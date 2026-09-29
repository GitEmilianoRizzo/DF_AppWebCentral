using System.Text.Json.Serialization;

namespace DFGroup.Api.Models.DTOs;

/*
 * Modulo de Estrategia.
 *
 * El circuito: Damian declara un objetivo con una metrica y una ventana, fija
 * una meta por sucursal, el motor propone acciones con la evidencia al lado, y
 * despues se mide lo hecho contra lo esperado DADO EL CLIMA QUE HUBO.
 *
 * La meta se expresa en PORCENTAJE sobre lo esperado y no como monto fijo:
 * "vender diez millones" depende de si hace frio o calor y no mide gestion;
 * "+5% sobre lo que corresponde a este clima" si.
 */

public class ObjetivoFilaDto
{
    [JsonPropertyName("objetivo_id")] public int ObjetivoId { get; set; }
    [JsonPropertyName("nombre")] public string Nombre { get; set; } = string.Empty;

    /// <summary>FACTURACION, MARGEN o KILOS. Cambia que sugiere el motor.</summary>
    [JsonPropertyName("metrica")] public string Metrica { get; set; } = string.Empty;

    [JsonPropertyName("fecha_desde")] public DateTime FechaDesde { get; set; }
    [JsonPropertyName("fecha_hasta")] public DateTime FechaHasta { get; set; }
    [JsonPropertyName("estado")] public string Estado { get; set; } = string.Empty;
    [JsonPropertyName("notas")] public string? Notas { get; set; }
    [JsonPropertyName("creado_por")] public string? CreadoPor { get; set; }
    [JsonPropertyName("creado_el")] public DateTime CreadoEl { get; set; }
    [JsonPropertyName("avisado_el")] public DateTime? AvisadoEl { get; set; }
    [JsonPropertyName("sucursales")] public int Sucursales { get; set; }
    [JsonPropertyName("sugerencias")] public int Sugerencias { get; set; }
    [JsonPropertyName("pendientes")] public int Pendientes { get; set; }

    /// <summary>Negativo: la ventana ya paso y el objetivo sigue abierto.</summary>
    [JsonPropertyName("dias_restantes")] public int DiasRestantes { get; set; }
}

public class ObjetivoSucursalDto
{
    [JsonPropertyName("sucursal")] public int Sucursal { get; set; }
    [JsonPropertyName("meta_pct")] public decimal MetaPct { get; set; }
    [JsonPropertyName("responsable")] public string? Responsable { get; set; }
    [JsonPropertyName("mail")] public string? Mail { get; set; }
    [JsonPropertyName("notas")] public string? Notas { get; set; }

    /// <summary>Cuando se le aviso a ESTA sucursal. Nulo = todavia no.</summary>
    [JsonPropertyName("avisado_el")] public DateTime? AvisadoEl { get; set; }

    /// <summary>
    /// El error tipico del modelo acumulado sobre una ventana de este largo.
    /// Es el piso de lo medible: una meta por debajo no se distingue del ruido.
    /// </summary>
    [JsonPropertyName("ruido_ventana_pct")] public decimal? RuidoVentanaPct { get; set; }
}

public class SugerenciaDto
{
    [JsonPropertyName("sugerencia_id")] public int SugerenciaId { get; set; }

    /// <summary>Nulo = aplica a todas las sucursales del objetivo.</summary>
    [JsonPropertyName("sucursal")] public int? Sucursal { get; set; }

    /// <summary>Nulo = vale para toda la ventana, no para un dia puntual.</summary>
    [JsonPropertyName("fecha")] public DateTime? Fecha { get; set; }

    /// <summary>OPERATIVO, PROMO, SOBREVENTA o MIX.</summary>
    [JsonPropertyName("tipo")] public string Tipo { get; set; } = string.Empty;

    [JsonPropertyName("titulo")] public string Titulo { get; set; } = string.Empty;
    [JsonPropertyName("detalle")] public string? Detalle { get; set; }

    /// <summary>El numero que respalda la sugerencia, tal como estaba al generarla.</summary>
    [JsonPropertyName("evidencia")] public string? Evidencia { get; set; }

    [JsonPropertyName("estado")] public string Estado { get; set; } = string.Empty;
    [JsonPropertyName("decidido_por")] public string? DecididoPor { get; set; }
    [JsonPropertyName("decidido_el")] public DateTime? DecididoEl { get; set; }
    [JsonPropertyName("comentario")] public string? Comentario { get; set; }
}

