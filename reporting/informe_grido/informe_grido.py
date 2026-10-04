"""
Informe Diario GRIDO - Automatizado
===================================
Aplicacion Streamlit para generar el Informe Diario de Ventas
directamente desde la base de datos SQL Server (SmartFran).

Uso: streamlit run informe_grido.py
"""

import streamlit as st
import pandas as pd
import pyodbc
from datetime import datetime, timedelta
from collections import Counter, defaultdict
from decimal import Decimal, ROUND_HALF_UP
import io
import openpyxl
from openpyxl.styles import Font, PatternFill, Alignment
from openpyxl.formatting.rule import FormulaRule
from openpyxl.utils import get_column_letter

# ============================================================================
# CONFIGURACION DE PAGINA
# ============================================================================
st.set_page_config(
    page_title="Informe Diario GRIDO",
    page_icon="🍦",
    layout="wide",
    initial_sidebar_state="expanded"
)

# ============================================================================
# CONSTANTES
# ============================================================================
ORDEN_SUC = ["Fiorito", "Escalada", "Lanus"]
SUC_DISPLAY = {"Fiorito": "Fiorito", "Escalada": "Escalada", "Lanus": "Lanus Oeste"}
SUC_ID_MAP = {3: "Fiorito", 2: "Escalada", 1: "Lanus"}  # Mapeo ID -> nombre

# El clima y las cajas de delivery no estan en la base de SmartFran: viven en
# el DWH de la WebApp Central, en el mismo servidor. Se leen de ahi para que el
# Excel y la pantalla web usen exactamente los mismos datos.
BASE_DWH = "DF_DTW"
BASE_ORIGEN = "SRV_GRIDO_ZSUR"

# ----------------------------------------------------------------------------
# Estandares para las alertas por desvio
# ----------------------------------------------------------------------------
# Minimo aceptable de sobreventas ACEPTADAS sobre ACTIVADAS (columna L, %SV).
# El cajero que quede por debajo se marca en rojo con texto blanco.
# Para cambiar el estandar, se cambia solo este valor: la regla, el umbral de
# la formula y la leyenda del Excel salen todos de aca.
UMBRAL_SV = 0.15

ALERTA_BG = "FFC0392B"   # rojo
ALERTA_FG = "FFFFFFFF"   # texto blanco

# Paleta de colores para Excel
COLORS = {
    "header_dark":    "FF1E2D3D",
    "header_med":     "FF2C3E50",
    "red":            "FFC0392B",
    "metrics_bg":     "FFF8F9FA",
    "col_hdr":        "FF455A64",
    "sv_hdr":         "FF8D5524",
    "ly_hdr":         "FF1F618D",
    "fiorito_row":    "FF4A7C59",
    "fiorito_cell":   "FFEBF5EE",
    "escalada_row":   "FF2E4053",
    "escalada_cell":  "FFEAF0FB",
    "lanus_row":      "FF784212",
    "lanus_cell":     "FFFEF5E7",
    "total_row":      "FF1A252F",
    "sv_cell":        "FFFFF8F0",
    "ly_cell":        "FFEBF5FB",
    "future":         "FFF5F6FA",
    "future_txt":     "FF9FA8B0",
}

# ============================================================================
# DIA OPERATIVO
# ============================================================================
def rango_dia_operativo(fecha_informe, hora_corte):
    """
    Devuelve (inicio, fin) del dia operativo de `fecha_informe`.

    La jornada comercial no coincide con el dia calendario: el turno noche
    cierra pasada la medianoche, asi que las ventas del 05/09 son las que van
    del 05/09 02:00 al 06/09 02:00.

    OJO con el sentido de la resta. Antes el rango se calculaba hacia atras
    (`fecha-1 02:00` a `fecha 02:00`), y como la tarea programada ya le pasaba
    la fecha de AYER, las dos restas se encadenaban: el informe rotulado 05/09
    traia en realidad la jornada del 04/09 y llegaba con dos dias de atraso. Se
    calcula hacia adelante para que la fecha que titula el informe sea la
    jornada que el informe contiene, y no la madrugada en que esa jornada
    termino.
    """
    inicio = datetime.combine(fecha_informe, hora_corte)
    fin = datetime.combine(fecha_informe + timedelta(days=1), hora_corte)
    return inicio, fin

# ============================================================================
# FUNCIONES DE CONEXION
# ============================================================================
def get_available_driver():
    """Detecta el driver ODBC de SQL Server disponible."""
    drivers = pyodbc.drivers()
    # Preferir versiones mas recientes
    for driver in ["ODBC Driver 18 for SQL Server",
                   "ODBC Driver 17 for SQL Server",
                   "ODBC Driver 13 for SQL Server",
                   "ODBC Driver 11 for SQL Server",
                   "SQL Server Native Client 11.0",
                   "SQL Server"]:
        if driver in drivers:
            return driver
    return None

def get_connection(server, database, username=None, password=None):
    """Establece conexion a SQL Server."""
    try:
        driver = get_available_driver()
        if not driver:
            st.error("No se encontro ningun driver ODBC de SQL Server instalado")
            return None

        # TrustServerCertificate=yes es necesario para el ODBC Driver 18, que exige
        # cifrado por defecto y rechaza los certificados autofirmados que usan las
        # instancias internas de SQL Server (error 08001 "certificate chain ...
        # not trusted").
        if username and password:
            conn_str = (
                f"DRIVER={{{driver}}};"
                f"SERVER={server};"
                f"DATABASE={database};"
                f"UID={username};"
                f"PWD={password};"
                f"TrustServerCertificate=yes;"
                f"Connection Timeout=10;"
            )
        else:
            conn_str = (
                f"DRIVER={{{driver}}};"
                f"SERVER={server};"
                f"DATABASE={database};"
                f"Trusted_Connection=yes;"
                f"TrustServerCertificate=yes;"
                f"Connection Timeout=10;"
            )
        conn = pyodbc.connect(conn_str, timeout=10)
        return conn
    except Exception as e:
        st.error(f"Error de conexion: {e}")
        return None

def test_connection(conn):
    """Verifica la conexion."""
    if conn is None:
        return False
    try:
        cursor = conn.cursor()
        cursor.execute("SELECT 1")
        cursor.fetchone()
        return True
    except:
        return False

# ============================================================================
# FUNCIONES DE CONSULTA SQL
# ============================================================================
def get_sucursales(conn):
    """Obtiene mapeo de sucursales."""
    query = """
    SELECT SUCURSAL, RTRIM(SUCCODIGO) as SUCCODIGO, RTRIM(SUCDESCRIP) as SUCDESCRIP
    FROM SUCURSALES
    WHERE SUCESTADO = 'ACTIVO'
    """
    df = pd.read_sql(query, conn)
    return {row['SUCURSAL']: row['SUCCODIGO'].strip() for _, row in df.iterrows()}

