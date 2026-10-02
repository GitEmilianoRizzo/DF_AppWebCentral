"""
Informe Diario GRIDO - Version desatendida (CLI)
================================================
Genera el Informe Diario de Ventas y lo envia por mail. Pensado para correr
desde el Programador de tareas de Windows, sin intervencion humana.

Reutiliza exactamente la misma logica de consulta y armado de Excel que la
app Streamlit (informe_grido.py), asi los dos caminos no se desincronizan.

El mail y la copia al historico de Drive son dos entregas INDEPENDIENTES: se
intentan las dos siempre y ninguna aborta a la otra.

Uso:
    python informe_cli.py                      # informe de ayer: mail + copia a Drive
    python informe_cli.py --fecha 2026-08-30   # una fecha puntual
    python informe_cli.py --sin-mail           # no manda mail, pero si copia a Drive
    python informe_cli.py --sin-drive          # manda mail, pero no copia a Drive
    python informe_cli.py --sin-mail --sin-drive   # solo genera el Excel (para probar)
    python informe_cli.py --a otro@dominio.com # override de destinatarios

Codigos de salida:
    0 = OK
    1 = error de configuracion o de argumentos
    2 = error de base de datos
    3 = error al armar el Excel
    4 = fallo el mail (la copia a Drive si se hizo)
    5 = fallo la copia al historico de Google Drive (el mail si salio)
    6 = fallaron las dos entregas (el Excel igual quedo en la carpeta salidas)
    7 = el informe salio VACIO: no se envio y se mando una alerta de ERROR
    8 = el informe salio vacio y ademas fallo el envio de la alerta

Un informe sin ventas NO se envia: se avisa por mail a los responsables
tecnicos ([correo] destinatarios_alerta) con el diagnostico de la causa. El
umbral esta en [control] tickets_minimos y --forzar-envio lo saltea.
"""

import argparse
import configparser
import logging
import mimetypes
import os
import shutil
import smtplib
import ssl
import subprocess
import sys
import traceback
import warnings
from datetime import datetime, timedelta
from email.message import EmailMessage

# pandas avisa en cada consulta que preferiria SQLAlchemy antes que una conexion
# pyodbc cruda. Funciona igual, pero repetido 5 veces por corrida ensucia el log
# de la tarea programada y tapa los errores que si importan.
warnings.filterwarnings(
    "ignore", message=".*only supports SQLAlchemy connectable.*")

# El import de informe_grido arrastra streamlit, que se queja de que lo estamos
# usando fuera de un servidor ("missing ScriptRunContext"). Es inofensivo pero
# ensucia el log de la tarea programada, asi que lo callamos antes de importar.
logging.getLogger("streamlit").setLevel(logging.ERROR)
logging.getLogger(
    "streamlit.runtime.scriptrunner_utils.script_run_context").setLevel(logging.ERROR)

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BASE_DIR)

import informe_grido as ig  # noqa: E402

CONFIG_PATH = os.path.join(BASE_DIR, "config.ini")
DIR_SALIDAS = os.path.join(BASE_DIR, "salidas")
DIR_LOGS = os.path.join(BASE_DIR, "logs")

log = logging.getLogger("informe")


# ---------------------------------------------------------------------------
# Configuracion y logging
# ---------------------------------------------------------------------------
def configurar_logging(fecha_ejecucion):
    os.makedirs(DIR_LOGS, exist_ok=True)
    ruta = os.path.join(DIR_LOGS, f"informe_{fecha_ejecucion:%Y-%m-%d}.log")

    fmt = logging.Formatter("%(asctime)s [%(levelname)s] %(message)s",
                            datefmt="%Y-%m-%d %H:%M:%S")
    log.setLevel(logging.INFO)
    log.handlers.clear()

    fh = logging.FileHandler(ruta, encoding="utf-8")
    fh.setFormatter(fmt)
    log.addHandler(fh)

    sh = logging.StreamHandler(sys.stdout)
    sh.setFormatter(fmt)
    log.addHandler(sh)

    return ruta


