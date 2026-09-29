using System.Text.Json.Serialization;

namespace DFGroup.Api.Models.DTOs;

/*
 * Fichero de Articulos: consulta de solo lectura del maestro de la base de
 * origen. No hay DTO de escritura a proposito: el alta y la modificacion se
 * siguen haciendo en el sistema de gestion.
 */

/// <summary>Fila del listado.</summary>
public class ArticuloFilaDto
{
    [JsonPropertyName("articulo")] public int Articulo { get; set; }
    [JsonPropertyName("codigo")] public string? Codigo { get; set; }
    [JsonPropertyName("descripcion")] public string Descripcion { get; set; } = string.Empty;
    [JsonPropertyName("tipo")] public string? Tipo { get; set; }
    [JsonPropertyName("grupo")] public int? Grupo { get; set; }
    [JsonPropertyName("grupo_descrip")] public string? GrupoDescrip { get; set; }
    [JsonPropertyName("estado")] public string? Estado { get; set; }
    [JsonPropertyName("precio")] public decimal? Precio { get; set; }
    [JsonPropertyName("costo")] public decimal? Costo { get; set; }
    [JsonPropertyName("unid_x_bulto")] public decimal? UnidXBulto { get; set; }
    [JsonPropertyName("peso")] public decimal? Peso { get; set; }

    /// <summary>Nulo si el articulo todavia no tiene codigo SAP cargado.</summary>
    [JsonPropertyName("codigo_sap")] public string? CodigoSap { get; set; }
}

/// <summary>Cabecera de la ficha.</summary>
public class ArticuloDetalleDto
{
    [JsonPropertyName("articulo")] public int Articulo { get; set; }
    [JsonPropertyName("codigo")] public string? Codigo { get; set; }
    [JsonPropertyName("descripcion")] public string Descripcion { get; set; } = string.Empty;
    [JsonPropertyName("descrip_ticket")] public string? DescripTicket { get; set; }
    [JsonPropertyName("tipo")] public string? Tipo { get; set; }
    [JsonPropertyName("estado")] public string? Estado { get; set; }
    [JsonPropertyName("fecha_estado")] public DateTime? FechaEstado { get; set; }
    [JsonPropertyName("grupo")] public int? Grupo { get; set; }
    [JsonPropertyName("grupo_descrip")] public string? GrupoDescrip { get; set; }
    [JsonPropertyName("venta_publico")] public string? VentaPublico { get; set; }
    [JsonPropertyName("iva_tasa")] public int? IvaTasa { get; set; }
    [JsonPropertyName("orden")] public int? Orden { get; set; }
    [JsonPropertyName("proveedor")] public int? Proveedor { get; set; }
    [JsonPropertyName("unid_x_bulto")] public decimal? UnidXBulto { get; set; }
    [JsonPropertyName("stock_minimo")] public decimal? StockMinimo { get; set; }
    [JsonPropertyName("peso")] public decimal? Peso { get; set; }
    [JsonPropertyName("costo")] public decimal? Costo { get; set; }
    [JsonPropertyName("precio_lista1")] public decimal? PrecioLista1 { get; set; }
    [JsonPropertyName("precio_lista2")] public decimal? PrecioLista2 { get; set; }
    [JsonPropertyName("precio_lista3")] public decimal? PrecioLista3 { get; set; }
    [JsonPropertyName("precio_gastro1")] public decimal? PrecioGastro1 { get; set; }
    [JsonPropertyName("precio_gastro2")] public decimal? PrecioGastro2 { get; set; }
    [JsonPropertyName("precio_gastro3")] public decimal? PrecioGastro3 { get; set; }
}

/// <summary>Un componente de la receta.</summary>
public class ArticuloRecetaDto
{
    [JsonPropertyName("orden")] public int Orden { get; set; }

    /// <summary>GENERICO (una categoria, como HELADO) o ARTICULO (un insumo concreto).</summary>
    [JsonPropertyName("clase")] public string Clase { get; set; } = string.Empty;

    [JsonPropertyName("componente")] public int Componente { get; set; }
    [JsonPropertyName("descripcion")] public string? Descripcion { get; set; }
    [JsonPropertyName("cantidad")] public decimal Cantidad { get; set; }

    /// <summary>Ya dividido por las unidades del bulto. Nulo para los genericos.</summary>
    [JsonPropertyName("costo_unit")] public decimal? CostoUnit { get; set; }

    [JsonPropertyName("costo_total")] public decimal? CostoTotal { get; set; }
}

/// <summary>
/// Relacion del articulo con el codigo SAP de Grido Central.
/// Es lo unico editable de la ficha y vive en el DWH, no en la base de origen:
/// esa se restaura entera todos los dias y se llevaria puesto lo cargado.
/// </summary>
public class ArticuloSapDto
{
    [JsonPropertyName("codigo_sap")] public string? CodigoSap { get; set; }
    [JsonPropertyName("descripcion_sap")] public string? DescripcionSap { get; set; }
    [JsonPropertyName("unidad_sap")] public string? UnidadSap { get; set; }

    /// <summary>Cuantas unidades SAP equivalen a una unidad local. 1 salvo que difieran.</summary>
    [JsonPropertyName("factor_sap")] public decimal FactorSap { get; set; } = 1;

    [JsonPropertyName("observaciones")] public string? Observaciones { get; set; }
    [JsonPropertyName("activo")] public bool Activo { get; set; } = true;
    [JsonPropertyName("usuario_alta")] public string? UsuarioAlta { get; set; }
    [JsonPropertyName("fecha_alta")] public DateTime? FechaAlta { get; set; }
    [JsonPropertyName("usuario_mod")] public string? UsuarioMod { get; set; }
    [JsonPropertyName("fecha_mod")] public DateTime? FechaMod { get; set; }
}

/// <summary>Lo que se manda al guardar el mapeo.</summary>
public class GuardarArticuloSapRequest
{
    [JsonPropertyName("codigo_sap")] public string CodigoSap { get; set; } = string.Empty;
    [JsonPropertyName("descripcion_sap")] public string? DescripcionSap { get; set; }
    [JsonPropertyName("unidad_sap")] public string? UnidadSap { get; set; }
    [JsonPropertyName("factor_sap")] public decimal FactorSap { get; set; } = 1;
    [JsonPropertyName("observaciones")] public string? Observaciones { get; set; }
    [JsonPropertyName("activo")] public bool Activo { get; set; } = true;
}

/// <summary>La ficha completa.</summary>
public class ArticuloFichaDto
{
    [JsonPropertyName("detalle")] public ArticuloDetalleDto? Detalle { get; set; }
    [JsonPropertyName("receta")] public IEnumerable<ArticuloRecetaDto> Receta { get; set; } = [];

    /// <summary>Nulo si el articulo todavia no tiene codigo SAP cargado.</summary>
    [JsonPropertyName("sap")] public ArticuloSapDto? Sap { get; set; }
}
