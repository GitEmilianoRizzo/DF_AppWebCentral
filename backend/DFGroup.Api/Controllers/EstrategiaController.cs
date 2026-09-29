using System.Data;
using System.Text.Json;
using Dapper;
using DFGroup.Api.Configuration;
using DFGroup.Api.Models.DTOs;
using DFGroup.Api.Services;
using Microsoft.AspNetCore.Mvc;
using Swashbuckle.AspNetCore.Annotations;

namespace DFGroup.Api.Controllers;

/// <summary>
/// Estrategia: el ciclo de declarar un objetivo, recibir sugerencias y decidir.
/// </summary>
/// <remarks>
/// A diferencia del resto de la app, que describe lo que ya paso, esto propone
/// que hacer. Las sugerencias salen del pronostico cruzado con la elasticidad
/// al clima medida sobre la huella, y se guardan con la evidencia con la que se
/// generaron: seis meses despues hay que poder saber por que se sugirio eso y
/// no otra cosa.
/// </remarks>
[ApiController]
[Route("api/v1/estrategia")]
[Produces("application/json")]
public class EstrategiaController : ControllerBase
{
    private readonly IDbConnectionFactory _connectionFactory;
    private readonly IMailService _mail;
    private readonly IConfiguration _config;

    public EstrategiaController(
        IDbConnectionFactory connectionFactory, IMailService mail, IConfiguration config)
    {
        _connectionFactory = connectionFactory;
        _mail = mail;
        _config = config;
    }

    /// <summary>Quien esta operando. Sin sesion se deja constancia de eso.</summary>
    private string Usuario => User?.Identity?.Name ?? "sin identificar";

    /// <summary>
    /// Los nombres de las sucursales.
    /// </summary>
    /// <remarks>
    /// Van aca y no en la base porque el aviso los necesita para el asunto del
    /// mail, y son cuatro y fijos. Cuando exista una dimension de sucursales
    /// en el DWH, esto sale de ahi.
    /// </remarks>
    private static readonly Dictionary<int, string> NombreSucursal = new()
    {
        [1] = "Lanus Oeste",
        [2] = "Escalada",
        [3] = "Fiorito",
        [4] = "Mayorista",
    };

    private static string Suc(int id) =>
        NombreSucursal.GetValueOrDefault(id, $"Sucursal {id}");

    /// <summary>Listado de objetivos.</summary>
    /// <param name="estado">VIGENTE o CERRADO. Vacio = todos.</param>
    /// <param name="top">Tope de filas.</param>
    [HttpGet("objetivos")]
    [SwaggerOperation(Summary = "Listado de objetivos")]
    [SwaggerResponse(200, "Objetivos", typeof(IEnumerable<ObjetivoFilaDto>))]
    public async Task<ActionResult<IEnumerable<ObjetivoFilaDto>>> GetObjetivos(
        [FromQuery] string? estado = null,
        [FromQuery] int top = 50)
    {
        using var connection = _connectionFactory.CreateConnection();

        var filas = await connection.QueryAsync<ObjetivoFilaDto>(
            "dbo.usp_ListarObjetivos",
            new
            {
                Estado = string.IsNullOrWhiteSpace(estado) ? null : estado.Trim().ToUpperInvariant(),
                Top = Math.Clamp(top, 1, 500)
            },
            commandType: CommandType.StoredProcedure,
            commandTimeout: 60);

        return Ok(filas);
    }