def cargar_config():
    if not os.path.exists(CONFIG_PATH):
        raise SystemExit(
            f"[ERROR] No existe el archivo de configuracion:\n  {CONFIG_PATH}\n"
            "Copie config.ini.ejemplo a config.ini y complete los valores.")
    cfg = configparser.ConfigParser()
    # "utf-8-sig" y no "utf-8": varios editores de Windows (el Bloc de notas y
    # cualquier cosa que pase por Set-Content -Encoding UTF8 de PowerShell 5.1)
    # graban un BOM al principio. Leyendo como "utf-8" ese BOM se pega al primer
    # "[" y configparser tira MissingSectionHeaderError, un error que no dice
    # nada sobre la causa real. "utf-8-sig" lo saca si esta y no molesta si no.
    cfg.read(CONFIG_PATH, encoding="utf-8-sig")
    for seccion in ("base_datos", "correo"):
        if not cfg.has_section(seccion):
            raise SystemExit(
                f"[ERROR] Falta la seccion [{seccion}] en {CONFIG_PATH}")
    return cfg


# ---------------------------------------------------------------------------
# Generacion del informe
# ---------------------------------------------------------------------------
def generar_informe(cfg, fecha_informe, hora_corte):
    """Consulta la base y devuelve (datos_por_sucursal, resumen)."""
    srv = cfg.get("base_datos", "servidor")
    db = cfg.get("base_datos", "base")
    usuario = cfg.get("base_datos", "usuario", fallback="").strip() or None
    clave = cfg.get("base_datos", "clave", fallback="").strip() or None

    log.info("Conectando a %s / %s (%s)", srv, db,
             "usuario SQL" if usuario else "autenticacion Windows")
    conn = ig.get_connection(srv, db, usuario, clave)
    if conn is None or not ig.test_connection(conn):
        raise ConnectionError(
            f"No se pudo conectar a {srv} / {db}. "
            "Revise servidor, base y permisos en config.ini.")

    # Mismo criterio de dia operativo que la app Streamlit: el periodo arranca
    # a la hora de corte de la fecha del informe y termina a la hora de corte
    # del dia siguiente. Sale de informe_grido para que los dos caminos no se
    # puedan desincronizar.
    fecha_inicio, fecha_fin = ig.rango_dia_operativo(fecha_informe, hora_corte)
    log.info("Periodo consultado: %s -> %s", fecha_inicio, fecha_fin)

    try:
        suc_map = ig.get_sucursales(conn)
        df_ventas = ig.get_ventas(conn, fecha_inicio, fecha_fin)
        log.info("Ventas: %d filas", len(df_ventas))
        df_kilos = ig.get_detventas_kilos(conn, fecha_inicio, fecha_fin)
        log.info("Kilos: %d grupos", len(df_kilos))
        df_turnos = ig.get_turnos(conn, fecha_inicio, fecha_fin)
        log.info("Turnos: %d filas", len(df_turnos))
        df_tarjetas = ig.get_tarjetas(conn, fecha_inicio, fecha_fin)
        log.info("Tarjetas: %d filas", len(df_tarjetas))
    finally:
        try:
            conn.close()
        except Exception:
            pass

    if df_ventas.empty:
        log.warning("La consulta no devolvio ventas para el periodo pedido.")

    turnos = ig.procesar_ventas(df_ventas, suc_map)
    kilos = ig.procesar_kilos(df_kilos, suc_map)
    extra = ig.procesar_turnos_extra(df_turnos, suc_map)
    socios = ig.procesar_socios(df_tarjetas, suc_map)
    datos = ig.ensamblar(turnos, kilos, socios, extra)

    resumen = armar_resumen(datos, fecha_inicio, fecha_fin)
    return datos, resumen


def armar_resumen(datos, fecha_inicio, fecha_fin):
    """Totales para el cuerpo del mail."""
    filas = []
    tot = {"ventas": 0.0, "tickets": 0, "kilos": 0.0, "socios": 0, "cajeros": 0}

    for suc in ig.ORDEN_SUC:
        f = datos.get(suc, [])
        d = {
            "sucursal": ig.SUC_DISPLAY.get(suc, suc),
            "ventas": sum(x["ventas"] for x in f),
            "tickets": sum(x["tickets"] for x in f),
            "kilos": sum(x["kilos"] for x in f),
            "socios": sum(x["socios"] for x in f),
            "cajeros": len(f),
        }
        d["ticket_prom"] = d["ventas"] / d["tickets"] if d["tickets"] else 0
        filas.append(d)
        for k in tot:
            tot[k] += d[k]

    tot["ticket_prom"] = tot["ventas"] / tot["tickets"] if tot["tickets"] else 0
    tot["sucursal"] = "TOTAL"
    return {"filas": filas, "total": tot,
            "desde": fecha_inicio, "hasta": fecha_fin}


