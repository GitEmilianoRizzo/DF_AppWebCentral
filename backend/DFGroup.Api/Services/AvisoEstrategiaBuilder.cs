using System.Globalization;
using System.Net;
using System.Text;
using DFGroup.Api.Models.DTOs;

namespace DFGroup.Api.Services;

/// <summary>
/// Arma el mail que recibe el responsable de cada local.
/// </summary>
/// <remarks>
/// CADA UNO RECIBE LO SUYO
/// -----------------------
/// El responsable de Fiorito recibe las acciones de Fiorito mas las que
/// aplican a todas las sucursales, y nada mas. Mandarles a los cuatro la lista
/// completa obliga a cada uno a filtrar mentalmente lo que no le toca, y lo
/// que se lee en diagonal no se ejecuta.
///
/// SOLO LO ACEPTADO
/// ----------------
/// Lo que Damian descarto no viaja. Una sugerencia descartada que igual llega
/// al local convierte el aviso en una lista de opciones, y deja de ser una
/// instruccion.
///
/// VA LA EVIDENCIA
/// ---------------
/// Cada accion lleva debajo el numero que la respalda. Es la diferencia entre
/// "reforza tortas el jueves" y "reforza tortas el jueves porque con lluvia
/// bocha cae a 0,84 y tortas se sostiene en 1,00". Lo segundo se discute; lo
/// primero solo se obedece o se ignora.
/// </remarks>
public static class AvisoEstrategiaBuilder
{
    private static readonly CultureInfo Ar = CultureInfo.GetCultureInfo("es-AR");

    private static readonly Dictionary<string, string> RotuloMetrica = new()
    {
        ["FACTURACION"] = "subir facturación",
        ["MARGEN"] = "subir margen",
        ["KILOS"] = "liquidar kilos",
    };

    private static readonly Dictionary<string, string> ColorTipo = new()
    {
        ["OPERATIVO"] = "#2E6F8E",
        ["PROMO"] = "#C9A227",
        ["SOBREVENTA"] = "#6B5B95",
        ["MIX"] = "#4A7C59",
    };

    /// <summary>Escapa el texto: lo escribe una persona y termina dentro de HTML.</summary>
    private static string E(string? s) => WebUtility.HtmlEncode(s ?? string.Empty);

    private static string Fecha(DateTime d) => d.ToString("dd/MM/yyyy", Ar);

    private static string DiaLargo(DateTime d) =>
        Ar.DateTimeFormat.GetDayName(d.DayOfWeek) + " " + d.ToString("dd/MM", Ar);

