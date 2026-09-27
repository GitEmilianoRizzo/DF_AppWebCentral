using System.Text.Json.Serialization;

namespace DFGroup.Api.Models.DTOs;

/*
 * Estadistica de Ventas: replica de la pantalla homonima de SmartFran.
 *
 * Los nombres siguen los rotulos de esa pantalla ("Pedidos", "$ Dtos.",
 * "# Promo") y no los de la huella, porque el objetivo del modulo es que los
 * dos se puedan cruzar mirandolos uno al lado del otro.
 *
 * Cada corte (sucursal, grupo, articulo) comparte la misma forma de fila: asi
 * el frontend dibuja una sola grilla y solo le cambia el origen de datos.
 */

/// <summary>Panel de totales: el recuadro azul de SmartFran.</summary>
public class EstadisticaTotalesDto
{
    [JsonPropertyName("venta_total")]
    public decimal VentaTotal { get; set; }

    [JsonPropertyName("tickets")]
    public int Tickets { get; set; }

    [JsonPropertyName("ticket_promedio")]
    public decimal TicketPromedio { get; set; }

    [JsonPropertyName("cantidad")]
    public decimal Cantidad { get; set; }

    [JsonPropertyName("descuentos")]
    public decimal Descuentos { get; set; }

    /// <summary>Unidades vendidas en promocion (PROMO=1), no cantidad de lineas.</summary>
    [JsonPropertyName("promos")]
    public decimal Promos { get; set; }

    [JsonPropertyName("kilos")]
    public decimal Kilos { get; set; }

    [JsonPropertyName("costo")]
    public decimal Costo { get; set; }

    /// <summary>Venta - Costo de mercaderia. Es la "Utilidad" de SmartFran.</summary>
    [JsonPropertyName("utilidad")]
    public decimal Utilidad { get; set; }

    /// <summary>Utilidad menos el costo de los insumos. Indicador propio.</summary>
    [JsonPropertyName("contrib_marginal")]
    public decimal ContribMarginal { get; set; }

    [JsonPropertyName("tickets_anulados")]
    public int TicketsAnulados { get; set; }

    [JsonPropertyName("sv_activadas")]
    public int SvActivadas { get; set; }

    [JsonPropertyName("sv_aceptadas")]
    public int SvAceptadas { get; set; }

    [JsonPropertyName("sv_importe")]
    public decimal SvImporte { get; set; }

    [JsonPropertyName("sv_kilos")]
    public decimal SvKilos { get; set; }
}

/// <summary>Fila de cualquiera de las grillas por corte.</summary>
public class EstadisticaFilaDto
{
    [JsonPropertyName("detalle")]
    public string Detalle { get; set; } = string.Empty;

    /// <summary>Id de sucursal o de articulo segun el corte; nulo en el resto.</summary>
    [JsonPropertyName("sucursal")]
    public int? Sucursal { get; set; }

    [JsonPropertyName("articulo")]
    public int? Articulo { get; set; }

    [JsonPropertyName("venta")]
    public decimal Venta { get; set; }

    [JsonPropertyName("porcentaje")]
    public decimal? Porcentaje { get; set; }

    [JsonPropertyName("pedidos")]
    public int? Pedidos { get; set; }

    [JsonPropertyName("cantidad")]
    public decimal Cantidad { get; set; }

    [JsonPropertyName("descuentos")]
    public decimal? Descuentos { get; set; }

    [JsonPropertyName("promos")]
    public decimal? Promos { get; set; }

    [JsonPropertyName("kilos")]
    public decimal? Kilos { get; set; }

    [JsonPropertyName("costo")]
    public decimal? Costo { get; set; }

    [JsonPropertyName("utilidad")]
    public decimal? Utilidad { get; set; }

    [JsonPropertyName("pct_utilidad")]
    public decimal? PctUtilidad { get; set; }

    [JsonPropertyName("contrib_marginal")]
    public decimal? ContribMarginal { get; set; }

    [JsonPropertyName("pct_contrib")]
    public decimal? PctContrib { get; set; }
}

/// <summary>Un dia de la serie historica.</summary>
public class EstadisticaDiaDto
{
    [JsonPropertyName("dia")]
    public DateTime Dia { get; set; }

    [JsonPropertyName("venta")]
    public decimal Venta { get; set; }

    [JsonPropertyName("tickets")]
    public int Tickets { get; set; }

    [JsonPropertyName("kilos")]
    public decimal Kilos { get; set; }

    [JsonPropertyName("utilidad")]
    public decimal Utilidad { get; set; }

    [JsonPropertyName("contrib_marginal")]
    public decimal ContribMarginal { get; set; }
}

/// <summary>
/// Distribucion por hora, dia de la semana, mes, canal o lugar de entrega.
/// Van juntas con un discriminador para no multiplicar endpoints casi iguales.
/// </summary>
public class EstadisticaDistribucionDto
{
    /// <summary>HORA | DIASEMANA | MES | CANAL | ENTREGA</summary>
    [JsonPropertyName("tipo")]
    public string Tipo { get; set; } = string.Empty;

    [JsonPropertyName("orden")]
    public int Orden { get; set; }

    [JsonPropertyName("clave")]
    public string Clave { get; set; } = string.Empty;

    [JsonPropertyName("venta")]
    public decimal Venta { get; set; }

    [JsonPropertyName("tickets")]
    public int Tickets { get; set; }
}

/// <summary>Todo lo que devuelve una corrida de la consulta.</summary>
public class EstadisticaVentasRespuestaDto
{
    [JsonPropertyName("totales")]
    public EstadisticaTotalesDto Totales { get; set; } = new();

    [JsonPropertyName("por_sucursal")]
    public IEnumerable<EstadisticaFilaDto> PorSucursal { get; set; } = [];

    [JsonPropertyName("por_grupo")]
    public IEnumerable<EstadisticaFilaDto> PorGrupo { get; set; } = [];

    [JsonPropertyName("por_articulo")]
    public IEnumerable<EstadisticaFilaDto> PorArticulo { get; set; } = [];

    [JsonPropertyName("por_promocion")]
    public IEnumerable<EstadisticaFilaDto> PorPromocion { get; set; } = [];

    [JsonPropertyName("por_sobreventa")]
    public IEnumerable<EstadisticaFilaDto> PorSobreventa { get; set; } = [];

    [JsonPropertyName("historia")]
    public IEnumerable<EstadisticaDiaDto> Historia { get; set; } = [];

    [JsonPropertyName("distribuciones")]
    public IEnumerable<EstadisticaDistribucionDto> Distribuciones { get; set; } = [];
}