def get_ventas(conn, fecha_inicio, fecha_fin, sucursales_excluir=[4]):
    """
    Obtiene ventas del periodo especificado.

    Args:
        fecha_inicio: datetime de inicio (ej: 2026-08-02 02:00)
        fecha_fin: datetime de fin (ej: 2026-08-03 02:00)
        sucursales_excluir: lista de IDs de sucursales a excluir (default: [4] = Mayorista)
    """
    excluir_str = ','.join(map(str, sucursales_excluir)) if sucursales_excluir else '0'

    query = f"""
    SELECT
        v.VENTA,
        v.SUCURSAL,
        v.TURNO,
        v.CAJA,
        v.VTAFECHA,
        v.VTAIMPORTE,
        RTRIM(v.VTAESTADO) as VTAESTADO,
        RTRIM(v.USULOGIN) as USULOGIN,
        RTRIM(v.CONDVTAPOS) as CONDVTAPOS,
        RTRIM(v.SOBREVENTA) as SOBREVENTA,
        RTRIM(v.VTAOPERACION) as VTAOPERACION
    FROM VENTAS v
    WHERE v.VTAFECHA >= ?
      AND v.VTAFECHA < ?
      AND v.SUCURSAL NOT IN ({excluir_str})
    ORDER BY v.SUCURSAL, v.TURNO, v.CAJA, v.VTAFECHA
    """
    df = pd.read_sql(query, conn, params=[fecha_inicio, fecha_fin])
    return df

def get_detventas_kilos(conn, fecha_inicio, fecha_fin, sucursales_excluir=[4]):
    """
    Obtiene kilos YA CALCULADOS Y AGRUPADOS por sucursal/turno/caja/cajero.

    Logica de kilos (calculada en SQL para mayor performance):
    - Para articulos ELABORADO: kilos = cant * (artcomp1cant + artcomp2cant + artcomp3cant)
    - Para otros tipos: kilos = cant * artpeso
    - Se usa ARTICULOSHISTORICO (version historica via artversion) NO articulos.artpeso
    - Filtro: promo <> 2 y vtaestado = 'NORMAL'

    Ademas trae, con los mismos filtros:
    - KILOS_CLUB: los kilos de las ventas Club Grido (vtaoperacion = 'VL'). Es
      la base del %VCG, que desde el 02/10/2026 se mide sobre kilos y no sobre
      pesos (pedido de Damian).
    - PROMOS: la venta (cant * precio) de las lineas que forman parte de una
      PROMOCION, es decir cuya PROMOCION apunta a un articulo de tipo
      PROMOCION. Es el mismo criterio que LINEA_ES_PROMOCION de la huella, asi
      que el Excel y la pantalla web dan igual. No incluye sobreventas ni
      canjes, que tambien se cargan como "promocion" en SmartFran.
    """
    excluir_str = ','.join(map(str, sucursales_excluir)) if sucursales_excluir else '0'

    query = f"""
    SELECT
        v.SUCURSAL,
        v.TURNO,
        v.CAJA,
        RTRIM(v.USULOGIN) as USULOGIN,
        SUM(dv.CANT * (
            CASE
                WHEN a.ARTTIPO = 'ELABORADO'
                THEN ISNULL(h.ARTCOMP1CANT, 0) + ISNULL(h.ARTCOMP2CANT, 0) + ISNULL(h.ARTCOMP3CANT, 0)
                ELSE ISNULL(h.ARTPESO, 0)
            END
        )) as KILOS,
        SUM(CASE WHEN v.VTAOPERACION = 'VL' THEN dv.CANT * (
            CASE
                WHEN a.ARTTIPO = 'ELABORADO'
                THEN ISNULL(h.ARTCOMP1CANT, 0) + ISNULL(h.ARTCOMP2CANT, 0) + ISNULL(h.ARTCOMP3CANT, 0)
                ELSE ISNULL(h.ARTPESO, 0)
            END) ELSE 0 END) as KILOS_CLUB,
        SUM(CASE WHEN p.ARTTIPO = 'PROMOCION' THEN dv.CANT * dv.PRECIO ELSE 0 END) as PROMOS
    FROM DETVENTAS dv
    INNER JOIN VENTAS v ON dv.VENTA = v.VENTA
        AND dv.SUCURSAL = v.SUCURSAL
        AND dv.CAJA = v.CAJA
    LEFT JOIN ARTICULOS a ON dv.ARTICULO = a.ARTICULO
    LEFT JOIN ARTICULOS p ON dv.PROMOCION = p.ARTICULO
    LEFT JOIN ARTICULOSHISTORICO h ON dv.ARTVERSION = h.IDHISTORICO
    WHERE v.VTAFECHA >= ?
      AND v.VTAFECHA < ?
      AND v.SUCURSAL NOT IN ({excluir_str})
      AND v.VTAESTADO = 'NORMAL'
      AND dv.PROMO <> 2
    GROUP BY v.SUCURSAL, v.TURNO, v.CAJA, v.USULOGIN
    """
    df = pd.read_sql(query, conn, params=[fecha_inicio, fecha_fin])
    return df

def get_turnos(conn, fecha_inicio, fecha_fin, sucursales_excluir=[4]):
    """Obtiene cierres de turno para diferencia de caja."""
    excluir_str = ','.join(map(str, sucursales_excluir)) if sucursales_excluir else '0'

    query = f"""
    SELECT
        t.TURNO,
        t.SUCURSAL,
        t.CAJA,
        RTRIM(t.USULOGIN) as USULOGIN,
        t.TURINICIATURNO,
        t.TURCIERRE,
        t.TURDIFERENCIA,
        t.TUREFECTIVO,
        t.TURTARJETA,
        t.TURTOTALCAJA,
        t.TURCAJATEORICA
    FROM TURNOS t
    WHERE t.TURINICIATURNO >= ?
      AND t.TURINICIATURNO < ?
      AND t.SUCURSAL NOT IN ({excluir_str})
    """
    df = pd.read_sql(query, conn, params=[fecha_inicio, fecha_fin])
    return df

def get_tarjetas(conn, fecha_inicio, fecha_fin, sucursales_excluir=[4]):
    """Obtiene tarjetas Club Grido activadas (socios nuevos)."""
    excluir_str = ','.join(map(str, sucursales_excluir)) if sucursales_excluir else '0'

    query = f"""
    SELECT
        RTRIM(t.USULOGIN) as USULOGIN,
        t.SUCURSAL,
        t.TURNO,
        t.CAJA,
        t.TARFECHA,
        RTRIM(t.OPERACION) as OPERACION
    FROM TARJETAS t
    WHERE t.TARFECHA >= ?
      AND t.TARFECHA < ?
      AND t.SUCURSAL NOT IN ({excluir_str})
    """
    df = pd.read_sql(query, conn, params=[fecha_inicio, fecha_fin])
    return df

ZONA_CLIMA = ("Lanus Oeste", "Escalada", "Fiorito")