    /// <summary>Un objetivo con sus metas por sucursal y sus sugerencias.</summary>
    [HttpGet("objetivos/{objetivoId:int}")]
    [SwaggerOperation(Summary = "Detalle de un objetivo")]
    [SwaggerResponse(200, "Detalle", typeof(ObjetivoDetalleDto))]
    [SwaggerResponse(404, "No existe")]
    public async Task<ActionResult<ObjetivoDetalleDto>> GetObjetivo(int objetivoId)
    {
        using var connection = _connectionFactory.CreateConnection();

        using var grid = await connection.QueryMultipleAsync(
            "dbo.usp_ObtenerObjetivo",
            new { ObjetivoId = objetivoId },
            commandType: CommandType.StoredProcedure,
            commandTimeout: 60);

        var cabecera = await grid.ReadFirstOrDefaultAsync<ObjetivoFilaDto>();
        if (cabecera is null)
        {
            return NotFound(new { error = $"No existe el objetivo {objetivoId}." });
        }

        var sucursales = (await grid.ReadAsync<ObjetivoSucursalDto>()).ToList();
        var sugerencias = (await grid.ReadAsync<SugerenciaDto>()).ToList();

        // La cabecera del SP no trae los contadores que si trae el listado;
        // se completan aca para que la pantalla use un solo tipo.
        cabecera.Sucursales = sucursales.Count;
        cabecera.Sugerencias = sugerencias.Count;
        cabecera.Pendientes = sugerencias.Count(s => s.Estado == "SUGERIDA");

        return Ok(new ObjetivoDetalleDto
        {
            Objetivo = cabecera,
            Sucursales = sucursales,
            Sugerencias = sugerencias
        });
    }

    /// <summary>Crea un objetivo con una meta por sucursal.</summary>
    /// <remarks>
    /// La meta va en porcentaje SOBRE LO ESPERADO para el clima de cada dia, no
    /// en pesos. Un monto fijo mide el verano, no la gestion.
    /// </remarks>
    [HttpPost("objetivos")]
    [SwaggerOperation(Summary = "Crear un objetivo")]
    [SwaggerResponse(201, "Creado", typeof(ObjetivoDetalleDto))]
    [SwaggerResponse(400, "Datos invalidos")]
    public async Task<ActionResult<ObjetivoDetalleDto>> CrearObjetivo(
        [FromBody] CrearObjetivoRequest req)
    {
        if (string.IsNullOrWhiteSpace(req.Nombre))
        {
            return BadRequest(new { error = "El objetivo necesita un nombre." });
        }

        var metrica = (req.Metrica ?? string.Empty).Trim().ToUpperInvariant();
        if (metrica is not ("FACTURACION" or "MARGEN" or "KILOS"))
        {
            return BadRequest(new { error = "La metrica tiene que ser FACTURACION, MARGEN o KILOS." });
        }
        if (req.FechaHasta.Date < req.FechaDesde.Date)
        {
            return BadRequest(new { error = "La fecha de fin no puede ser anterior a la de inicio." });
        }
        if (req.Sucursales is null || req.Sucursales.Count == 0)
        {
            return BadRequest(new { error = "Hay que indicar al menos una sucursal." });
        }
        if (req.Sucursales.Select(s => s.Sucursal).Distinct().Count() != req.Sucursales.Count)
        {
            return BadRequest(new { error = "Hay una sucursal repetida en la lista." });
        }

        // El SP recibe las sucursales como JSON porque cada una lleva su propia
        // meta: es el punto 2 del circuito, no todas tienen que ir al mismo numero.
        var sucursalesJson = JsonSerializer.Serialize(req.Sucursales.Select(s => new
        {
            sucursal = s.Sucursal,
            meta = s.MetaPct,
            responsable = string.IsNullOrWhiteSpace(s.Responsable) ? null : s.Responsable.Trim(),
            mail = string.IsNullOrWhiteSpace(s.Mail) ? null : s.Mail.Trim()
        }));

        using var connection = _connectionFactory.CreateConnection();

        int objetivoId;
        try
        {
            objetivoId = await connection.QueryFirstAsync<int>(
                "dbo.usp_CrearObjetivo",
                new
                {
                    Nombre = req.Nombre.Trim(),
                    Metrica = metrica,
                    FechaDesde = req.FechaDesde.Date,
                    FechaHasta = req.FechaHasta.Date,
                    Sucursales = sucursalesJson,
                    Notas = string.IsNullOrWhiteSpace(req.Notas) ? null : req.Notas.Trim(),
                    Usuario
                },
                commandType: CommandType.StoredProcedure,
                commandTimeout: 60);
        }
        catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Class == 16)
        {
            // Las validaciones del SP son RAISERROR de severidad 16: son
            // problemas del pedido, no de la base. Van como 400 y no como 500.
            return BadRequest(new { error = ex.Message });
        }

