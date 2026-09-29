using System.Data;
using Dapper;
using DFGroup.Api.Configuration;
using DFGroup.Api.Models.DTOs;
using Microsoft.AspNetCore.Mvc;
using Swashbuckle.AspNetCore.Annotations;

namespace DFGroup.Api.Controllers;

/// <summary>
/// Estadistica de Ventas: la misma consulta que la pantalla "Estadisticas de
/// venta" de SmartFran, resuelta sobre la huella.
/// </summary>
/// <remarks>
/// Se verifico contra una captura del 09/09/2026: para el periodo 01/09 al
/// 08/09, Escalada, Fiorito y Mayorista coinciden al centavo en venta,
/// tickets, cantidad, descuentos, promos, kilos, costo y utilidad, y los
/// totales de sobreventas dan exactos. Lanus difiere solo por movimientos que
/// llegaron al servidor central despues de esa captura.
/// </remarks>
[ApiController]
[Route("api/v1/ventas/estadistica")]
[Produces("application/json")]
public class EstadisticaVentasController : ControllerBase
{
    private readonly IDbConnectionFactory _connectionFactory;

    public EstadisticaVentasController(IDbConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    /// <summary>Corre la consulta con los filtros de la pantalla de SmartFran.</summary>
    /// <param name="desde">Inicio del periodo. Hora calendario, no jornada comercial.</param>
    /// <param name="hasta">Fin del periodo, EXCLUSIVO.</param>
    /// <param name="sucursales">Ids separados por coma. Vacio = todas.</param>
    /// <param name="horaDesde">Hora de corte inferior (0-24).</param>
    /// <param name="horaHasta">Hora de corte superior (0-24), exclusiva.</param>
    /// <param name="diasSemana">Dias a incluir, 1=lunes..7=domingo. Vacio = todos.</param>
    /// <param name="canal">Id de canal de venta.</param>
    /// <param name="tipoProducto">Tipo de articulo (ELABORADO, etc).</param>
    /// <param name="grupoProducto">Id de grupo de articulo.</param>
    /// <param name="articulo">Id de articulo.</param>
    /// <param name="delivery">1 solo delivery, 0 sin delivery, vacio ambos.</param>
    /// <param name="cajero">Usuario del cajero.</param>
    /// <param name="cliente">Id de cliente.</param>
    /// <param name="topArticulos">Cuantos articulos devolver como maximo.</param>
    [HttpGet]
    [SwaggerOperation(
        Summary = "Estadistica de Ventas",
        Description = "Totales y cortes por sucursal, grupo, articulo, promocion y sobreventa.")]
    [SwaggerResponse(200, "Resultado de la consulta", typeof(EstadisticaVentasRespuestaDto))]
    [SwaggerResponse(400, "Parametros invalidos")]
    public async Task<ActionResult<EstadisticaVentasRespuestaDto>> Get(
        [FromQuery] DateTime? desde,
        [FromQuery] DateTime? hasta,
        [FromQuery] string? sucursales = null,
        [FromQuery] byte horaDesde = 0,
        [FromQuery] byte horaHasta = 24,
        [FromQuery] string? diasSemana = null,
        [FromQuery] int? canal = null,
        [FromQuery] string? tipoProducto = null,
        [FromQuery] int? grupoProducto = null,
        [FromQuery] int? articulo = null,
        [FromQuery] byte? delivery = null,
        [FromQuery] string? cajero = null,
        [FromQuery] int? cliente = null,
        [FromQuery] int topArticulos = 200)
    {
        // Sin periodo, el mes en curso hasta hoy: es el arranque mas util y
        // evita barrer la tabla entera por un descuido.
        var hoy = DateTime.Today;
        var fDesde = desde ?? new DateTime(hoy.Year, hoy.Month, 1);
        var fHasta = hasta ?? hoy;

        if (fDesde >= fHasta)
        {
            return BadRequest(new { error = "La fecha 'desde' tiene que ser anterior a 'hasta'." });
        }

        if ((fHasta - fDesde).TotalDays > 400)
        {
            return BadRequest(new { error = "El periodo no puede superar los 400 dias." });
        }

        // La franja horaria recorta DENTRO de cada dia, no es un intervalo
        // continuo: 'desde' igual o mayor que 'hasta' describiria una ventana
        // que cruza la medianoche, que esto no puede expresar. El caso real
        // que lleva a eso es la jornada comercial, y se pide por el periodo
        // (desde=D 02:00, hasta=D+1 02:00), no por esta franja.
        if (horaDesde > 24 || horaHasta > 24)
        {
            return BadRequest(new { error = "Las horas de la franja tienen que estar entre 0 y 24." });
        }

        if (horaDesde >= horaHasta)
        {
            return BadRequest(new
            {
                error = $"La franja horaria {horaDesde} a {horaHasta} esta vacia: recorta un tramo " +
                        "dentro de cada dia, asi que 'desde' tiene que ser menor que 'hasta'. " +
                        "Si lo que se busca es la jornada comercial (de 02:00 a 02:00 del dia " +
                        "siguiente), pedirla por el periodo con hora y dejar la franja en 0 a 24."
            });
        }

        topArticulos = Math.Clamp(topArticulos, 1, 2000);

        using var connection = _connectionFactory.CreateConnection();

        // El SP devuelve ocho conjuntos en un solo viaje. Leerlos por separado
        // significaria repetir el filtrado (que es la parte cara) ocho veces.
        using var grid = await connection.QueryMultipleAsync(
            "dbo.usp_EstadisticaVentas",
            new
            {
                FechaDesde = fDesde,
                FechaHasta = fHasta,
                Sucursales = string.IsNullOrWhiteSpace(sucursales) ? null : sucursales,
                HoraDesde = horaDesde,
                HoraHasta = horaHasta,
                DiasSemana = string.IsNullOrWhiteSpace(diasSemana) ? null : diasSemana,
                Canal = canal,
                TipoProducto = string.IsNullOrWhiteSpace(tipoProducto) ? null : tipoProducto,
                GrupoProducto = grupoProducto,
                Articulo = articulo,
                Delivery = delivery,
                Cajero = string.IsNullOrWhiteSpace(cajero) ? null : cajero,
                Cliente = cliente,
                TopArticulos = topArticulos
            },
            commandType: CommandType.StoredProcedure,
            commandTimeout: 180);

        // El orden de lectura tiene que seguir el orden de los SELECT del SP.
        var respuesta = new EstadisticaVentasRespuestaDto
        {
            Totales = await grid.ReadFirstAsync<EstadisticaTotalesDto>(),
            PorSucursal = await grid.ReadAsync<EstadisticaFilaDto>(),
            PorGrupo = await grid.ReadAsync<EstadisticaFilaDto>(),
            PorArticulo = await grid.ReadAsync<EstadisticaFilaDto>(),
            PorPromocion = await grid.ReadAsync<EstadisticaFilaDto>(),
            PorSobreventa = await grid.ReadAsync<EstadisticaFilaDto>(),
            Historia = await grid.ReadAsync<EstadisticaDiaDto>(),
            Distribuciones = await grid.ReadAsync<EstadisticaDistribucionDto>(),
            MapaCalor = await grid.ReadAsync<EstadisticaMapaCalorDto>(),
            ClimaDia = await grid.ReadAsync<EstadisticaClimaDiaDto>(),
            ClimaHora = await grid.ReadAsync<EstadisticaClimaHoraDto>(),
            PromoClima = await grid.ReadAsync<EstadisticaPromoClimaDto>()
        };

        return Ok(respuesta);
    }
}