def get_clima(conn, fecha_inicio, fecha_fin):
    """
    Clima DE ZONA hora por hora, del DWH (CLIMA_ZONA_HORA). Especificacion de
    Damian del 01/10/2026 (ESPEC_Hojas_Damian_2026-10-01.md, seccion 2 bis):

    - El clima viene de un modelo en grilla: Lanus y Escalada dan lo mismo y
      Fiorito difiere apenas. Lo que si cambia es CUANDO se cargo cada
      ubicacion (pronostico contra dato ya ocurrido). Por eso, para cada hora
      se toma la carga mas reciente entre las 3 ubicaciones; si empatan,
      todas sus filas.
    - Va de las 00 h de la jornada a las 02 h del dia siguiente: las horas de
      la madrugada usan la CLIMA_KEY_HORA del dia siguiente.

    Devuelve las filas (no el promedio): la condicion climatica se elige por
    moda sobre todas ellas. Si el DWH no esta disponible, el informe sale con
    el clima vacio: el clima suma contexto pero no puede frenar el informe.
    """
    query = f"""
    WITH cz AS (
        SELECT CLIMA_KEY_HORA, SUCURSAL_NOMBRE, SENSACION_TERMICA, PRECIPITACION, DESCRIPCION_TIEMPO, FECHA_CARGA,
               MAX(FECHA_CARGA) OVER (PARTITION BY CLIMA_KEY_HORA) AS ULTIMA_CARGA
        FROM {BASE_DWH}.dbo.CLIMA_ZONA_HORA
        WHERE BASE_ORIGEN = ?
          AND SUCURSAL_NOMBRE IN ({",".join("?" * len(ZONA_CLIMA))})
          AND CLIMA_KEY_HORA >= CAST(CAST(? AS date) AS datetime)
          AND CLIMA_KEY_HORA <  DATEADD(hour, 26, CAST(CAST(? AS date) AS datetime)))
    SELECT CLIMA_KEY_HORA, SUCURSAL_NOMBRE, SENSACION_TERMICA, PRECIPITACION, DESCRIPCION_TIEMPO
    FROM cz WHERE FECHA_CARGA = ULTIMA_CARGA
    -- El orden fija el desempate de la condicion (gana la que aparece
    -- primero): usp_InformeDiarioGrido desempata igual, para dar lo mismo.
    ORDER BY CLIMA_KEY_HORA, SUCURSAL_NOMBRE
    """
    try:
        return pd.read_sql(query, conn, params=[BASE_ORIGEN, *ZONA_CLIMA, fecha_inicio, fecha_inicio])
    except Exception:
        # Que quede en el log: un clima vacio sin explicacion parece un dia sin datos.
        import logging, traceback
        logging.getLogger("informe").error("No se pudo leer el clima de zona; el informe sale sin clima:\n%s",
                                           traceback.format_exc())
        return pd.DataFrame(columns=["CLIMA_KEY_HORA", "SUCURSAL_NOMBRE", "SENSACION_TERMICA",
                                     "PRECIPITACION", "DESCRIPCION_TIEMPO"])

def get_cajas_delivery(conn):
    """
    Cajas de delivery de cada sucursal (CFG_CAJA_DELIVERY del DWH). Es la misma
    tabla que usa la pantalla web: si un local cambia de caja, se cambia ahi y
    salen bien los dos informes.
    """
    query = f"""
    SELECT SUCURSAL, CAJA FROM {BASE_DWH}.dbo.CFG_CAJA_DELIVERY WHERE BASE_ORIGEN = ?
    """
    try:
        return pd.read_sql(query, conn, params=[BASE_ORIGEN])
    except Exception:
        return pd.DataFrame(columns=["SUCURSAL", "CAJA"])

# ============================================================================
# FUNCIONES DE PROCESAMIENTO
# ============================================================================
def texto(valor, default=""):
    """
    Normaliza a str un valor que viene de un DataFrame.

    Necesario porque un NULL de SQL no llega igual segun la version de pandas:
    en 2.x las columnas de texto son 'object' y el NULL llega como None (falsy),
    pero en 3.x son dtype 'str' y el NULL llega como float('nan'), que es TRUTHY.
    Por eso 'row[col].strip() if row[col] else ""' revienta con
    AttributeError: 'float' object has no attribute 'strip'.
    """
    if valor is None:
        return default
    if isinstance(valor, float) and pd.isna(valor):
        return default
    if not isinstance(valor, str):
        valor = str(valor)
    valor = valor.strip()
    return valor if valor else default

def procesar_ventas(df_ventas, suc_map):
    """
    Procesa ventas y agrupa por sucursal/turno/caja/cajero.
    """
    turnos = {}

    for _, row in df_ventas.iterrows():
        suc_id = row['SUCURSAL']
        suc_key = suc_map.get(suc_id, f"Suc{suc_id}").strip()
        turno = int(row['TURNO'])
        caja = int(row['CAJA'])
        cajero = texto(row['USULOGIN'], "Desconocido").title()

        key = (suc_key, turno, caja, cajero)

        if key not in turnos:
            turnos[key] = {
                "sucursal": suc_key,
                "turno": turno,
                "caja": caja,
                "cajero": cajero,
                "ventas": 0.0,
                "ventas_club": 0.0,
                "tickets": set(),
                "anuladas": 0,
                "sv_aceptadas": 0,
                "sv_rechazadas": 0,
                "min_fecha": None,
                "max_fecha": None,
            }

        t = turnos[key]
        estado = texto(row['VTAESTADO'])

        if estado == "ANULADO":
            t["anuladas"] += 1
            continue

        importe = float(row['VTAIMPORTE']) if pd.notna(row['VTAIMPORTE']) else 0.0
        t["ventas"] += importe
        t["tickets"].add(int(row['VENTA']))

        # Ventas Club Grido (segun SP infturnos: vtaoperacion = 'VL')
        vtaoperacion = texto(row['VTAOPERACION']).upper()
        if vtaoperacion == "VL":
            t["ventas_club"] += importe

        # Sobreventas
        sobreventa = texto(row['SOBREVENTA'])
        if sobreventa == "ACEPTADA":
            t["sv_aceptadas"] += 1
        elif sobreventa == "RECHAZADA":
            t["sv_rechazadas"] += 1

        # Horario
        if row['VTAFECHA']:
            dt = row['VTAFECHA']
            if t["min_fecha"] is None or dt < t["min_fecha"]:
                t["min_fecha"] = dt
            if t["max_fecha"] is None or dt > t["max_fecha"]:
                t["max_fecha"] = dt

    # Calcular horas y horario
    for t in turnos.values():
        t["tickets_count"] = len(t["tickets"])
        t["sv_activadas"] = t["sv_aceptadas"] + t["sv_rechazadas"]

        if t["min_fecha"] and t["max_fecha"]:
            diff = (t["max_fecha"] - t["min_fecha"]).total_seconds() / 3600
            t["horas"] = round(diff, 1)
            t["horario"] = f"{t['min_fecha'].strftime('%H:%M')} a {t['max_fecha'].strftime('%H:%M')}"
        else:
            t["horas"] = 0
            t["horario"] = ""

    return turnos