def guardar_excel(datos, fecha_informe):
    os.makedirs(DIR_SALIDAS, exist_ok=True)
    wb = ig.construir_excel(datos, fecha_informe.strftime("%d/%m/%Y"))
    ruta = os.path.join(DIR_SALIDAS,
                        f"{fecha_informe:%Y-%m-%d}_InformeDiarioGRIDO.xlsx")
    wb.save(ruta)
    log.info("Excel generado: %s (%d bytes)", ruta, os.path.getsize(ruta))
    return ruta


# ---------------------------------------------------------------------------
# Correo
# ---------------------------------------------------------------------------
def _ar(valor, decimales=0):
    """Formatea un numero al estilo argentino: 1.234.567,8"""
    s = f"{valor:,.{decimales}f}"          # 1,234,567.8  (estilo ingles)
    return s.replace(",", "\x00").replace(".", ",").replace("\x00", ".")


def _pesos(v):
    return "$" + _ar(v, 0)


def cuerpo_html(resumen, fecha_informe):
    td = "padding:8px 12px;border-bottom:1px solid #e5e7eb"
    tdr = td + ";text-align:right"

    filas_html = []
    for d in resumen["filas"]:
        filas_html.append(
            "<tr>"
            f"<td style='{td}'>{d['sucursal']}</td>"
            f"<td style='{tdr}'>{_pesos(d['ventas'])}</td>"
            f"<td style='{tdr}'>{_ar(d['tickets'])}</td>"
            f"<td style='{tdr}'>{_pesos(d['ticket_prom'])}</td>"
            f"<td style='{tdr}'>{_ar(d['kilos'], 1)}</td>"
            f"<td style='{tdr}'>{d['socios']}</td>"
            "</tr>")

    t = resumen["total"]
    tt = "padding:10px 12px"
    ttr = tt + ";text-align:right"
    total_html = (
        "<tr style='background:#1e2d3d;color:#fff;font-weight:bold'>"
        f"<td style='{tt}'>TOTAL</td>"
        f"<td style='{ttr}'>{_pesos(t['ventas'])}</td>"
        f"<td style='{ttr}'>{_ar(t['tickets'])}</td>"
        f"<td style='{ttr}'>{_pesos(t['ticket_prom'])}</td>"
        f"<td style='{ttr}'>{_ar(t['kilos'], 1)}</td>"
        f"<td style='{ttr}'>{t['socios']}</td>"
        "</tr>")

    return f"""<html><body style="margin:0;padding:24px;background:#f4f5f7;
font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;color:#1a1a2e">
<div style="max-width:720px;margin:0 auto;background:#fff;border-radius:10px;overflow:hidden;
box-shadow:0 1px 3px rgba(0,0,0,.12)">
  <div style="background:#1e2d3d;color:#fff;padding:20px 24px">
    <div style="font-size:19px;font-weight:700">GRIDO &middot; Informe Diario de Ventas</div>
    <div style="font-size:13px;color:#bdc3c7;margin-top:4px">Fecha del informe: {fecha_informe:%d/%m/%Y}</div>
  </div>
  <div style="padding:20px 24px">
    <p style="margin:0 0 16px;font-size:14px;color:#5d6d7e">
      Periodo cubierto: <strong>{resumen['desde']:%d/%m/%Y %H:%M}</strong> a
      <strong>{resumen['hasta']:%d/%m/%Y %H:%M}</strong>.
    </p>
    <table style="width:100%;border-collapse:collapse;font-size:14px">
      <thead>
        <tr style="background:#455a64;color:#fff;font-size:12px;text-transform:uppercase">
          <th style="padding:10px 12px;text-align:left">Sucursal</th>
          <th style="padding:10px 12px;text-align:right">Ventas</th>
          <th style="padding:10px 12px;text-align:right">Tickets</th>
          <th style="padding:10px 12px;text-align:right">Ticket prom.</th>
          <th style="padding:10px 12px;text-align:right">Kilos</th>
          <th style="padding:10px 12px;text-align:right">Socios</th>
        </tr>
      </thead>
      <tbody>{''.join(filas_html)}{total_html}</tbody>
    </table>
    <p style="margin:20px 0 0;font-size:13px;color:#5d6d7e">
      El detalle por cajero y turno esta en el Excel adjunto.
    </p>
  </div>
  <div style="padding:14px 24px;background:#f8f9fa;border-top:1px solid #e5e7eb;
font-size:12px;color:#9fa8b0">
    Generado automaticamente el {datetime.now():%d/%m/%Y a las %H:%M}.
  </div>
</div>
</body></html>"""