    /// <summary>
    /// Compone el mail de una sucursal. Devuelve null si no hay nada que
    /// avisarle: un mail que dice "no hay acciones" solo entrena a ignorarlos.
    /// </summary>
    public static MailSalida? Armar(
        ObjetivoFilaDto objetivo,
        ObjetivoSucursalDto sucursal,
        string nombreSucursal,
        IEnumerable<SugerenciaDto> sugerencias,
        string? copiaA)
    {
        // Las suyas y las que aplican a todas. Ordenadas por fecha: el
        // responsable las va a leer como una agenda, no como un informe.
        var suyas = sugerencias
            .Where(s => s.Estado == "ACEPTADA"
                        && (s.Sucursal is null || s.Sucursal == sucursal.Sucursal))
            .OrderBy(s => s.Fecha ?? DateTime.MinValue)
            .ThenBy(s => s.Tipo)
            .ToList();

        if (suyas.Count == 0) return null;
        if (string.IsNullOrWhiteSpace(sucursal.Mail)) return null;

        var metrica = RotuloMetrica.GetValueOrDefault(objetivo.Metrica, objetivo.Metrica.ToLowerInvariant());
        var asunto = $"{nombreSucursal} - {objetivo.Nombre} ({Fecha(objetivo.FechaDesde)} al {Fecha(objetivo.FechaHasta)})";

        var b = new StringBuilder();
        b.Append("""
            <div style="font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#222;max-width:640px">
            """);

        // ----------------------------------------------------------- cabecera
        b.Append($"""
            <div style="border-left:4px solid #C9A227;padding:2px 0 2px 12px;margin-bottom:18px">
              <div style="font-size:18px;font-weight:600">{E(objetivo.Nombre)}</div>
              <div style="color:#666;margin-top:2px">
                {E(nombreSucursal)} &middot; objetivo: {E(metrica)}
                &middot; del {Fecha(objetivo.FechaDesde)} al {Fecha(objetivo.FechaHasta)}
              </div>
            </div>
            """);

        if (!string.IsNullOrWhiteSpace(sucursal.Responsable))
            b.Append($"<p>Hola {E(sucursal.Responsable)}:</p>");

        // -------------------------------------------------------------- meta
        var meta = sucursal.MetaPct;
        b.Append($"""
            <table style="border-collapse:collapse;margin:14px 0;width:100%">
              <tr>
                <td style="background:#F7F5F0;border:1px solid #E6E1D6;padding:12px 14px">
                  <div style="font-size:12px;color:#666;text-transform:uppercase;letter-spacing:.5px">
                    Meta de {E(nombreSucursal)}
                  </div>
                  <div style="font-size:26px;font-weight:600;color:{(meta > 0 ? "#2F7A4F" : meta < 0 ? "#B23B2E" : "#666")};margin-top:2px">
                    {(meta > 0 ? "+" : "")}{meta.ToString("0.#", Ar)}%
                  </div>
                  <div style="font-size:12px;color:#666;margin-top:4px">
                    Sobre lo <strong>esperado para el clima de cada día</strong>, no sobre la
                    semana pasada. Un día frío con la venta que corresponde a un día frío
                    cumple; un día de calor con venta floja, no.
                  </div>
                </td>
              </tr>
            </table>
            """);

        // ------------------------------------------------------------ acciones
        b.Append($"""
            <div style="font-size:12px;color:#666;text-transform:uppercase;letter-spacing:.5px;margin:22px 0 8px">
              {suyas.Count} {(suyas.Count == 1 ? "acción para esta ventana" : "acciones para esta ventana")}
            </div>
            """);

        foreach (var s in suyas)
        {
            var color = ColorTipo.GetValueOrDefault(s.Tipo, "#888");
            var cuando = s.Fecha.HasValue ? DiaLargo(s.Fecha.Value) : "Toda la ventana";
            var alcance = s.Sucursal is null ? " &middot; aplica a todas las sucursales" : "";

            b.Append($"""
                <div style="border:1px solid #E5E5E5;border-left:3px solid {color};padding:10px 12px;margin-bottom:8px">
                  <div style="font-size:11px;color:#888;text-transform:uppercase;letter-spacing:.5px">
                    {E(cuando)}{alcance}
                  </div>
                  <div style="font-weight:600;margin-top:3px">{E(s.Titulo)}</div>
                """);

            if (!string.IsNullOrWhiteSpace(s.Detalle))
                b.Append($"""<div style="margin-top:3px;color:#444">{E(s.Detalle)}</div>""");

            if (!string.IsNullOrWhiteSpace(s.Evidencia))
                b.Append($"""
                    <div style="margin-top:7px;padding-left:9px;border-left:2px solid #DDD;font-size:12px;color:#777">
                      {E(s.Evidencia)}
                    </div>
                    """);

            b.Append("</div>");
        }

        if (!string.IsNullOrWhiteSpace(objetivo.Notas))
            b.Append($"""
                <div style="margin-top:18px;font-size:13px;color:#555">
                  <strong>Nota:</strong> {E(objetivo.Notas)}
                </div>
                """);

        // ------------------------------------------------------------- cierre
        b.Append("""
            <div style="margin-top:24px;padding-top:12px;border-top:1px solid #E5E5E5;font-size:12px;color:#888">
              La medición llega sola: todos los días se compara lo que vendió el local
              contra lo que correspondía al clima que hubo. No hay que cargar nada.
              <br><br>
              Mensaje automático de la app de DF Group. Si algo de esto no se puede hacer,
              respondé este mail y se ajusta.
            </div>
            </div>
            """);

        return new MailSalida(sucursal.Mail!, asunto, b.ToString(), copiaA);
    }
}