def procesar_kilos(df_kilos, suc_map):
    """
    Procesa kilos ya calculados y agrupados desde SQL.
    El DataFrame viene con: SUCURSAL, TURNO, CAJA, USULOGIN, KILOS
    """
    kilos = {}

    for _, row in df_kilos.iterrows():
        suc_id = row['SUCURSAL']
        suc_key = suc_map.get(suc_id, f"Suc{suc_id}").strip()
        turno = int(row['TURNO'])
        caja = int(row['CAJA'])
        cajero = texto(row['USULOGIN'], "Desconocido").title()
        def num(col):
            return float(row[col]) if col in row and pd.notna(row[col]) else 0.0

        kilos[(suc_key, turno, caja, cajero)] = {
            "kilos": num('KILOS'),
            "kilos_club": num('KILOS_CLUB'),
            "promos": num('PROMOS'),
        }

    return kilos

def procesar_clima(df_clima, suc_map=None):
    """
    {hora_redonda: (sensacion, precipitacion, [condiciones])}: el promedio de
    las filas de la carga mas reciente de esa hora, y todas sus condiciones.
    """
    filas = defaultdict(list)
    for _, row in df_clima.iterrows():
        hora = pd.Timestamp(row['CLIMA_KEY_HORA']).to_pydatetime().replace(minute=0, second=0, microsecond=0)
        filas[hora].append(row)
    clima = {}
    for hora, rows in filas.items():
        st = [Decimal(str(r['SENSACION_TERMICA'])) for r in rows if pd.notna(r['SENSACION_TERMICA'])]
        pp = [Decimal(str(r['PRECIPITACION'])) for r in rows if pd.notna(r['PRECIPITACION'])]
        cond = [texto(r['DESCRIPCION_TIEMPO']) for r in rows if texto(r['DESCRIPCION_TIEMPO'])]
        clima[hora] = (sum(st) / len(st) if st else None, sum(pp) / len(pp) if pp else None, cond)
    return clima

def horas_turno(desde, hasta):
    """
    Horas de un turno, segun la espec de Damian: de la hora de inicio a la de
    fin, y la de fin cuenta solo si tiene minutos ("10:18 a 15:00" son las
    horas 10 a 14). Trabaja con fecha y hora, asi que un turno que pasa la
    medianoche toma solo las horas del dia siguiente.
    """
    if desde is None or hasta is None:
        return []
    h = pd.Timestamp(desde).to_pydatetime().replace(minute=0, second=0, microsecond=0)
    fin_dt = pd.Timestamp(hasta).to_pydatetime()
    ult = fin_dt.replace(minute=0, second=0, microsecond=0)
    if fin_dt.minute == 0 and ult > h:
        ult -= timedelta(hours=1)
    horas = []
    while h <= ult:
        horas.append(h)
        h += timedelta(hours=1)
    return horas

def clima_de_horas(clima, horas):
    """
    (sensacion termica promedio, lluvia mm, condicion) para un conjunto de
    horas: promedio de la sensacion de cada hora, suma de la lluvia de cada
    hora, y la condicion que mas se repite.

    La condicion se cuenta sobre TODAS las filas de la carga mas reciente y no
    sobre una por hora: la consulta de la espec elige una por hora con MIN(),
    o sea por orden alfabetico, y eso hacia ganar "Chaparrones" sobre
    "Llovizna moderada" solo por empezar con C. En un empate gana la que
    aparece primero en el turno.
    """
    st, pp, conds = [], [], []
    for h in sorted(set(horas)):
        if h in clima:
            s, p, c = clima[h]
            if s is not None:
                st.append(s)
            if p is not None:
                pp.append(p)
            conds.extend(c)
    cond = Counter(conds).most_common(1)[0][0] if conds else None
    return (redondear1(sum(st) / len(st)) if st else None,
            redondear1(sum(pp)) if pp else None,
            cond)

def redondear1(x):
    """
    Redondea a un decimal como SQL Server (mitad hacia arriba: 14,25 -> 14,3).
    round() de Python redondea al par (14,25 -> 14,2) y hacia que el Excel y
    la web mostraran distinto el mismo dato.
    """
    return float(Decimal(str(x)).quantize(Decimal("0.1"), rounding=ROUND_HALF_UP))

def procesar_cajas_delivery(df_cajas, suc_map):
    """{sucursal: {cajas}} a partir de CFG_CAJA_DELIVERY."""
    cajas = defaultdict(set)
    for _, row in df_cajas.iterrows():
        suc_key = suc_map.get(row['SUCURSAL'], f"Suc{row['SUCURSAL']}").strip()
        cajas[suc_key].add(int(row['CAJA']))
    return cajas

def procesar_turnos_extra(df_turnos, suc_map):
    """Procesa datos extra de turnos (diferencia de caja)."""
    data = {}

    for _, row in df_turnos.iterrows():
        suc_id = row['SUCURSAL']
        suc_key = suc_map.get(suc_id, f"Suc{suc_id}").strip()
        turno = int(row['TURNO'])
        caja = int(row['CAJA'])

        dif_caja = float(row['TURDIFERENCIA']) if pd.notna(row['TURDIFERENCIA']) else 0.0

        data[(suc_key, turno, caja)] = {
            "dif_caja": dif_caja,
        }

    return data

def procesar_socios(df_tarjetas, suc_map):
    """Cuenta socios nuevos por cajero."""
    socios = defaultdict(int)

    for _, row in df_tarjetas.iterrows():
        cajero = texto(row['USULOGIN'], "Desconocido").title()
        operacion = texto(row['OPERACION']).upper()

        # Contar socios: N = salon, W = web (segun SP inftarjetascajero)
        if operacion in ["N", "W"]:
            socios[cajero] += 1

    return socios

def calcular_totales_sucursal(turnos):
    """Calcula totales por sucursal para kilos proporcionales."""
    totales = defaultdict(lambda: {"ventas": 0.0, "kilos_calculados": 0.0})

    for t in turnos.values():
        totales[t["sucursal"]]["ventas"] += t["ventas"]

    return totales