def cuerpo_texto(resumen, fecha_informe):
    lineas = [
        f"GRIDO - Informe Diario de Ventas",
        f"Fecha del informe: {fecha_informe:%d/%m/%Y}",
        f"Periodo: {resumen['desde']:%d/%m/%Y %H:%M} a {resumen['hasta']:%d/%m/%Y %H:%M}",
        "",
    ]
    for d in resumen["filas"]:
        lineas.append(
            f"{d['sucursal']:<14} {_pesos(d['ventas']):>14} | "
            f"{d['tickets']:>5} tickets | {_ar(d['kilos'], 1):>9} kg | {d['socios']} socios")
    t = resumen["total"]
    lineas += [
        "",
        f"{'TOTAL':<14} {_pesos(t['ventas']):>14} | {t['tickets']:>5} tickets | "
        f"{_ar(t['kilos'], 1):>9} kg | {t['socios']} socios",
        f"Ticket promedio: {_pesos(t['ticket_prom'])}",
        "",
        "El detalle por cajero y turno esta en el Excel adjunto.",
    ]
    return "\n".join(lineas)


def enviar_mail(cfg, adjunto, resumen, fecha_informe, destinatarios=None):
    host = cfg.get("correo", "servidor", fallback="smtp.gmail.com")
    puerto = cfg.getint("correo", "puerto", fallback=587)
    remitente = cfg.get("correo", "remitente")
    # Google muestra la contrasena de aplicacion en 4 grupos de 4 por comodidad
    # visual, pero los espacios no son parte de la credencial. Los sacamos para
    # que de igual como se haya pegado.
    clave = "".join(cfg.get("correo", "clave", fallback="").split())
    usuario = cfg.get("correo", "usuario", fallback="").strip() or remitente

    if destinatarios is None:
        crudo = cfg.get("correo", "destinatarios", fallback="")
        destinatarios = [x.strip() for x in crudo.replace(";", ",").split(",")
                         if x.strip()]
    if not destinatarios:
        raise ValueError("No hay destinatarios configurados.")
    if not clave or clave.upper().startswith("PEGAR"):
        raise ValueError(
            "Falta la contrasena de aplicacion de Gmail en config.ini "
            "(seccion [correo], clave). Ver LEEME_AUTOMATIZACION.md.")

    msg = EmailMessage()
    msg["Subject"] = f"Informe Diario GRIDO - {fecha_informe:%d/%m/%Y}"
    msg["From"] = remitente
    msg["To"] = ", ".join(destinatarios)
    msg.set_content(cuerpo_texto(resumen, fecha_informe))
    msg.add_alternative(cuerpo_html(resumen, fecha_informe), subtype="html")

    tipo, _ = mimetypes.guess_type(adjunto)
    maintype, subtype = (tipo.split("/", 1) if tipo
                         else ("application", "octet-stream"))
    with open(adjunto, "rb") as fh:
        msg.add_attachment(fh.read(), maintype=maintype, subtype=subtype,
                           filename=os.path.basename(adjunto))

    log.info("Enviando mail a %s via %s:%d", ", ".join(destinatarios), host, puerto)
    contexto = ssl.create_default_context()
    if puerto == 465:
        with smtplib.SMTP_SSL(host, puerto, context=contexto, timeout=60) as s:
            s.login(usuario, clave)
            s.send_message(msg)
    else:
        with smtplib.SMTP(host, puerto, timeout=60) as s:
            s.ehlo()
            s.starttls(context=contexto)
            s.ehlo()
            s.login(usuario, clave)
            s.send_message(msg)
    log.info("Mail enviado correctamente.")


# ---------------------------------------------------------------------------
# Copia al historico de Google Drive
# ---------------------------------------------------------------------------
def _resolver_lnk(ruta_lnk):
    """
    Devuelve la carpeta a la que apunta un acceso directo de Windows.

    Google Drive representa las carpetas COMPARTIDAS como archivos .lnk: lo que
    se ve como "Referentes.lnk" en realidad apunta a
    G:\\.shortcut-targets-by-id\\<id>\\Referentes. No se puede copiar "dentro"
    del .lnk, hay que resolverlo primero.

    En el venv no esta pywin32, asi que se lo pedimos al propio Windows. Es una
    sola llamada por corrida, el costo es irrelevante.
    """
    ps = ("$ErrorActionPreference='Stop';"
          "$s=(New-Object -ComObject WScript.Shell).CreateShortcut("
          f"'{ruta_lnk}'); Write-Output $s.TargetPath")
    r = subprocess.run(["powershell", "-NoProfile", "-Command", ps],
                       capture_output=True, text=True, timeout=90)
    destino = (r.stdout or "").strip()
    if r.returncode != 0 or not destino:
        raise RuntimeError(
            f"No se pudo resolver el acceso directo {ruta_lnk}: "
            f"{(r.stderr or '').strip()[:200]}")
    return destino