        // Un objetivo recien creado sin sugerencias es una pantalla vacia que
        // no dice nada. Se generan en el acto; si el pronostico no alcanza, el
        // objetivo igual queda creado y se puede regenerar despues.
        try
        {
            await connection.ExecuteAsync(
                "dbo.usp_GenerarSugerencias",
                new { ObjetivoId = objetivoId },
                commandType: CommandType.StoredProcedure,
                commandTimeout: 180);
        }
        catch (Microsoft.Data.SqlClient.SqlException)
        {
            // Se ignora a proposito: el objetivo existe y es lo que importa.
        }

        var detalle = await GetObjetivo(objetivoId);
        return CreatedAtAction(nameof(GetObjetivo), new { objetivoId }, (detalle.Result as OkObjectResult)?.Value);
    }

    /// <summary>Vuelve a generar las sugerencias de un objetivo.</summary>
    /// <remarks>
    /// Rehace las que nadie decidio todavia. Las aceptadas y descartadas no se
    /// tocan: son decisiones tomadas y sirven para medir despues.
    /// </remarks>
    [HttpPost("objetivos/{objetivoId:int}/sugerencias")]
    [SwaggerOperation(Summary = "Regenerar sugerencias")]
    [SwaggerResponse(200, "Detalle actualizado", typeof(ObjetivoDetalleDto))]
    public async Task<ActionResult<ObjetivoDetalleDto>> GenerarSugerencias(int objetivoId)
    {
        using (var connection = _connectionFactory.CreateConnection())
        {
            await connection.ExecuteAsync(
                "dbo.usp_GenerarSugerencias",
                new { ObjetivoId = objetivoId },
                commandType: CommandType.StoredProcedure,
                commandTimeout: 180);
        }

        return await GetObjetivo(objetivoId);
    }

    /// <summary>Acepta, descarta o reabre una sugerencia.</summary>
    [HttpPut("sugerencias/{sugerenciaId:int}")]
    [SwaggerOperation(Summary = "Decidir una sugerencia")]
    [SwaggerResponse(200, "Decidida")]
    [SwaggerResponse(400, "Estado invalido")]
    [SwaggerResponse(404, "No existe")]
    public async Task<IActionResult> DecidirSugerencia(
        int sugerenciaId, [FromBody] DecidirSugerenciaRequest req)
    {
        var estado = (req.Estado ?? string.Empty).Trim().ToUpperInvariant();
        if (estado is not ("ACEPTADA" or "DESCARTADA" or "SUGERIDA"))
        {
            return BadRequest(new { error = "El estado tiene que ser ACEPTADA, DESCARTADA o SUGERIDA." });
        }

        using var connection = _connectionFactory.CreateConnection();

        try
        {
            var resultado = await connection.QueryFirstOrDefaultAsync<SugerenciaDto>(
                "dbo.usp_DecidirSugerencia",
                new
                {
                    SugerenciaId = sugerenciaId,
                    Estado = estado,
                    Comentario = string.IsNullOrWhiteSpace(req.Comentario) ? null : req.Comentario.Trim(),
                    Usuario
                },
                commandType: CommandType.StoredProcedure,
                commandTimeout: 60);

            // Aceptar algo DESPUES de haber avisado invalida el aviso: lo que
            // recibieron los locales ya no es lo vigente. Se destilda para que
            // el boton vuelva a aparecer, en vez de dejar el objetivo marcado
            // como avisado con la mitad de las acciones.
            if (estado == "ACEPTADA")
            {
                await connection.ExecuteAsync(
                    // El id del objetivo va a una variable: EXEC no acepta una
                    // subconsulta como valor de parametro.
                    @"DECLARE @obj int = (SELECT OBJETIVO_ID FROM dbo.ESTRATEGIA_SUGERENCIA
                                          WHERE SUGERENCIA_ID = @SugerenciaId);
                      IF EXISTS (SELECT 1 FROM dbo.ESTRATEGIA_OBJETIVO
                                 WHERE OBJETIVO_ID = @obj AND AVISADO_EL IS NOT NULL)
                          EXEC dbo.usp_ReabrirAviso @ObjetivoId = @obj;",
                    new { SugerenciaId = sugerenciaId },
                    commandTimeout: 60);
            }

            return Ok(resultado);
        }
        catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Class == 16)
        {
            return NotFound(new { error = ex.Message });
        }
    }

    /// <summary>La medicion del objetivo: esperado contra real, dia por dia.</summary>
    /// <remarks>
    /// Solo LEE lo que la tarea diaria ya calculo. No recalcula: la medicion se
    /// congela el dia que se hace, con el clima y la calibracion de ese momento,
    /// para que un recalibrado de manana no cambie una medicion de ayer.
    /// </remarks>
    [HttpGet("objetivos/{objetivoId:int}/medicion")]
    [SwaggerOperation(Summary = "Medicion de un objetivo")]
    [SwaggerResponse(200, "Medicion", typeof(MedicionDto))]
    public async Task<ActionResult<MedicionDto>> GetMedicion(int objetivoId)
    {
        using var connection = _connectionFactory.CreateConnection();

        using var grid = await connection.QueryMultipleAsync(
            "dbo.usp_ObtenerMedicion",
            new { ObjetivoId = objetivoId },
            commandType: CommandType.StoredProcedure,
            commandTimeout: 120);

        return Ok(new MedicionDto
        {
            Sucursales = await grid.ReadAsync<MedicionSucursalDto>(),
            Dias = await grid.ReadAsync<MedicionDiaDto>(),
        });
    }

    /// <summary>Recalcula la medicion ahora, sin esperar la tarea diaria.</summary>
    /// <remarks>
    /// La medicion normal la hace la tarea de las 12:30. Esto existe para el dia
    /// que se recargo una jornada vieja o se acaba de crear un objetivo sobre un
    /// periodo ya pasado: sin esto habria que esperar hasta el otro dia.
    /// </remarks>
    [HttpPost("objetivos/{objetivoId:int}/medicion")]
    [SwaggerOperation(Summary = "Recalcular la medicion")]
    [SwaggerResponse(200, "Medicion", typeof(MedicionDto))]
    [SwaggerResponse(404, "No existe")]
    public async Task<ActionResult<MedicionDto>> RecalcularMedicion(int objetivoId)
    {
        using (var connection = _connectionFactory.CreateConnection())
        {
            try
            {
                await connection.ExecuteAsync(
                    "dbo.usp_MedirObjetivo",
                    new { ObjetivoId = objetivoId },
                    commandType: CommandType.StoredProcedure,
                    commandTimeout: 300);
            }
            catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Class == 16)
            {
                return NotFound(new { error = ex.Message });
            }
        }

        return await GetMedicion(objetivoId);
    }

    /// <summary>El mail tal como lo va a recibir una sucursal, sin enviarlo.</summary>
    /// <remarks>
    /// Existe para poder mirar el aviso antes de que salga. Un mail a los
    /// locales no se puede despublicar, asi que conviene que haya una forma de
    /// verlo que no implique mandarlo.
    ///
    /// Devuelve HTML y no JSON: es para abrirlo en el navegador.
    /// </remarks>
    [HttpGet("objetivos/{objetivoId:int}/aviso/vista-previa")]
    [SwaggerOperation(Summary = "Vista previa del aviso")]
    [SwaggerResponse(200, "HTML del mail")]
    [SwaggerResponse(404, "No existe, o no hay nada que avisarle a esa sucursal")]
    public async Task<IActionResult> VistaPreviaAviso(int objetivoId, [FromQuery] int sucursal)
    {
        var previo = await GetObjetivo(objetivoId);
        if ((previo.Result as OkObjectResult)?.Value is not ObjetivoDetalleDto detalle
            || detalle.Objetivo is null)
        {
            return NotFound(new { error = $"No existe el objetivo {objetivoId}." });
        }

        var suc = detalle.Sucursales.FirstOrDefault(s => s.Sucursal == sucursal);
        if (suc is null)
        {
            return NotFound(new { error = $"El objetivo no incluye la sucursal {sucursal}." });
        }

        // La vista previa no puede depender de que el mail este cargado: se
        // quiere ver como queda ANTES de terminar de cargar los datos.
        var conMail = new ObjetivoSucursalDto
        {
            Sucursal = suc.Sucursal,
            MetaPct = suc.MetaPct,
            Responsable = suc.Responsable,
            Mail = string.IsNullOrWhiteSpace(suc.Mail) ? "vista-previa@ejemplo.com" : suc.Mail,
            Notas = suc.Notas,
        };

        var mail = AvisoEstrategiaBuilder.Armar(
            detalle.Objetivo, conMail, Suc(sucursal), detalle.Sugerencias, null);

        if (mail is null)
        {
            return NotFound(new
            {
                error = $"{Suc(sucursal)} no tiene ninguna sugerencia aceptada, asi que no recibiria mail.",
            });
        }

        return Content(mail.CuerpoHtml, "text/html; charset=utf-8");
    }

    /// <summary>Manda a cada responsable las acciones aceptadas de su local.</summary>
    /// <remarks>
    /// Es el paso 4 del circuito. Cada uno recibe lo suyo mas lo que aplica a
    /// todas las sucursales, nunca la lista completa: lo que se lee en diagonal
    /// no se ejecuta.
    ///
    /// Un mail que falla no frena a los demas, y solo se marca como avisada la
    /// sucursal que efectivamente recibio el suyo.
    /// </remarks>
    [HttpPost("objetivos/{objetivoId:int}/avisar")]
    [SwaggerOperation(Summary = "Avisar a los responsables")]
    [SwaggerResponse(200, "Resultado del envio", typeof(AvisoResultadoDto))]
    [SwaggerResponse(400, "No hay nada que avisar o falta configurar el correo")]
    [SwaggerResponse(404, "No existe")]
    /// <param name="prueba">Manda a la casilla de copia en vez de a los locales.</param>
    /// <param name="sucursal">Solo esta sucursal. Pensado para el ensayo.</param>
    public async Task<ActionResult<AvisoResultadoDto>> Avisar(
        int objetivoId, [FromQuery] bool prueba = false, [FromQuery] int? sucursal = null)
    {
        if (!_mail.Configurado)
        {
            return BadRequest(new
            {
                error = "Falta configurar el correo saliente. La clave se toma de la variable "
                      + @"Smtp__Password, que los lanzadores leen de C:\PILL-DF\_secrets\webapp_smtp.txt.",
            });
        }

        var previo = await GetObjetivo(objetivoId);
        if ((previo.Result as OkObjectResult)?.Value is not ObjetivoDetalleDto detalle
            || detalle.Objetivo is null)
        {
            return NotFound(new { error = $"No existe el objetivo {objetivoId}." });
        }

        var sugerencias = detalle.Sugerencias.ToList();
        if (!sugerencias.Any(s => s.Estado == "ACEPTADA"))
        {
            return BadRequest(new
            {
                error = "No hay ninguna sugerencia aceptada. Avisar una lista vacia solo "
                      + "entrena a los locales a ignorar estos mails.",
            });
        }

        var copiaA = _config["Smtp:CopiaA"];
        if (prueba && string.IsNullOrWhiteSpace(copiaA))
        {
            return BadRequest(new
            {
                error = "El modo prueba manda a la casilla de copia, y no hay ninguna configurada (Smtp:CopiaA).",
            });
        }

        var detalleEnvio = new List<AvisoSucursalDto>();

        using var connection = _connectionFactory.CreateConnection();

        var destino = detalle.Sucursales
            .Where(x => sucursal is null || x.Sucursal == sucursal)
            .OrderBy(x => x.Sucursal)
            .ToList();

        if (destino.Count == 0)
        {
            return BadRequest(new { error = $"El objetivo no incluye la sucursal {sucursal}." });
        }

        foreach (var s in destino)
        {
            var nombre = Suc(s.Sucursal);

            // En el ensayo el mail no va al local sino a la casilla de copia,
            // asi que la falta de direccion cargada no tiene por que impedirlo:
            // justamente sirve para ver como queda antes de terminar de cargar
            // esos datos.
            var origen = prueba && string.IsNullOrWhiteSpace(s.Mail)
                ? new ObjetivoSucursalDto
                {
                    Sucursal = s.Sucursal, MetaPct = s.MetaPct, Responsable = s.Responsable,
                    Mail = copiaA, Notas = s.Notas, AvisadoEl = s.AvisadoEl,
                }
                : s;

            var mail = AvisoEstrategiaBuilder.Armar(detalle.Objetivo, origen, nombre, sugerencias, copiaA);

            if (mail is null)
            {
                // Dos motivos distintos que hay que poder diferenciar: no tiene
                // nada que hacer, o falta cargarle el mail.
                var acciones = sugerencias.Count(g =>
                    g.Estado == "ACEPTADA" && (g.Sucursal is null || g.Sucursal == s.Sucursal));
                detalleEnvio.Add(new AvisoSucursalDto
                {
                    Sucursal = s.Sucursal,
                    Nombre = nombre,
                    Mail = s.Mail,
                    Enviado = false,
                    Acciones = acciones,
                    Motivo = acciones == 0
                        ? "No le quedo ninguna accion aceptada."
                        : "No tiene mail cargado.",
                });
                continue;
            }

            // En modo prueba el mail sale igual, pero solo a la casilla de
            // copia: sirve para ver como queda sin avisarle a los locales.
            var salida = prueba && !string.IsNullOrWhiteSpace(copiaA)
                ? mail with { Para = copiaA!, Copia = null, Asunto = "[PRUEBA] " + mail.Asunto }
                : mail;

            var r = await _mail.EnviarAsync(salida);

            detalleEnvio.Add(new AvisoSucursalDto
            {
                Sucursal = s.Sucursal,
                Nombre = nombre,
                Mail = salida.Para,
                Enviado = r.Enviado,
                Acciones = sugerencias.Count(g =>
                    g.Estado == "ACEPTADA" && (g.Sucursal is null || g.Sucursal == s.Sucursal)),
                Motivo = r.Error,
            });

            // Una prueba no marca nada: si marcara, el aviso real quedaria
            // dado por hecho y los locales nunca se enterarian.
            if (r.Enviado && !prueba)
            {
                await connection.ExecuteAsync(
                    "dbo.usp_MarcarAvisado",
                    new { ObjetivoId = objetivoId, Sucursal = s.Sucursal },
                    commandType: CommandType.StoredProcedure,
                    commandTimeout: 60);
            }
        }

        var post = await GetObjetivo(objetivoId);

        return Ok(new AvisoResultadoDto
        {
            Enviados = detalleEnvio.Count(d => d.Enviado),
            Omitidos = detalleEnvio.Count(d => !d.Enviado),
            Detalle = detalleEnvio,
            Objetivo = (post.Result as OkObjectResult)?.Value as ObjetivoDetalleDto,
        });
    }

    /// <summary>Cierra un objetivo.</summary>
    /// <remarks>
    /// Las sugerencias que quedaron sin decidir pasan a VENCIDA. No son tareas
    /// abiertas: la ventana en la que servian ya paso.
    /// </remarks>
    [HttpPost("objetivos/{objetivoId:int}/cerrar")]
    [SwaggerOperation(Summary = "Cerrar un objetivo")]
    [SwaggerResponse(200, "Cerrado")]
    public async Task<IActionResult> CerrarObjetivo(int objetivoId)
    {
        using var connection = _connectionFactory.CreateConnection();

        await connection.ExecuteAsync(
            "dbo.usp_CerrarObjetivo",
            new { ObjetivoId = objetivoId, Usuario },
            commandType: CommandType.StoredProcedure,
            commandTimeout: 60);

        return Ok(new { objetivoId, estado = "CERRADO" });
    }

    /// <summary>El pronostico diario por sucursal.</summary>
    /// <remarks>
    /// Es el dato sobre el que se apoyan las sugerencias, asi que la pantalla
    /// lo muestra al lado: si el pronostico se ve raro, la sugerencia tambien.
    /// </remarks>
    /// <param name="sucursal">Vacio = todas.</param>
    /// <param name="dias">Cuantos dias hacia adelante.</param>
    [HttpGet("pronostico")]
    [SwaggerOperation(Summary = "Pronostico diario")]
    [SwaggerResponse(200, "Pronostico", typeof(IEnumerable<PronosticoDiaDto>))]
    public async Task<ActionResult<IEnumerable<PronosticoDiaDto>>> GetPronostico(
        [FromQuery] int? sucursal = null,
        [FromQuery] int dias = 7)
    {
        using var connection = _connectionFactory.CreateConnection();

        var filas = await connection.QueryAsync<PronosticoDiaDto>(
            "dbo.usp_PronosticoDiario",
            new { Sucursal = sucursal, Dias = Math.Clamp(dias, 1, 16) },
            commandType: CommandType.StoredProcedure,
            commandTimeout: 60);

        return Ok(filas);
    }
}