def ensamblar(turnos, kilos_raw, socios_raw, turnos_extra, clima=None, cajas_delivery=None):
    """
    Ensambla datos finales por sucursal.

    Devuelve {sucursal: [filas]}. Ademas deja en la clave especial "_suc"
    el clima de cada sucursal (subtotal) y el del dia (TOTAL). `clima` es el
    clima de zona por hora (procesar_clima).
    """
    clima = clima or {}
    cajas_delivery = cajas_delivery or {}
    # Calcular totales por sucursal
    suc_totales = defaultdict(float)
    for t in turnos.values():
        suc_totales[t["sucursal"]] += t["ventas"]

    resultado = {}
    clima_suc = {}
    horas_dia = set()

    for suc in ORDEN_SUC:
        suc_turnos = [t for t in turnos.values() if t["sucursal"] == suc]
        suc_turnos.sort(key=lambda x: x["turno"])

        total_ventas_suc = suc_totales.get(suc, 1)

        # Rastrear socios ya asignados
        cajeros_socios_asignados = set()
        # Horas en que trabajo algun cajero de la sucursal: es el clima del
        # subtotal. Union de horas y no suma de turnos: dos cajas a la vez
        # contarian dos veces la lluvia.
        horas_suc = set()

        filas = []
        for t in suc_turnos:
            key = (t["sucursal"], t["turno"], t["caja"], t["cajero"])

            # Kilos, kilos club y promos del turno
            kd = kilos_raw.get(key, {})
            kg = redondear1(kd.get("kilos", 0))
            kg_club = redondear1(kd.get("kilos_club", 0))
            promos = kd.get("promos", 0.0)

            horas = horas_turno(t["min_fecha"], t["max_fecha"])
            sens, lluvia, condicion = clima_de_horas(clima, horas)
            horas_suc.update(horas)
            horas_dia.update(horas)

            # Socios (solo al primer turno del cajero)
            cajero_lower = t["cajero"].lower()
            socios_val = 0
            if cajero_lower not in cajeros_socios_asignados:
                socios_val = socios_raw.get(t["cajero"], 0)
                if socios_val > 0:
                    cajeros_socios_asignados.add(cajero_lower)

            extra = turnos_extra.get((t["sucursal"], t["turno"], t["caja"]), {})

            filas.append({
                "cajero": t["cajero"],
                "turno": t["turno"],
                "caja": t["caja"],
                "horario": t["horario"],
                "horas": t["horas"],
                "kilos": kg,
                "ventas": t["ventas"],
                "tickets": t["tickets_count"],
                "sv_act": t["sv_activadas"],
                "sv_acept": t["sv_aceptadas"],
                "socios": socios_val,
                "ventas_club": t["ventas_club"],
                "kilos_club": kg_club,
                "promos": promos,
                "anuladas": t["anuladas"],
                "dif_caja": extra.get("dif_caja", 0),
                "es_delivery": t["caja"] in cajas_delivery.get(suc, set()),
                "sensacion_termica": sens,
                "lluvia_mm": lluvia,
                "condicion": condicion,
            })

        resultado[suc] = filas
        clima_suc[suc] = clima_de_horas(clima, horas_suc)

    resultado["_suc"] = {
        "clima": clima_suc,
        # TOTAL: todas las horas del dia con algun turno (espec de Damian).
        "clima_total": clima_de_horas(clima, horas_dia),
        "cajas_delivery": {s: sorted(cajas_delivery.get(s, set())) for s in ORDEN_SUC},
    }

    return resultado

# ============================================================================
# FUNCIONES DE EXCEL
# ============================================================================
def fill(hex_color):
    return PatternFill("solid", fgColor=hex_color)

def fnt(color="FF000000", bold=False, size=10, name="Arial"):
    return Font(name=name, bold=bold, color=color, size=size)

def aln(h="center", v="center", wrap=False):
    return Alignment(horizontal=h, vertical=v, wrap_text=wrap)

def set_cell(ws, row, col, value, bg, fg="FF000000", bold=False, size=9,
             h="center", v="center", wrap=False, fmt=None):
    c = ws.cell(row=row, column=col)
    c.value = value
    c.fill = fill(bg)
    c.font = fnt(fg, bold, size)
    c.alignment = aln(h, v, wrap)
    if fmt:
        c.number_format = fmt
    return c

# ----------------------------------------------------------------------------
# Columnas de la hoja "Informe Diario" (espec de Damian del 01/10/2026,
# ESPEC_Hojas_Damian_2026-10-01.md seccion 2 bis, y su ejemplo del 27/09):
#   A Sucursal/Cajero  B Turno  C Caja  D Horario  E Horas  F Kilos
#   G Ventas  H Ticket prom.
#   I Tickets  J SV activadas  K SV aceptadas  L %SV            (SOBREVENTAS)
#   M Promos ($)  N %Promos
#   O Nuevos socios  P Kilos Club Grido  Q %Kilos CG/Kilos      (CLUB GRIDO)
#   R Anuladas  S Dif. de caja
#   T Sensacion termica  U Lluvia (mm)  V Condicion            (CLIMA EN EL TURNO)
# Kilos Club Grido REEMPLAZA a Ventas Club Grido ($): el Club se mide en kilos.
# Las hojas Sobreventas, etc. leen J y K por posicion: no mover columnas.
# Ademas, por decision de Emiliano (02/10/2026), distinto del ejemplo: la
# caja de delivery dice DELI y Turno/Caja/Horario/Horas van en gris claro.
# ----------------------------------------------------------------------------
COLOR_CLIMA_CELL = "FFE8F6F3"
GRIS_REF = "FFC3C3C3"     # letra de turno, caja, horario y horas (igual que la web)
FMT_GRADOS = "0.0"
FMT_MM = "0.0"
FMT_KG = "#,##0.0"

def escribir_subtotal(ws, r, nombre, first, last, bg, clima_suc=(None, None, None)):
    set_cell(ws, r, 1, nombre, bg, "FFFFFFFF", bold=True, h="left")
    set_cell(ws, r, 2, "Todos", bg, "FFFFFFFF", bold=True)
    formulas = {
        5: f"=SUM(E{first}:E{last})",
        6: f"=SUM(F{first}:F{last})",
        7: f"=SUM(G{first}:G{last})",
        8: f'=IFERROR(G{r}/I{r},"")',
        9: f"=SUM(I{first}:I{last})",
        10: f"=SUM(J{first}:J{last})",
        11: f"=SUM(K{first}:K{last})",
        12: f'=IFERROR(K{r}/J{r},"")',
        13: f"=SUM(M{first}:M{last})",
        14: f'=IFERROR(M{r}/G{r},"")',
        15: f"=SUM(O{first}:O{last})",
        16: f"=SUM(P{first}:P{last})",
        17: f'=IFERROR(P{r}/F{r},"")',
        18: f"=SUM(R{first}:R{last})",
        19: f"=SUM(S{first}:S{last})",
        # Clima de todas las horas en que trabajo algun cajero de la sucursal.
        20: clima_suc[0],
        21: clima_suc[1],
        22: clima_suc[2],
    }
    fmts = {7: "$#,##0", 8: "$#,##0", 12: "0.0%", 13: "$#,##0", 14: "0.0%",
            16: FMT_KG, 17: "0.0%", 19: "$#,##0", 20: FMT_GRADOS, 21: FMT_MM}
    for col in range(3, 23):
        val = formulas.get(col, None)
        set_cell(ws, r, col, val, bg, "FFFFFFFF", bold=True, fmt=fmts.get(col))