def copiar_a_historico(cfg, adjunto):
    """
    Copia el Excel ya enviado a la carpeta historica de Google Drive.

    Se llama DESPUES de mandar el mail a proposito: el mail es lo critico, y no
    queremos que un problema de Drive (no montado, sin espacio, sin permisos)
    impida que el informe llegue.
    """
    carpeta = cfg.get("archivo", "carpeta_historico", fallback="").strip()
    if not carpeta:
        log.info("No hay carpeta_historico configurada: se omite la copia.")
        return None

    if carpeta.lower().endswith(".lnk"):
        if not os.path.exists(carpeta):
            raise FileNotFoundError(
                f"No se ve el acceso directo {carpeta}. "
                "?Google Drive esta montado?")
        carpeta = _resolver_lnk(carpeta)
        log.info("El acceso directo apunta a: %s", carpeta)

    if not os.path.isdir(carpeta):
        raise NotADirectoryError(
            f"La carpeta de historico no existe o no es una carpeta: {carpeta}. "
            "?Google Drive esta montado?")

    destino = os.path.join(carpeta, os.path.basename(adjunto))
    shutil.copy2(adjunto, destino)

    # Drive es un sistema de archivos virtual: la escritura puede reportar exito
    # y no haber materializado el archivo. Verificamos tamanio antes de cantar
    # victoria.
    origen_bytes = os.path.getsize(adjunto)
    if not os.path.exists(destino):
        raise IOError(f"La copia no aparecio en destino: {destino}")
    destino_bytes = os.path.getsize(destino)
    if destino_bytes != origen_bytes:
        raise IOError(
            f"La copia quedo incompleta: {destino_bytes} bytes en destino "
            f"contra {origen_bytes} en origen ({destino}).")

    log.info("Copiado al historico de Drive: %s (%d bytes)",
             destino, destino_bytes)
    return destino


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def parse_args(argv=None):
    p = argparse.ArgumentParser(
        description="Genera el Informe Diario GRIDO y lo envia por mail.")
    p.add_argument("--fecha", metavar="YYYY-MM-DD",
                   help="Fecha del informe. Por defecto, ayer.")
    p.add_argument("--hora-corte", default="02:00", metavar="HH:MM",
                   help="Hora de corte del dia operativo (default: 02:00).")
    p.add_argument("--a", dest="destinatarios", metavar="MAIL",
                   help="Destinatarios separados por coma. Pisa el config.ini.")
    p.add_argument("--sin-mail", action="store_true",
                   help="No envia el mail. La copia al historico de Drive se "
                        "hace igual: sirve para rellenar la carpeta sin "
                        "molestar a los destinatarios.")
    p.add_argument("--sin-drive", action="store_true",
                   help="No copia al historico de Drive. Combinado con "
                        "--sin-mail, solo genera el Excel.")
    p.add_argument("--forzar-envio", action="store_true",
                   help="Envia el informe aunque venga sin ventas. Para el "
                        "caso raro de un dia realmente cerrado.")
    p.add_argument("--probar-mail", action="store_true",
                   help="Solo prueba el envio (mail corto, sin tocar la base). "
                        "Sirve para validar la credencial de Gmail.")
    return p.parse_args(argv)


