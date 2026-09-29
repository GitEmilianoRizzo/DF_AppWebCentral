using System.Data;
using Dapper;
using DFGroup.Api.Configuration;
using DFGroup.Api.Models.DTOs;
using Microsoft.AspNetCore.Mvc;
using Swashbuckle.AspNetCore.Annotations;

namespace DFGroup.Api.Controllers;

/// <summary>
/// Fichero de Articulos: consulta del maestro de la base de origen.
/// </summary>
/// <remarks>
/// Solo lectura. El alta y la modificacion se siguen haciendo en el sistema
/// de gestion; esto es para poder mirar una ficha sin salir de la app.
/// </remarks>
[ApiController]
[Route("api/v1/abm/articulos")]
[Produces("application/json")]
public class FicheroArticulosController : ControllerBase
{
    private readonly IDbConnectionFactory _connectionFactory;

    public FicheroArticulosController(IDbConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    /// <summary>Listado de articulos, filtrable.</summary>
    /// <param name="buscar">Texto en la descripcion o el codigo, o el id exacto.</param>
    /// <param name="tipo">ELABORADO, INSUMO, etc.</param>
    /// <param name="grupo">Id de grupo.</param>
    /// <param name="soloActivos">Por defecto solo los activos, como el sistema de origen.</param>
    /// <param name="top">Tope de filas.</param>
    [HttpGet]
    [SwaggerOperation(Summary = "Listado del maestro de articulos")]
    [SwaggerResponse(200, "Articulos", typeof(IEnumerable<ArticuloFilaDto>))]
    public async Task<ActionResult<IEnumerable<ArticuloFilaDto>>> Get(
        [FromQuery] string? buscar = null,
        [FromQuery] string? tipo = null,
        [FromQuery] int? grupo = null,
        [FromQuery] bool soloActivos = true,
        [FromQuery] int top = 300)
    {
        using var connection = _connectionFactory.CreateConnection();

        var filas = await connection.QueryAsync<ArticuloFilaDto>(
            "dbo.usp_FicheroArticulos",
            new
            {
                Buscar = string.IsNullOrWhiteSpace(buscar) ? null : buscar.Trim(),
                Tipo = string.IsNullOrWhiteSpace(tipo) ? null : tipo,
                Grupo = grupo,
                SoloActivos = soloActivos,
                Top = Math.Clamp(top, 1, 5000)
            },
            commandType: CommandType.StoredProcedure,
            commandTimeout: 120);

        return Ok(filas);
    }

    /// <summary>Ficha de un articulo: cabecera y receta.</summary>
    [HttpGet("{articulo:int}")]
    [SwaggerOperation(Summary = "Ficha de un articulo")]
    [SwaggerResponse(200, "Ficha", typeof(ArticuloFichaDto))]
    [SwaggerResponse(404, "No existe")]
    public async Task<ActionResult<ArticuloFichaDto>> GetFicha(int articulo)
    {
        using var connection = _connectionFactory.CreateConnection();

        using var grid = await connection.QueryMultipleAsync(
            "dbo.usp_FicheroArticuloDetalle",
            new { Articulo = articulo },
            commandType: CommandType.StoredProcedure,
            commandTimeout: 120);

        var detalle = await grid.ReadFirstOrDefaultAsync<ArticuloDetalleDto>();
        if (detalle is null)
        {
            return NotFound(new { error = $"No existe el articulo {articulo}." });
        }

        return Ok(new ArticuloFichaDto
        {
            Detalle = detalle,
            Receta = await grid.ReadAsync<ArticuloRecetaDto>(),
            Sap = await grid.ReadFirstOrDefaultAsync<ArticuloSapDto>()
        });
    }

    /// <summary>Guarda o actualiza el codigo SAP del articulo.</summary>
    /// <remarks>
    /// Es lo UNICO editable de la ficha. El dato vive en DF_DTW y no en la
    /// base de origen, que se restaura entera todos los dias a las 12:00 y se
    /// llevaria puesto lo que se cargue.
    /// </remarks>
    [HttpPut("{articulo:int}/sap")]
    [SwaggerOperation(Summary = "Guardar el codigo SAP de un articulo")]
    [SwaggerResponse(200, "Mapeo guardado", typeof(ArticuloSapDto))]
    [SwaggerResponse(400, "Datos invalidos")]
    public async Task<ActionResult<ArticuloSapDto>> GuardarSap(
        int articulo, [FromBody] GuardarArticuloSapRequest req)
    {
        if (string.IsNullOrWhiteSpace(req.CodigoSap))
        {
            return BadRequest(new { error = "El codigo SAP no puede quedar vacio." });
        }
        if (req.FactorSap <= 0)
        {
            return BadRequest(new { error = "El factor de conversion tiene que ser mayor que cero." });
        }

        using var connection = _connectionFactory.CreateConnection();

        var guardado = await connection.QueryFirstOrDefaultAsync<ArticuloSapDto>(
            "dbo.usp_GuardarArticuloSap",
            new
            {
                Articulo = articulo,
                CodigoSap = req.CodigoSap.Trim(),
                DescripcionSap = string.IsNullOrWhiteSpace(req.DescripcionSap) ? null : req.DescripcionSap.Trim(),
                UnidadSap = string.IsNullOrWhiteSpace(req.UnidadSap) ? null : req.UnidadSap.Trim(),
                FactorSap = req.FactorSap,
                Observaciones = string.IsNullOrWhiteSpace(req.Observaciones) ? null : req.Observaciones.Trim(),
                Activo = req.Activo,
                // Queda registrado quien lo toco. Sin sesion identificada se
                // deja constancia de eso mismo en vez de inventar un nombre.
                Usuario = User?.Identity?.Name ?? "sin identificar"
            },
            commandType: CommandType.StoredProcedure,
            commandTimeout: 60);

        return Ok(guardado);
    }

    /// <summary>Borra el mapeo a SAP del articulo.</summary>
    [HttpDelete("{articulo:int}/sap")]
    [SwaggerOperation(Summary = "Borrar el codigo SAP de un articulo")]
    [SwaggerResponse(204, "Borrado")]
    public async Task<IActionResult> BorrarSap(int articulo)
    {
        using var connection = _connectionFactory.CreateConnection();
        await connection.ExecuteAsync(
            "dbo.usp_BorrarArticuloSap",
            new { Articulo = articulo },
            commandType: CommandType.StoredProcedure,
            commandTimeout: 60);
        return NoContent();
    }
}