def escribir_cajero(ws, r, fila, bg_std, bg_sv, bg_ly):
    set_cell(ws, r, 1, f"    {fila['cajero']}", bg_std, "FF1A1A2E", h="left")
    # Turno, caja, horario y horas son referencia, no rendimiento: van en gris
    # claro, igual que en la web. La caja de delivery dice "DELI".
    set_cell(ws, r, 2, fila["turno"], bg_std, GRIS_REF)
    set_cell(ws, r, 3, "DELI" if fila.get("es_delivery") else fila["caja"], bg_std, GRIS_REF)
    set_cell(ws, r, 4, fila["horario"], bg_std, GRIS_REF)
    set_cell(ws, r, 5, fila["horas"], bg_std, GRIS_REF)
    set_cell(ws, r, 6, fila["kilos"], bg_std, "FF1A1A2E")
    set_cell(ws, r, 7, fila["ventas"], bg_std, "FF1A1A2E", fmt="$#,##0")
    set_cell(ws, r, 8, f'=IFERROR(G{r}/I{r},"")', bg_std, "FF1A1A2E", fmt="$#,##0")
    set_cell(ws, r, 9, fila["tickets"], bg_sv, "FF1A1A2E")
    set_cell(ws, r, 10, fila["sv_act"], bg_sv, "FF1A1A2E")
    set_cell(ws, r, 11, fila["sv_acept"], bg_sv, "FF1A1A2E")
    set_cell(ws, r, 12, f'=IFERROR(K{r}/J{r},"")', bg_sv, "FF1A1A2E", fmt="0.0%")
    set_cell(ws, r, 13, fila.get("promos", 0), bg_std, "FF1A1A2E", fmt="$#,##0")
    set_cell(ws, r, 14, f'=IFERROR(M{r}/G{r},"")', bg_std, "FF1A1A2E", fmt="0.0%")
    set_cell(ws, r, 15, fila["socios"], bg_ly, "FF1A1A2E")
    set_cell(ws, r, 16, fila.get("kilos_club", 0), bg_ly, "FF1A1A2E", fmt=FMT_KG)
    set_cell(ws, r, 17, f'=IFERROR(P{r}/F{r},"")', bg_ly, "FF1A1A2E", fmt="0.0%")
    set_cell(ws, r, 18, fila["anuladas"], bg_std, "FF1A1A2E")
    set_cell(ws, r, 19, fila.get("dif_caja", 0), bg_std, "FF1A1A2E", fmt="$#,##0")
    set_cell(ws, r, 20, fila.get("sensacion_termica"), COLOR_CLIMA_CELL, "FF1A1A2E", fmt=FMT_GRADOS)
    set_cell(ws, r, 21, fila.get("lluvia_mm"), COLOR_CLIMA_CELL, "FF1A1A2E", fmt=FMT_MM)
    set_cell(ws, r, 22, fila.get("condicion"), COLOR_CLIMA_CELL, "FF1A1A2E")