def probar_mail(cfg, destinatarios=None):
    """Manda un mail minimo para validar la credencial, sin consultar la base."""
    host = cfg.get("correo", "servidor", fallback="smtp.gmail.com")
    puerto = cfg.getint("correo", "puerto", fallback=587)
    remitente = cfg.get("correo", "remitente")
    # Google muestra la contrasena de aplicacion en 4 grupos de 4 por comodidad
    # visual, pero los espacios no son parte de la credencial. Los sacamos para
    # que de igual como se haya pegado.
    clave = "".join(cfg.get("correo", "clave", fallback="").split())
    usuario = cfg.get("correo", "usuario", fallback="").strip() or remitente

    if destinatarios is None:
        crudo = cfg.get("correo", "destinatarios", fallback="")
        destinatarios = [x.strip() for x in crudo.replace(";", ",").split(",")
                         if x.strip()]
    if not clave or clave.upper().startswith("PEGAR"):
        raise ValueError(
            "Falta la contrasena de aplicacion de Gmail en config.ini "
            "(seccion [correo], clave). Ver LEEME_AUTOMATIZACION.md.")

    msg = EmailMessage()
    msg["Subject"] = "Prueba - Informe Diario GRIDO"
    msg["From"] = remitente
    msg["To"] = ", ".join(destinatarios)
    msg.set_content(
        "Prueba de envio del Informe Diario GRIDO.\n\n"
        "Si estas leyendo esto, la casilla y la credencial funcionan, y el "
        "informe automatico de las 13:00 va a poder salir.\n\n"
        f"Enviado el {datetime.now():%d/%m/%Y a las %H:%M} "
        "desde el equipo WIN-6ARG3SUELOE.")

    log.info("Probando envio a %s via %s:%d", ", ".join(destinatarios), host, puerto)
    contexto = ssl.create_default_context()
    if puerto == 465:
        with smtplib.SMTP_SSL(host, puerto, context=contexto, timeout=60) as s:
            s.login(usuario, clave)
            s.send_message(msg)
    else:
        with smtplib.SMTP(host, puerto, timeout=60) as s:
            s.ehlo()
            s.starttls(context=contexto)
            s.ehlo()
            s.login(usuario, clave)
            s.send_message(msg)
    log.info("Mail de prueba enviado correctamente.")


def destinatarios_alerta(cfg):
    """A quien se avisa cuando el informe sale vacio.

    Es una lista aparte de los destinatarios normales a proposito: la alerta
    es un problema tecnico y no tiene por que llegarles a los referentes de
    cada sucursal. Si no esta configurada, cae en los destinatarios comunes,
    que es preferible a que la alerta no salga.
    """
    crudo = cfg.get("correo", "destinatarios_alerta", fallback="").strip()
    if not crudo:
        log.warning("No hay 'destinatarios_alerta' en config.ini: la alerta "
                    "va a los destinatarios normales.")
        crudo = cfg.get("correo", "destinatarios", fallback="")
    return [x.strip() for x in crudo.replace(";", ",").split(",") if x.strip()]


def diagnosticar_origen(cfg):
    """Ultima venta que tiene la base de origen.

    Va dentro de la alerta porque es el dato que explica la causa nueve de
    cada diez veces: si el informe sale vacio es porque el restore no trajo
    datos nuevos, y esta fecha lo muestra de un vistazo.
    """
    try:
        conn = ig.get_connection(
            cfg.get("base_datos", "servidor"),
            cfg.get("base_datos", "base"),
            cfg.get("base_datos", "usuario", fallback="").strip() or None,
            cfg.get("base_datos", "clave", fallback="").strip() or None)
        if conn is None:
            return None
        cur = conn.cursor()
        cur.execute("SELECT MAX(VTAFECHA) FROM VENTAS")
        fila = cur.fetchone()
        return fila[0] if fila else None
    except Exception:
        log.warning("No se pudo leer la ultima venta del origen:\n%s",
                    traceback.format_exc())
        return None