public class ObjetivoDetalleDto
{
    [JsonPropertyName("objetivo")] public ObjetivoFilaDto? Objetivo { get; set; }
    [JsonPropertyName("sucursales")] public IEnumerable<ObjetivoSucursalDto> Sucursales { get; set; } = [];
    [JsonPropertyName("sugerencias")] public IEnumerable<SugerenciaDto> Sugerencias { get; set; } = [];
}

public class CrearObjetivoRequest
{
    [JsonPropertyName("nombre")] public string Nombre { get; set; } = string.Empty;
    [JsonPropertyName("metrica")] public string Metrica { get; set; } = string.Empty;
    [JsonPropertyName("fecha_desde")] public DateTime FechaDesde { get; set; }
    [JsonPropertyName("fecha_hasta")] public DateTime FechaHasta { get; set; }
    [JsonPropertyName("notas")] public string? Notas { get; set; }
    [JsonPropertyName("sucursales")] public List<ObjetivoSucursalDto> Sucursales { get; set; } = [];
}

public class DecidirSugerenciaRequest
{
    [JsonPropertyName("estado")] public string Estado { get; set; } = string.Empty;
    [JsonPropertyName("comentario")] public string? Comentario { get; set; }
}

/* ---------------------------------------------------------------------------
 * Medicion: objetivo contra realidad.
 *
 * El desvio NUNCA viaja solo. Va con el ruido al lado, porque un +8% sobre un
 * modelo que se equivoca +-10% no dice nada, y sin ese numero cualquiera lo
 * leeria como un logro.
 * --------------------------------------------------------------------------- */

/// <summary>El acumulado de una sucursal en la ventana del objetivo.</summary>
public class MedicionSucursalDto
{
    [JsonPropertyName("sucursal")] public int Sucursal { get; set; }
    [JsonPropertyName("meta_pct")] public decimal MetaPct { get; set; }
    [JsonPropertyName("dias")] public int Dias { get; set; }
    [JsonPropertyName("dias_cumplidos")] public int DiasCumplidos { get; set; }
    [JsonPropertyName("esperado")] public decimal Esperado { get; set; }
    [JsonPropertyName("real")] public decimal Real { get; set; }
    [JsonPropertyName("desvio_pct")] public decimal? DesvioPct { get; set; }
    [JsonPropertyName("cumple")] public bool Cumple { get; set; }

    /// <summary>Cuanto se equivoca el modelo en UN dia, tipicamente.</summary>
    [JsonPropertyName("error_tipico_pct")] public decimal? ErrorTipicoPct { get; set; }

    /// <summary>Lo mismo acumulado sobre la ventana. Es el piso de lo medible.</summary>
    [JsonPropertyName("ruido_ventana_pct")] public decimal? RuidoVentanaPct { get; set; }

    /// <summary>
    /// False cuando el desvio no se despega del ruido: el resultado no dice ni
    /// que cumplio ni que fallo, y presentarlo como un veredicto seria mentir.
    /// </summary>
    [JsonPropertyName("concluyente")] public bool Concluyente { get; set; }
}

/// <summary>Un dia medido.</summary>
public class MedicionDiaDto
{
    [JsonPropertyName("sucursal")] public int Sucursal { get; set; }
    [JsonPropertyName("fecha")] public DateTime Fecha { get; set; }
    [JsonPropertyName("tmax")] public decimal? TMax { get; set; }
    [JsonPropertyName("tmax_ayer")] public decimal? TMaxAyer { get; set; }
    [JsonPropertyName("llovio")] public bool? Llovio { get; set; }

    /// <summary>Que porcentaje de la venta del dia cayo en horas con lluvia.</summary>
    [JsonPropertyName("expos_lluvia")] public decimal? ExposLluvia { get; set; }

    [JsonPropertyName("factor_salto")] public decimal? FactorSalto { get; set; }
    [JsonPropertyName("esperado")] public decimal? Esperado { get; set; }
    [JsonPropertyName("real")] public decimal? Real { get; set; }
    [JsonPropertyName("desvio_pct")] public decimal? DesvioPct { get; set; }
    [JsonPropertyName("meta_pct")] public decimal? MetaPct { get; set; }
    [JsonPropertyName("cumple")] public bool? Cumple { get; set; }
    [JsonPropertyName("error_tipico_pct")] public decimal? ErrorTipicoPct { get; set; }