def construir_excel(datos_suc, date_str):
    """Construye el archivo Excel con el formato del informe."""
    wb = openpyxl.Workbook()
    ws = wb.active
    ws.title = "Informe Diario"

    info_suc = datos_suc.get("_suc", {})
    clima_suc = info_suc.get("clima", {})
    clima_total = info_suc.get("clima_total", (None, None, None))

    # Anchos de columna
    anchos = {"A":22,"B":8,"C":7,"D":16,"E":7,"F":7,"G":14,"H":12,
              "I":8,"J":8,"K":8,"L":7,"M":12,"N":8,"O":8,"P":10,
              "Q":9,"R":9,"S":9,"T":13,"U":8,"V":21}
    for col, w in anchos.items():
        ws.column_dimensions[col].width = w

    altos = {1:28,2:18,3:20,4:22,5:28,9:36}
    for r, h in altos.items():
        ws.row_dimensions[r].height = h

    # Fila 1 - Titulo (ya no hay columnas "a desarrollar a futuro": T a V
    # pasaron a ser el clima)
    ws.merge_cells("A1:V1")
    set_cell(ws, 1, 1, f"GRIDO - INFORME DIARIO DE VENTAS | {date_str}",
             COLORS["header_dark"], "FFFFFFFF", bold=True, size=14, h="left")

    # Fila 2 - Subtitulo
    ws.merge_cells("A2:V2")
    set_cell(ws, 2, 1, f"Generado: {date_str}  |  Escalada - Fiorito - Lanus",
             COLORS["header_med"], "FFBDC3C7", size=10, h="left")

    # Fila 3 - Metricas clave
    ws.merge_cells("A3:V3")
    set_cell(ws, 3, 1, "METRICAS CLAVE", COLORS["red"], "FFFFFFFF", bold=True, size=11)

    # Filas 4-5 - Metricas (se completan despues)
    for col in range(1, 23):
        ws.cell(4, col).fill = fill(COLORS["metrics_bg"])
        ws.cell(5, col).fill = fill(COLORS["metrics_bg"])

    # Fila 8 - Sub-headers
    # Leyenda de la alerta: sin esto el jefe ve celdas rojas y tiene que
    # adivinar el criterio.
    ws.merge_cells("A8:H8")
    set_cell(ws, 8, 1,
             f"ALERTA  =  %SV por debajo del estandar ({UMBRAL_SV:.0%})",
             ALERTA_BG, ALERTA_FG, bold=True, size=9, h="left")

    ws.merge_cells("I8:L8")
    set_cell(ws, 8, 9, "SOBREVENTAS", "FF6B4226", "FFFFFFFF", bold=True, size=9)
    ws.merge_cells("O8:Q8")
    set_cell(ws, 8, 15, "CLUB GRIDO", "FF1A5276", "FFFFFFFF", bold=True, size=9)
    # Mismo estilo que CLUB GRIDO (espec, seccion 2 bis).
    ws.merge_cells("T8:V8")
    set_cell(ws, 8, 20, "CLIMA EN EL TURNO", "FF1A5276", "FFFFFFFF", bold=True, size=9)

    # Fila 9 - Headers tabla
    hdrs_std = [(1,"Sucursal / Cajero"),(2,"Turno"),(3,"Caja"),(4,"Horario"),
                (5,"Horas"),(6,"Kilos"),(7,"Ventas ($)"),(8,"Ticket\nProm. ($)")]
    hdrs_sv = [(9,"Tickets"),(10,"SV\nActivadas"),(11,"SV\nAceptadas"),(12,"%SV")]
    hdrs_mid = [(13,"Promos ($)"),(14,"%Promos")]
    hdrs_ly = [(15,"Nuevos\nSocios"),(16,"Kilos\nClub Grido"),(17,"%Kilos CG\n/Kilos")]
    hdrs_end = [(18,"Anuladas"),(19,"Dif.\nde Caja")]
    hdrs_clima = [(20,"Sensación térmica\npromedio (°C)"),(21,"Lluvia\n(mm)"),(22,"Condición\nclimática")]

    for col, txt in hdrs_std:
        set_cell(ws, 9, col, txt, COLORS["col_hdr"], "FFFFFFFF", bold=True, size=9, wrap=True)
    for col, txt in hdrs_sv:
        set_cell(ws, 9, col, txt, COLORS["sv_hdr"], "FFFFFFFF", bold=True, size=9, wrap=True)
    for col, txt in hdrs_mid:
        set_cell(ws, 9, col, txt, COLORS["col_hdr"], "FFFFFFFF", bold=True, size=9, wrap=True)
    for col, txt in hdrs_ly:
        set_cell(ws, 9, col, txt, COLORS["ly_hdr"], "FFFFFFFF", bold=True, size=9, wrap=True)
    for col, txt in hdrs_end:
        set_cell(ws, 9, col, txt, COLORS["col_hdr"], "FFFFFFFF", bold=True, size=9, wrap=True)
    for col, txt in hdrs_clima:
        set_cell(ws, 9, col, txt, COLORS["ly_hdr"], "FFFFFFFF", bold=True, size=9, wrap=True)

    # Escribir sucursales
    SUC_COLORS = {
        "Fiorito": (COLORS["fiorito_row"], COLORS["fiorito_cell"]),
        "Escalada": (COLORS["escalada_row"], COLORS["escalada_cell"]),
        "Lanus": (COLORS["lanus_row"], COLORS["lanus_cell"]),
    }

    current_row = 10
    subtotal_rows = {}
    rangos_cajeros = []   # para la alerta por desvio de %SV

    for suc in ORDEN_SUC:
        filas = datos_suc.get(suc, [])
        bg_row, bg_cell = SUC_COLORS[suc]

        subtotal_row = current_row
        first_cajero = current_row + 1
        last_cajero = current_row + len(filas)

        escribir_subtotal(ws, subtotal_row, SUC_DISPLAY[suc], first_cajero, last_cajero, bg_row,
                          clima_suc.get(suc, (None, None, None)))
        subtotal_rows[suc] = subtotal_row
        current_row += 1

        for fila in filas:
            escribir_cajero(ws, current_row, fila, bg_cell, COLORS["sv_cell"], COLORS["ly_cell"])
            current_row += 1

        # Las filas de cajero no son contiguas: entre sucursal y sucursal se
        # mete el subtotal, que no debe entrar en la alerta.
        if filas:
            rangos_cajeros.append((first_cajero, last_cajero))

    # Fila TOTAL
    r_total = current_row
    sub_rows = list(subtotal_rows.values())
    set_cell(ws, r_total, 1, "TOTAL", COLORS["total_row"], "FFFFFFFF", bold=True, size=10, h="left")

    total_formulas = {
        5: f"={'+'.join([f'E{r}' for r in sub_rows])}",
        6: f"={'+'.join([f'F{r}' for r in sub_rows])}",
        7: f"={'+'.join([f'G{r}' for r in sub_rows])}",
        8: f'=IFERROR(G{r_total}/I{r_total},"")',
        9: f"={'+'.join([f'I{r}' for r in sub_rows])}",
        10: f"={'+'.join([f'J{r}' for r in sub_rows])}",
        11: f"={'+'.join([f'K{r}' for r in sub_rows])}",
        12: f'=IFERROR(K{r_total}/J{r_total},"")',
        13: f"={'+'.join([f'M{r}' for r in sub_rows])}",
        14: f'=IFERROR(M{r_total}/G{r_total},"")',
        15: f"={'+'.join([f'O{r}' for r in sub_rows])}",
        16: f"={'+'.join([f'P{r}' for r in sub_rows])}",
        17: f'=IFERROR(P{r_total}/F{r_total},"")',
        18: f"={'+'.join([f'R{r}' for r in sub_rows])}",
        19: f"={'+'.join([f'S{r}' for r in sub_rows])}",
        # Clima de todas las horas del dia con algun turno (es clima de zona).
        20: clima_total[0],
        21: clima_total[1],
        22: clima_total[2],
    }
    fmts_total = {7:"$#,##0",8:"$#,##0",12:"0.0%",13:"$#,##0",14:"0.0%",16:FMT_KG,17:"0.0%",19:"$#,##0",
                  20:FMT_GRADOS,21:FMT_MM}

    for col in range(2, 23):
        val = total_formulas.get(col)
        set_cell(ws, r_total, col, val, COLORS["total_row"], "FFFFFFFF", bold=True,
                 size=10, fmt=fmts_total.get(col))

    # Metricas fila 5 (referencias a fila TOTAL)
    metric_hdr_defs = [
        (4, "VENTAS TOTALES"),
        (7, "TRANSACCIONES"),
        (10, "TICKET PROMEDIO"),
        (13, "SOCIOS CLUB GRIDO"),
    ]
    for col, txt in metric_hdr_defs:
        end_col = get_column_letter(col + 2)
        start_col = get_column_letter(col)
        ws.merge_cells(f"{start_col}4:{end_col}4")
        set_cell(ws, 4, col, txt, COLORS["metrics_bg"], "FF6C757D", bold=True, size=9)

    metric_defs = [
        (4, f"=G{r_total}", "FFC0392B", "$#,##0"),
        (7, f"=I{r_total}", "FF2E5F8A", None),
        (10, f"=H{r_total}", "FF4A7C59", "$#,##0"),
        (13, f"=O{r_total}", "FF1F618D", None),
    ]
    for col, formula, color, fmt in metric_defs:
        set_cell(ws, 5, col, formula, COLORS["metrics_bg"], color, bold=True, size=16, fmt=fmt)

    aplicar_alerta_sv(ws, rangos_cajeros)

    return wb

def aplicar_alerta_sv(ws, rangos_cajeros):
    """
    Pinta en rojo con texto blanco el %SV (columna L) de todo cajero que quede
    por debajo de UMBRAL_SV.

    Va como formato condicional y no como relleno fijo para que la alerta siga
    viva: la columna L es una formula (=K/J), asi que si alguien corrige
    aceptadas o activadas en el Excel, el color se recalcula solo.

    ISNUMBER() no es decorativo: cuando el cajero no activo ninguna sobreventa,
    L da "" por el IFERROR. Sin ese filtro Excel trata el texto vacio como
    menor al umbral y lo pintaria en rojo, acusando de bajo rendimiento a quien
    simplemente no tuvo sobreventas. En cambio 0 aceptadas sobre N activadas si
    da 0 numerico y se marca, que es justamente el caso a mirar.
    """
    for primera, ultima in rangos_cajeros:
        regla = FormulaRule(
            # Anclada a la primera fila del rango; Excel desplaza la fila sola.
            formula=[f"AND(ISNUMBER($L{primera}),$L{primera}<{UMBRAL_SV})"],
            # OJO: aca NO sirve fill(), que solo setea fgColor. El formato
            # condicional usa un "differential style" y Excel toma el color del
            # relleno desde bgColor; con solo fgColor la celda sale sin pintar.
            # Se setean los dos extremos para que valga en cualquier contexto.
            fill=PatternFill(start_color=ALERTA_BG, end_color=ALERTA_BG,
                             fill_type="solid"),
            font=fnt(ALERTA_FG, bold=True, size=9),
            stopIfTrue=False,
        )
        ws.conditional_formatting.add(f"L{primera}:L{ultima}", regla)