def enviar_alerta(cfg, fecha_informe, resumen, ultima_venta, adjunto=None):
    """Avisa que el informe salio vacio, en vez de mandarlo.

    Un informe en cero no es un dia flojo: es que falto el dato. Mandarlo
    igual, como se hacia antes, disfraza una falla tecnica de resultado
    comercial y nadie se entera hasta que alguien lo nota por su cuenta.
    """
    host = cfg.get("correo", "servidor", fallback="smtp.gmail.com")
    puerto = cfg.getint("correo", "puerto", fallback=587)
    remitente = cfg.get("correo", "remitente")
    clave = "".join(cfg.get("correo", "clave", fallback="").split())
    usuario = cfg.get("correo", "usuario", fallback="").strip() or remitente
    destinatarios = destinatarios_alerta(cfg)

    if not destinatarios:
        raise ValueError("No hay a quien mandarle la alerta.")
    if not clave or clave.upper().startswith("PEGAR"):
        raise ValueError("Falta la contrasena de aplicacion de Gmail en config.ini.")

    t = resumen["total"]
    if ultima_venta:
        atraso = (datetime.combine(fecha_informe, datetime.min.time())
                  - datetime(ultima_venta.year, ultima_venta.month, ultima_venta.day)).days
        linea_origen = (f"  Ultima venta en la base ....... {ultima_venta:%d/%m/%Y %H:%M}\n"
                        f"  Atraso respecto del informe ... {atraso} dia(s)\n")
        if atraso >= 1:
            causa = ("La base de origen esta atrasada. Lo mas probable es que el "
                     "restore de las 12:00 no haya encontrado un backup nuevo en "
                     "la carpeta de Google Drive.")
        else:
            causa = ("La base tiene datos de la fecha, asi que el problema no es "
                     "el restore. Revisar el periodo consultado y los filtros.")
    else:
        linea_origen = "  Ultima venta en la base ....... no se pudo leer\n"
        causa = ("No se pudo consultar la base de origen. Puede estar caida, "
                 "restaurandose o sin permisos.")

    msg = EmailMessage()
    msg["Subject"] = f"ERROR - Informe Diario GRIDO {fecha_informe:%d/%m/%Y} sin datos"
    msg["From"] = remitente
    msg["To"] = ", ".join(destinatarios)
    msg.set_content(
        "El Informe Diario GRIDO se genero SIN VENTAS y por eso NO se envio a "
        "los destinatarios habituales.\n\n"
        f"  Jornada del informe ........... {fecha_informe:%d/%m/%Y}\n"
        f"  Periodo consultado ............ {resumen['desde']:%d/%m %H:%M}"
        f" a {resumen['hasta']:%d/%m %H:%M}\n"
        f"  Ventas encontradas ............ {t['ventas']:,.2f}\n"
        f"  Tickets ....................... {t['tickets']}\n"
        f"{linea_origen}"
        "\n"
        f"CAUSA PROBABLE\n{causa}\n\n"
        "QUE HACER\n"
        "  1. Verificar que haya un GESTION_*.bak nuevo en la carpeta de Drive.\n"
        "  2. Si no esta, revisar que la PC de origen lo este subiendo.\n"
        "  3. Con el backup disponible, correr la tarea 'Restore SRV_GRIDO_ZSUR',\n"
        "     despues 'PILL_huellaventaDiaria', y reenviar el informe con:\n"
        f"     TAREA_INFORME_DIARIO.bat {fecha_informe:%Y-%m-%d}\n\n"
        "El Excel vacio quedo guardado en la carpeta salidas por si se quiere\n"
        "revisar, pero no se copio al historico de Drive.\n\n"
        f"Generado el {datetime.now():%d/%m/%Y a las %H:%M} en WIN-6ARG3SUELOE.")

    log.info("Enviando ALERTA a %s", ", ".join(destinatarios))
    contexto = ssl.create_default_context()
    if puerto == 465:
        with smtplib.SMTP_SSL(host, puerto, context=contexto, timeout=60) as s:
            s.login(usuario, clave)
            s.send_message(msg)
    else:
        with smtplib.SMTP(host, puerto, timeout=60) as s:
            s.ehlo()
            s.starttls(context=contexto)
            s.ehlo()
            s.login(usuario, clave)
            s.send_message(msg)
    log.info("Alerta enviada correctamente.")