    /// <summary>Con que precision se estimo. Un nivel flojo hay que verlo.</summary>
    [JsonPropertyName("nivel_modelo")] public string? NivelModelo { get; set; }

    [JsonPropertyName("calculado_el")] public DateTime CalculadoEl { get; set; }
}

public class MedicionDto
{
    [JsonPropertyName("sucursales")] public IEnumerable<MedicionSucursalDto> Sucursales { get; set; } = [];
    [JsonPropertyName("dias")] public IEnumerable<MedicionDiaDto> Dias { get; set; } = [];
}

/// <summary>Como le fue al aviso de una sucursal.</summary>
public class AvisoSucursalDto
{
    [JsonPropertyName("sucursal")] public int Sucursal { get; set; }
    [JsonPropertyName("nombre")] public string Nombre { get; set; } = string.Empty;
    [JsonPropertyName("mail")] public string? Mail { get; set; }
    [JsonPropertyName("enviado")] public bool Enviado { get; set; }

    /// <summary>Cuantas acciones le tocaban. Cero explica un envio omitido.</summary>
    [JsonPropertyName("acciones")] public int Acciones { get; set; }

    /// <summary>Por que no se envio, cuando no se envio.</summary>
    [JsonPropertyName("motivo")] public string? Motivo { get; set; }
}

public class AvisoResultadoDto
{
    [JsonPropertyName("enviados")] public int Enviados { get; set; }
    [JsonPropertyName("omitidos")] public int Omitidos { get; set; }
    [JsonPropertyName("detalle")] public IEnumerable<AvisoSucursalDto> Detalle { get; set; } = [];

    /// <summary>El objetivo ya actualizado, para que la pantalla no tenga que recargar.</summary>
    [JsonPropertyName("objetivo")] public ObjetivoDetalleDto? Objetivo { get; set; }
}

/// <summary>Un dia del pronostico, como lo consume la pantalla.</summary>
public class PronosticoDiaDto
{
    [JsonPropertyName("sucursal")] public int Sucursal { get; set; }
    [JsonPropertyName("dia")] public DateTime Dia { get; set; }
    [JsonPropertyName("dia_semana")] public int DiaSemana { get; set; }
    [JsonPropertyName("tmax")] public decimal? TMax { get; set; }
    [JsonPropertyName("tmin")] public decimal? TMin { get; set; }

    /// <summary>Maxima del dia anterior: es lo que define el salto termico.</summary>
    [JsonPropertyName("tmax_ayer")] public decimal? TMaxAyer { get; set; }

    [JsonPropertyName("llueve")] public int Llueve { get; set; }
    [JsonPropertyName("horas_lluvia")] public int HorasLluvia { get; set; }
    [JsonPropertyName("lluvia_mm")] public decimal? LluviaMm { get; set; }

    /// <summary>
    /// Que porcentaje de la venta del dia cae en horas con lluvia.
    /// </summary>
    /// <remarks>
    /// Es LA variable de lluvia, no <c>Llueve</c>. Medido sobre 2024-2026, un
    /// dia con menos del 10% expuesto no se distingue de uno seco y uno con mas
    /// de la mitad vende ~30% menos que un dia seco de la misma temperatura.
    /// Once horas de lluvia de madrugada y doce encima de la tarde dan el mismo
    /// <c>Llueve</c> y son dias opuestos.
    /// </remarks>
    [JsonPropertyName("exposicion")] public decimal? Exposicion { get; set; }

    /// <summary>0 nada · 1 hasta 10% · 2 10-25% · 3 25-50% · 4 mas de 50%.</summary>
    [JsonPropertyName("tramo_lluvia")] public int? TramoLluvia { get; set; }

    /// <summary>Cuanto cuesta ese tramo contra un dia seco, en esa sucursal.</summary>
    [JsonPropertyName("impacto_pct")] public decimal? ImpactoPct { get; set; }

    /// <summary>Dias de anticipacion con que se hizo. Mas alto, menos confiable.</summary>
    [JsonPropertyName("anticipacion")] public int Anticipacion { get; set; }
}
