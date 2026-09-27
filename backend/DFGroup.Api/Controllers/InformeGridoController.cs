using System.Data;
using Dapper;
using DFGroup.Api.Configuration;
using DFGroup.Api.Models.DTOs;
using Microsoft.AspNetCore.Mvc;
using Swashbuckle.AspNetCore.Annotations;

namespace DFGroup.Api.Controllers;

/// <summary>
/// Informe Diario GRIDO: las mismas metricas que el Excel que sale por mail
/// todos los dias, para el rango de jornadas que se pida.
/// </summary>
[ApiController]
[Route("api/v1/ventas/informe-grido")]
[Produces("application/json")]
public class InformeGridoController : ControllerBase
{
    private readonly IDbConnectionFactory _connectionFactory;

    public InformeGridoController(IDbConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    /// <summary>
    /// Filas del Informe Diario GRIDO para un rango de jornadas.
    /// </summary>
    /// <remarks>
    /// Una fila por jornada/sucursal/turno/caja/cajero, igual que el Excel.
    /// Los subtotales por sucursal y el total los arma el frontend, porque el
    /// Excel tambien los calcula con formulas: asi los dos muestran lo mismo.
    /// </remarks>
    [HttpGet]
    [SwaggerOperation(
        Summary = "Informe Diario GRIDO",
        Description = "Metricas por cajero y turno para un rango de jornadas (dia operativo de 02:00 a 02:00).")]
    [SwaggerResponse(200, "Filas del informe", typeof(IEnumerable<InformeGridoFilaDto>))]
    [SwaggerResponse(400, "Rango de fechas invalido")]
    public async Task<ActionResult<IEnumerable<InformeGridoFilaDto>>> Get(
        [FromQuery] DateTime? desde,
        [FromQuery] DateTime? hasta)
    {
        // Sin rango, la ultima jornada cerrada: es lo que trae el Excel de hoy.
        var hoy = DateTime.Today;
        var fDesde = (desde ?? hoy.AddDays(-1)).Date;
        var fHasta = (hasta ?? fDesde).Date;

        if (fDesde > fHasta)
        {
            return BadRequest(new { error = "La fecha 'desde' no puede ser posterior a 'hasta'." });
        }

        // Un rango muy largo devuelve miles de filas y no se puede leer. El
        // tope es generoso pero evita que un dedazo cuelgue el navegador.
        if ((fHasta - fDesde).TotalDays > 366)
        {
            return BadRequest(new { error = "El rango no puede superar los 366 dias." });
        }

        using var connection = _connectionFactory.CreateConnection();

        var filas = await connection.QueryAsync<InformeGridoFilaDto>(
            "dbo.usp_InformeDiarioGrido",
            new { FechaDesde = fDesde, FechaHasta = fHasta },
            commandType: CommandType.StoredProcedure,
            commandTimeout: 120);

        return Ok(filas);
    }
}