# ============================================================================
# INTERFAZ STREAMLIT
# ============================================================================
def main():
    st.title("🍦 Informe Diario GRIDO")
    st.markdown("**Generador automatizado de informes desde SQL Server**")

    # Sidebar - Configuracion
    st.sidebar.header("⚙️ Configuracion")

    # Conexion a base de datos
    st.sidebar.subheader("📊 Base de Datos")
    server = st.sidebar.text_input("Servidor", value=r"WIN-6ARG3SUELOE\SQLEXPRESS")
    database = st.sidebar.text_input("Base de Datos", value="SRV_GRIDO_ZSUR")

    auth_type = st.sidebar.radio("Autenticacion", ["Windows (Trusted)", "SQL Server"])

    username = None
    password = None
    if auth_type == "SQL Server":
        username = st.sidebar.text_input("Usuario")
        password = st.sidebar.text_input("Contraseña", type="password")

    # Fecha del informe
    st.sidebar.subheader("📅 Fecha del Informe")
    fecha_informe = st.sidebar.date_input(
        "Fecha",
        value=datetime.now().date() - timedelta(days=1),
        help="Seleccione la fecha del dia operativo"
    )

    # Hora de corte (dia operativo)
    hora_corte = st.sidebar.time_input(
        "Hora de corte",
        value=datetime.strptime("02:00", "%H:%M").time(),
        help="Hora de inicio/fin del dia operativo"
    )

    # Boton de conexion
    if st.sidebar.button("🔌 Conectar", type="primary"):
        with st.spinner("Conectando a la base de datos..."):
            conn = get_connection(server, database, username, password)
            if conn and test_connection(conn):
                st.session_state.conn = conn
                st.session_state.connected = True
                st.sidebar.success("✅ Conectado exitosamente")
            else:
                st.sidebar.error("❌ Error de conexion")
                st.session_state.connected = False

    # Panel principal
    if st.session_state.get('connected', False):
        conn = st.session_state.conn

        # Calcular rango de fechas (dia operativo)
        fecha_inicio, fecha_fin = rango_dia_operativo(fecha_informe, hora_corte)

        st.info(f"📆 Periodo: {fecha_inicio.strftime('%d/%m/%Y %H:%M')} → {fecha_fin.strftime('%d/%m/%Y %H:%M')}")

        col1, col2 = st.columns([3, 1])

        with col1:
            if st.button("📊 Generar Informe", type="primary"):
                with st.spinner("Consultando base de datos..."):
                    try:
                        # Obtener mapeo de sucursales
                        suc_map = get_sucursales(conn)

                        # Obtener datos
                        progress = st.progress(0)
                        status = st.empty()

                        status.text("Obteniendo ventas...")
                        df_ventas = get_ventas(conn, fecha_inicio, fecha_fin)
                        progress.progress(20)

                        status.text("Calculando kilos (puede demorar)...")
                        df_kilos = get_detventas_kilos(conn, fecha_inicio, fecha_fin)
                        progress.progress(60)

                        status.text("Obteniendo turnos...")
                        df_turnos = get_turnos(conn, fecha_inicio, fecha_fin)
                        progress.progress(80)

                        status.text("Obteniendo tarjetas...")
                        df_tarjetas = get_tarjetas(conn, fecha_inicio, fecha_fin)
                        progress.progress(100)

                        status.empty()
                        progress.empty()

                        # Procesar datos
                        st.success(f"✅ Datos obtenidos: {len(df_ventas)} ventas, {len(df_kilos)} grupos de kilos")

                        turnos = procesar_ventas(df_ventas, suc_map)
                        kilos_raw = procesar_kilos(df_kilos, suc_map)
                        turnos_extra = procesar_turnos_extra(df_turnos, suc_map)
                        socios_raw = procesar_socios(df_tarjetas, suc_map)
                        clima = procesar_clima(get_clima(conn, fecha_inicio, fecha_fin), suc_map)
                        cajas = procesar_cajas_delivery(get_cajas_delivery(conn), suc_map)

                        # Ensamblar
                        datos_suc = ensamblar(turnos, kilos_raw, socios_raw, turnos_extra, clima, cajas)

                        # Guardar en session state
                        st.session_state.datos_suc = datos_suc
                        st.session_state.fecha_str = fecha_informe.strftime("%d/%m/%Y")

                        # Mostrar resumen
                        st.subheader("📈 Resumen del Informe")

                        total_ventas = 0
                        total_tickets = 0
                        total_kilos = 0

                        for suc in ORDEN_SUC:
                            filas = datos_suc.get(suc, [])
                            suc_ventas = sum(f["ventas"] for f in filas)
                            suc_tickets = sum(f["tickets"] for f in filas)
                            suc_kilos = sum(f["kilos"] for f in filas)

                            total_ventas += suc_ventas
                            total_tickets += suc_tickets
                            total_kilos += suc_kilos

                            st.write(f"**{SUC_DISPLAY.get(suc, suc)}**: ${suc_ventas:,.0f} | {suc_tickets} tickets | {suc_kilos:.1f} kg | {len(filas)} cajeros")

                        st.markdown("---")
                        col_m1, col_m2, col_m3, col_m4 = st.columns(4)
                        col_m1.metric("Ventas Totales", f"${total_ventas:,.0f}")
                        col_m2.metric("Transacciones", f"{total_tickets:,}")
                        col_m3.metric("Ticket Promedio", f"${total_ventas/total_tickets:,.0f}" if total_tickets > 0 else "$0")
                        col_m4.metric("Kilos", f"{total_kilos:.1f}")

                    except Exception as e:
                        st.error(f"Error al generar informe: {e}")
                        import traceback
                        st.code(traceback.format_exc())

        with col2:
            if st.session_state.get('datos_suc'):
                st.subheader("📥 Exportar")

                # Generar Excel
                wb = construir_excel(
                    st.session_state.datos_suc,
                    st.session_state.fecha_str
                )

                # Guardar en buffer
                buffer = io.BytesIO()
                wb.save(buffer)
                buffer.seek(0)

                # Boton de descarga
                fecha_file = fecha_informe.strftime("%Y-%m-%d")
                st.download_button(
                    label="⬇️ Descargar Excel",
                    data=buffer,
                    file_name=f"informe_grido_{fecha_file}.xlsx",
                    mime="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                    type="primary"
                )

    else:
        st.warning("👈 Configure la conexion a la base de datos en el panel lateral")

        # Mostrar informacion de ayuda
        st.markdown("""
        ### Instrucciones de uso

        1. **Configurar conexion**: Ingrese los datos del servidor SQL Server
        2. **Seleccionar fecha**: Elija la fecha del informe a generar
        3. **Generar informe**: Click en el boton para consultar la base de datos
        4. **Exportar**: Descargue el informe en formato Excel

        ### Requisitos

        - Acceso a la base de datos `Gestion_DB_Fernandez` en `PILLOWSRV001`
        - Driver ODBC 17 para SQL Server instalado
        - Permisos de lectura en las tablas: VENTAS, DETVENTAS, TURNOS, TARJETAS, SUCURSALES
        """)

if __name__ == "__main__":
    main()
