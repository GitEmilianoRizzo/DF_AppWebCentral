using System.Text.Json.Serialization;

namespace DFGroup.Api.Models.DTOs;

/// <summary>
/// Una fila del Informe Diario GRIDO: un turno de un cajero en una jornada.
/// Los nombres coinciden con las columnas del Excel para que sea facil
/// contrastar los dos.
/// </summary>
public class InformeGridoFilaDto
{
    [JsonPropertyName("fecha_operativa")]
    public DateTime FechaOperativa { get; set; }

    [JsonPropertyName("sucursal")]
    public int Sucursal { get; set; }

    /// <summary>Rotulo tal como lo escribe el Excel (la 1 sale "Lanus Oeste").</summary>
    [JsonPropertyName("sucursal_rotulo")]
    public string SucursalRotulo { get; set; } = string.Empty;

    /// <summary>Orden del informe: Fiorito, Escalada, Lanus.</summary>
    [JsonPropertyName("orden_sucursal")]
    public int OrdenSucursal { get; set; }

    [JsonPropertyName("turno")]
    public int Turno { get; set; }

    [JsonPropertyName("caja")]
    public int Caja { get; set; }

    [JsonPropertyName("cajero")]
    public string Cajero { get; set; } = string.Empty;

    [JsonPropertyName("horario")]
    public string Horario { get; set; } = string.Empty;

    [JsonPropertyName("horas")]
    public decimal Horas { get; set; }

    [JsonPropertyName("kilos")]
    public decimal Kilos { get; set; }

    [JsonPropertyName("ventas")]
    public decimal Ventas { get; set; }

    [JsonPropertyName("tickets")]
    public int Tickets { get; set; }

    [JsonPropertyName("sv_activadas")]
    public int SvActivadas { get; set; }

    [JsonPropertyName("sv_aceptadas")]
    public int SvAceptadas { get; set; }

    /// <summary>Venta de las lineas en PROMOCION (sin sobreventa ni canjes), a precio de lista.</summary>
    [JsonPropertyName("promos")]
    public decimal Promos { get; set; }

    [JsonPropertyName("socios")]
    public int Socios { get; set; }

    [JsonPropertyName("ventas_club")]
    public decimal VentasClub { get; set; }

    /// <summary>Kilos vendidos a socios Club Grido. Es la base del %VCG.</summary>
    [JsonPropertyName("kilos_club")]
    public decimal KilosClub { get; set; }

    [JsonPropertyName("anuladas")]
    public int Anuladas { get; set; }

    [JsonPropertyName("dif_caja")]
    public decimal DifCaja { get; set; }

    /// <summary>La caja atiende delivery segun CFG_CAJA_DELIVERY.</summary>
    [JsonPropertyName("es_caja_delivery")]
    public bool EsCajaDelivery { get; set; }

    /// <summary>Sensacion termica promedio (°C) en las horas del turno. Null si no hay clima cargado.</summary>
    [JsonPropertyName("sensacion_termica")]
    public decimal? SensacionTermica { get; set; }

    /// <summary>Lluvia (mm) en las horas del turno.</summary>
    [JsonPropertyName("lluvia_mm")]
    public decimal? LluviaMm { get; set; }

    /// <summary>Sensacion termica de la sucursal en toda la jornada: va en el subtotal.</summary>
    [JsonPropertyName("suc_sensacion_termica")]
    public decimal? SucSensacionTermica { get; set; }

    /// <summary>Lluvia de la sucursal en toda la jornada: va en el subtotal.</summary>
    [JsonPropertyName("suc_lluvia_mm")]
    public decimal? SucLluviaMm { get; set; }
}