def main(argv=None):
    args = parse_args(argv)

    if args.fecha:
        try:
            fecha_informe = datetime.strptime(args.fecha, "%Y-%m-%d").date()
        except ValueError:
            print(f"[ERROR] Fecha invalida: {args.fecha!r}. Use YYYY-MM-DD.")
            return 1
    else:
        fecha_informe = (datetime.now() - timedelta(days=1)).date()

    try:
        hora_corte = datetime.strptime(args.hora_corte, "%H:%M").time()
    except ValueError:
        print(f"[ERROR] Hora de corte invalida: {args.hora_corte!r}. Use HH:MM.")
        return 1

    ruta_log = configurar_logging(datetime.now())
    log.info("=" * 62)
    log.info("Informe Diario GRIDO - fecha del informe: %s", fecha_informe)
    log.info("Log: %s", ruta_log)

    try:
        cfg = cargar_config()
    except SystemExit as e:
        log.error("%s", e)
        return 1

    destinatarios_cli = None
    if args.destinatarios:
        destinatarios_cli = [x.strip() for x in
                             args.destinatarios.replace(";", ",").split(",")
                             if x.strip()]

    if args.probar_mail:
        try:
            probar_mail(cfg, destinatarios_cli)
        except Exception:
            log.error("Fallo la prueba de envio:\n%s", traceback.format_exc())
            return 4
        return 0

    try:
        datos, resumen = generar_informe(cfg, fecha_informe, hora_corte)
    except Exception:
        log.error("Fallo la consulta a la base de datos:\n%s",
                  traceback.format_exc())
        return 2

    t = resumen["total"]
    log.info("Resumen: %s en %d tickets, %.1f kg, %d cajeros",
             _pesos(t["ventas"]), t["tickets"], t["kilos"], t["cajeros"])

    try:
        adjunto = guardar_excel(datos, fecha_informe)
    except Exception:
        log.error("Fallo al armar el Excel:\n%s", traceback.format_exc())
        return 3

    # -----------------------------------------------------------------------
    # CONTROL DE INFORME VACIO
    #
    # Un informe sin ventas no es un dia flojo: es que falto el dato. Paso en
    # septiembre de 2026 con las jornadas 21 y 22, cuando una actualizacion de
    # Google Drive dejo dos instancias peleando el mismo montaje, el backup
    # nuevo no se vio y el restore quedo sirviendo datos viejos. Los dos
    # informes salieron en cero a los cinco destinatarios y el problema recien
    # se noto dos dias despues.
    #
    # Ahora, por debajo del umbral, NO se manda el informe: se manda una
    # alerta a los responsables tecnicos con el diagnostico. El umbral se
    # configura por si alguna vez hay un dia legitimamente cerrado, y
    # --forzar-envio permite mandarlo igual a mano.
    # -----------------------------------------------------------------------
    minimo = cfg.getint("control", "tickets_minimos", fallback=1)
    tickets = resumen["total"]["tickets"]

    if tickets < minimo and not args.forzar_envio:
        log.error("INFORME VACIO: %d tickets, por debajo del minimo de %d. "
                  "NO se envia el informe.", tickets, minimo)
        ultima = diagnosticar_origen(cfg)
        if ultima:
            log.error("La ultima venta en el origen es del %s", ultima)
        # --sin-mail tambien silencia la alerta: si no, probar el proceso a
        # mano dispararia avisos de ERROR sin que haya pasado nada.
        if args.sin_mail:
            log.warning("--sin-mail: la alerta NO se envia. Se habria avisado "
                        "a: %s", ", ".join(destinatarios_alerta(cfg)))
            return 7
        try:
            enviar_alerta(cfg, fecha_informe, resumen, ultima, adjunto)
        except Exception:
            log.error("Ademas fallo el envio de la alerta:\n%s",
                      traceback.format_exc())
            return 8
        # El Excel vacio queda en salidas para poder revisarlo, pero NO se
        # copia al historico de Drive: ahi solo van informes validos.
        return 7

    if tickets < minimo and args.forzar_envio:
        log.warning("El informe tiene %d tickets pero se envia igual por "
                    "--forzar-envio.", tickets)

    # -----------------------------------------------------------------------
    # DOS ENTREGAS INDEPENDIENTES: el mail y la copia al historico de Drive.
    #
    # Antes la copia colgaba del envio: un "return 4" cortaba la funcion antes
    # de llegar a copiar. En septiembre de 2026 eso costo cinco informes en
    # Drive (jornadas 14 al 18) por una contrasena de aplicacion de Gmail que
    # habia quedado revocada, aun cuando el Excel se habia generado bien los
    # cinco dias. La carpeta de Drive no tenia por que sufrir un problema de
    # correo.
    #
    # Ahora cada entrega se intenta siempre y falla por su cuenta, y el codigo
    # de salida dice cual de las dos se cayo. El mail va primero porque es lo
    # que alguien esta esperando a las 13:00, y G: es una unidad virtual de
    # Google Drive que puede tardar en responder.
    # -----------------------------------------------------------------------
    fallo_mail = False
    fallo_drive = False

    if args.sin_mail:
        log.info("--sin-mail: se omite el envio.")
    else:
        try:
            enviar_mail(cfg, adjunto, resumen, fecha_informe, destinatarios_cli)
        except Exception:
            fallo_mail = True
            log.error("Fallo el envio del mail:\n%s", traceback.format_exc())

    if args.sin_drive:
        log.info("--sin-drive: se omite la copia al historico.")
    else:
        try:
            copiar_a_historico(cfg, adjunto)
        except Exception:
            fallo_drive = True
            log.error("Fallo la copia al historico de Drive:\n%s",
                      traceback.format_exc())

    if fallo_mail and fallo_drive:
        log.error("Terminado CON ERRORES: no salio el mail ni se copio a "
                  "Drive. El Excel quedo igual en %s", adjunto)
        return 6
    if fallo_mail:
        log.error("Terminado CON ERRORES: la copia a Drive SI se hizo, pero "
                  "el mail no salio.")
        return 4
    if fallo_drive:
        log.error("Terminado CON ERRORES: el mail SI se envio, pero fallo la "
                  "copia al historico de Drive.")
        return 5

    log.info("Proceso terminado con exito.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
