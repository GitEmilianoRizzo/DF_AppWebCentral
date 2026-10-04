# Informe Diario GRIDO: 5 hojas nuevas (Productos, Promociones, Sobreventas, Tickets, Efemérides)

**Para:** Emiliano (y su Claude, que trabaja con el data warehouse **DF_DTW**)
**De:** Damián Fernández
**Fecha:** 01/10/2026 (actualizado)
**Adjuntos:**
- `2026-09-27_InformeDiarioGRIDO_ejemplo.xlsx`: ejemplo terminado del 27/09/2026 (Informe Diario + las 5 hojas).
- `feriados.csv` y `efemerides.csv`: calendario que usa la hoja Efemérides.
- `control_columnas_informe_diario.csv`: valores esperados de las columnas nuevas del Informe Diario para el 27/09/2026.

---

## 1. Qué hay que hacer

Al Excel diario `AAAA-MM-DD_InformeDiarioGRIDO.xlsx` (una hoja: **«Informe Diario»**) hay que **agregarle 5 hojas**, en este orden:

1. **Productos**: todo lo vendido por sucursal (cantidad, kilos, venta), un **top 10 de las 3 sucursales juntas** con gráfico del aporte de cada una, y un **top 10 por sucursal** con gráfico.
2. **Promociones**: qué productos salieron dentro de cada promo y **cuántas veces se usó cada promo** por sucursal.
3. **Sobreventas**: productos aceptados como sobreventa y **ofrecidas / aceptadas / % por sucursal** (tomadas del Informe Diario).
4. **Tickets**: un renglón por ticket del día, con sucursal, cajero, hora, canal, importe, rubro principal, producto llevado, sobreventa y producto llevado en la sobreventa.
5. **Efemérides**: cartel «PRÓXIMAMENTE», si el día es feriado o efeméride, el próximo feriado y el calendario del año. El calendario incluye fechas escolares y otras fechas que pueden mover la venta.

Además, **en la hoja «Informe Diario» cambian 5 columnas**: Promos ($) pasa a tener dato, Club Grido se mide en kilos y las 3 columnas vacías del final se reemplazan por datos de clima del turno. Está detallado en la **sección 2 bis**. El archivo de ejemplo muestra exactamente cómo tiene que quedar.

---

## 2. Fuente de datos

- **Servidor / base:** SQL Server `.\SQLEXPRESS`, base **DF_DTW** (el warehouse).
- **Tabla:** `dbo.TRX_HUELLA_VENTA`, una fila por línea de ticket.
- **Día:** `FECHA_OPERATIVA`. Los tickets pasada la medianoche pertenecen al día operativo anterior, igual que en el Informe Diario.
- **Sucursales:** las mismas que tiene el Informe Diario. Hoy son `Fiorito`, `Escalada` y `Lanus Oeste`; no va `Mayorista`. Se matchean por `SUCURSAL_DESCRIP` = texto de la columna A de la fila de sucursal del Informe Diario.

### Cómo leer el Informe Diario (para las fórmulas)

- **Fila de sucursal:** la que tiene `B = "Todos"` (en A está el nombre de la sucursal).
- **Filas de cajeros:** las que siguen, con el nombre indentado.
- **Fila final:** `A = "TOTAL"`.
- **Columnas usadas:** `F` kilos · `G` venta · `I` tickets · **`J` sobreventas ofrecidas** · **`K` sobreventas aceptadas**.

---

## 2 bis. Cambios en la hoja «Informe Diario»

Cada fila de cajero es un **turno**: columna B = `TURNO` del POS. Los datos nuevos se calculan por `TURNO`.

| Col. | Antes | Ahora (encabezado de la fila 9) | Cómo se calcula |
|---|---|---|---|
| **M** | Promos ($), siempre 0 | **Promos ($)** | Venta en promociones del turno: `SUM(IMPORTE)` de las líneas con `PROMOCION_TIPO = 'PROMOCION'`. N (%Promos = M/G) no cambia |
| **P** | Ventas Club Grido ($) | **Kilos Club Grido** | Kilos vendidos a socios: `SUM(KILOS)` con `ES_CLUB_GRIDO = 1`. Formato `#,##0.0` |
| **Q** | %VCG/Ventas = `P/G` | **%Kilos CG /Kilos** | `=IFERROR(P/F;"")`. Ejemplo: 100 kg en total y 40 kg a socios → 40% |
| **T** | Personal (vacía) | **Sensación térmica promedio (°C)** | Promedio de `SENSACION_TERMICA` de la zona en las horas del turno. Una decimal |
| **U** | Productividad (vacía) | **Lluvia (mm)** | Suma de `PRECIPITACION` de la zona en las horas del turno. Una decimal |
| **V** | Clima (vacía) | **Condición climática** | `DESCRIPCION_TIEMPO` que más se repite en las horas del turno |

- **Fila 8:** se agrega el grupo «**CLIMA EN EL TURNO**» en T8:V8, celdas combinadas y con el mismo estilo que «CLUB GRIDO» (O8).
- **Filas de sucursal (B = «Todos»):**
  - M y P = `SUM` de sus cajeros.
  - Q = `IFERROR(P/F;"")`.
  - T, U y V = clima de todas las horas en que trabajó algún cajero de esa sucursal.
- **Fila TOTAL:**
  - P = suma de las filas de sucursal.
  - Q = `IFERROR(P/F;"")`.
  - T, U y V = clima de todas las horas del día con algún turno.
- **Horas del turno:** salen del Horario (columna D, por ejemplo «17:12 a 00:38»). Van de la hora de inicio a la hora de fin. Si la fin es menor que el inicio, el turno pasó la medianoche. La hora de fin cuenta si tiene minutos.
- **Clima de zona:**
  - **Fuente:** `dbo.CLIMA_ZONA_HORA`, ubicaciones Lanus Oeste, Escalada y Fiorito.
  - **Regla:** para cada hora se toma el dato con la **`FECHA_CARGA` más reciente** entre las 3 ubicaciones (si hay empate, el promedio).
  - **Por qué:** el clima viene de un modelo en grilla. Lanús y Escalada tienen el mismo dato y Fiorito difiere apenas. Las diferencias de un día puntual vienen de cargas hechas en distintos momentos (pronóstico contra dato ya ocurrido).
  - **Madrugada:** para las horas después de medianoche se usa `CLIMA_KEY_HORA` del día siguiente.

```sql
-- Q7. Promos ($) y Kilos Club Grido por turno
SELECT TURNO,
       SUM(CASE WHEN PROMOCION_TIPO = 'PROMOCION' THEN IMPORTE ELSE 0 END) AS PromosPesos,
       SUM(CASE WHEN ES_CLUB_GRIDO = 1 THEN KILOS ELSE 0 END)              AS KilosClubGrido
FROM dbo.TRX_HUELLA_VENTA
WHERE FECHA_OPERATIVA = @fecha AND ES_ANULADA = 0 AND SUCURSAL_DESCRIP IN (...)
GROUP BY TURNO;

-- Q8. Clima de zona por hora (de las 00 h del día a las 01 h del día siguiente)
WITH cz AS (
  SELECT CLIMA_KEY_HORA kh, SENSACION_TERMICA st, PRECIPITACION p, DESCRIPCION_TIEMPO d, FECHA_CARGA fc,
         MAX(FECHA_CARGA) OVER (PARTITION BY CLIMA_KEY_HORA) mfc
  FROM dbo.CLIMA_ZONA_HORA
  WHERE SUCURSAL_NOMBRE IN ('Lanus Oeste','Escalada','Fiorito')
    AND CLIMA_KEY_HORA >= @fecha AND CLIMA_KEY_HORA < DATEADD(hour, 26, CAST(@fecha AS datetime)))
SELECT kh, AVG(st) AS SensacionTermica, AVG(p) AS LluviaMm, MIN(d) AS Condicion
FROM cz WHERE fc = mfc GROUP BY kh;
```

**Valores del 27/09/2026 para controlar** (también en `control_columnas_informe_diario.csv`):

| Sucursal | Cajero | Turno | Promos ($) | Kilos Club Grido | Kilos | Sens. térmica | Lluvia mm | Condición |
|---|---|---|---|---|---|---|---|---|
| Fiorito | Candela | 9823 | 0 | 27,5 | 49,7 | 14,0 | 6,6 | Llovizna leve |
| Fiorito | Ailen | 9825 | 14.000 | 29,0 | 58,2 | 15,0 | 0,6 | Mayormente despejado |
| Fiorito | Veronica | 11774 | 0 | 9,5 | 17,9 | 14,4 | 4,1 | Llovizna leve |
| Fiorito | Luana | 11776 | 54.800 | 13,6 | 39,4 | 15,1 | 0,1 | Mayormente despejado |
| Escalada | Eliseo | 8470 | 64.560 | 3,6 | 22,0 | 13,7 | 3,4 | Llovizna moderada |
| Escalada | Silvia | 8471 | 0 | 13,5 | 33,0 | 14,7 | 3,2 | Llovizna leve |
| Escalada | Emiliano | 8472 | 33.700 | 9,2 | 34,8 | 15,0 | 0,5 | Mayormente despejado |
| Escalada | Camila | 9993 | 0 | 2,5 | 2,5 | 14,4 | 1,9 | Chaparrones leves |
| Escalada | Facundo | 9994 | 0 | 5,9 | 6,4 | 14,1 | 0,8 | Llovizna leve |
| Lanus Oeste | Oscar | 13390 | 42.100 | 28,3 | 50,5 | 14,1 | 6,2 | Chaparrones leves |
| Lanus Oeste | Wanda | 13391 | 59.760 | 22,5 | 63,3 | 14,6 | 1,0 | Llovizna leve |
| Lanus Oeste | Fiorella | 13889 | 39.120,02 | 5,7 | 17,5 | 13,9 | 6,5 | Llovizna leve |
| Lanus Oeste | Agustin | 13891 | 63.350,01 | 8,5 | 16,6 | 14,8 | 0,8 | Mayormente despejado |

Totales Club Grido en kilos: Fiorito 79,6 / 165,2 = **48,2%** · Escalada 34,7 / 98,7 = **35,1%** · Lanús 65,0 / 147,9 = **44,0%**.

---

## 3. Reglas de negocio (importantes)

1. **Excluir anuladas:** siempre `ES_ANULADA = 0`.
2. **Importes:** `IMPORTE` = importe **neto** que pagó el cliente por esa línea. `DESCUENTOS` = descuento **contra el precio de lista**. `KILOS` = helado equivalente.
3. **Tipos de promoción** en `PROMOCION_TIPO`:
   - `'PROMOCION'`
   - `'SOBREVENTA'`
   - `'CANJE'` (canje de puntos Club Grido; no se usa en estas hojas)
   - `'OTROS'` o NULL (venta normal)
4. **Estructura de cada uso de promo o sobreventa:**
   - **`PROMO = 2`:** línea **cabecera**, importe 0 y cantidad 0. Hay **una por cada uso** → **usos = cantidad de líneas con PROMO = 2**.
   - **`PROMO = 1`:** líneas de **producto** dentro de la promo, con cantidad, kilos, importe y descuento.
   - **Ejemplo:** un «2x1 en kilo» genera 1 cabecera y 2 líneas de «1 KILO», la segunda a $0,01 con todo el descuento.
5. **Hoja Productos:** incluye todas las líneas **menos las cabeceras** (`ISNULL(PROMO,0) <> 2`), o sea también lo que salió dentro de promos y sobreventas.
6. **Sobreventa a nivel ticket:** campo `SOBREVENTA` = `'ACEPTADA'`, `'RECHAZADA'` o NULL (no se ofreció).
   - Ofrecidas = tickets con ACEPTADA o RECHAZADA.
   - Aceptadas = tickets con ACEPTADA.
   - Estos conteos **coinciden** con las columnas J y K del Informe Diario, por eso en la hoja se toman con fórmula desde ahí.
7. **Un ticket puede llevar más de una sobreventa:** la suma de unidades por producto puede superar las «aceptadas». En el 27/09, Escalada tuvo 15 unidades contra 14 tickets aceptados.
8. **Venta del Informe Diario vs. suma por producto:** la venta del Informe Diario es la suma de `VTAIMPORTE` por ticket, que ya viene **neta** de los descuentos de PedidosYa / Rappi. La suma de `IMPORTE` por producto da algo más en las sucursales con apps (27/09: Fiorito +$40.810, Escalada +$104.094). No es un error: el POS no reparte ese descuento por producto.
9. **Promos de apps:** las de PEYA, «Apps» y «Pedí Grido» registran `DESCUENTOS = 0`, porque el precio ya viene rebajado.
10. **Dato a corregir en origen:** «Canje Torta Frutillas con Crema» figura como `PROMOCION` y no como `CANJE`.

---

## 4. Consultas SQL

Parámetros: `@fecha` (date) y la lista de sucursales del Informe Diario.

```sql
-- Filtro común
-- WHERE FECHA_OPERATIVA = @fecha AND ES_ANULADA = 0
--   AND SUCURSAL_DESCRIP IN ('Fiorito','Escalada','Lanus Oeste')

-- Q1. PRODUCTOS
SELECT SUCURSAL_DESCRIP AS Suc,
       ISNULL(ART_GRUPO_DESCRIP,'(sin rubro)') AS Rubro,
       ART_DESCRIP AS Producto,
       SUM(CANTIDAD) AS Cantidad, SUM(KILOS) AS Kilos, SUM(IMPORTE) AS Venta
FROM dbo.TRX_HUELLA_VENTA
WHERE FECHA_OPERATIVA = @fecha AND ES_ANULADA = 0 AND SUCURSAL_DESCRIP IN (...)
  AND ISNULL(PROMO,0) <> 2
GROUP BY SUCURSAL_DESCRIP, ART_GRUPO_DESCRIP, ART_DESCRIP;
-- Orden: sucursal (orden del Informe Diario), Rubro A-Z, Cantidad desc.

-- Q2. PROMOCIONES: productos dentro de cada promo
SELECT SUCURSAL_DESCRIP AS Suc, PROMOCION_DESCRIP AS Promocion, ART_DESCRIP AS Producto,
       SUM(CANTIDAD) AS Cantidad, SUM(KILOS) AS Kilos, SUM(IMPORTE) AS Venta, SUM(DESCUENTOS) AS Descuento
FROM dbo.TRX_HUELLA_VENTA
WHERE FECHA_OPERATIVA = @fecha AND ES_ANULADA = 0 AND SUCURSAL_DESCRIP IN (...)
  AND PROMOCION_TIPO = 'PROMOCION' AND PROMO = 1
GROUP BY SUCURSAL_DESCRIP, PROMOCION_DESCRIP, ART_DESCRIP;
-- Orden: sucursal, Promocion A-Z, Cantidad desc.

-- Q3. PROMOCIONES: usos por promo y sucursal
SELECT SUCURSAL_DESCRIP AS Suc, PROMOCION_DESCRIP AS Promocion,
       SUM(CASE WHEN PROMO = 2 THEN 1 ELSE 0 END) AS Usos
FROM dbo.TRX_HUELLA_VENTA
WHERE FECHA_OPERATIVA = @fecha AND ES_ANULADA = 0 AND SUCURSAL_DESCRIP IN (...)
  AND PROMOCION_TIPO = 'PROMOCION'
GROUP BY SUCURSAL_DESCRIP, PROMOCION_DESCRIP;
-- Se pivotea: una fila por promo, una columna por sucursal. Orden: total de usos desc. Se omiten las de 0 usos.

-- Q4. SOBREVENTAS: productos aceptados
SELECT SUCURSAL_DESCRIP AS Suc, PROMOCION_DESCRIP AS Sobreventa, ART_DESCRIP AS Producto,
       SUM(CANTIDAD) AS Cantidad, SUM(KILOS) AS Kilos, SUM(IMPORTE) AS Venta, SUM(DESCUENTOS) AS Descuento
FROM dbo.TRX_HUELLA_VENTA
WHERE FECHA_OPERATIVA = @fecha AND ES_ANULADA = 0 AND SUCURSAL_DESCRIP IN (...)
  AND PROMOCION_TIPO = 'SOBREVENTA' AND PROMO = 1
GROUP BY SUCURSAL_DESCRIP, PROMOCION_DESCRIP, ART_DESCRIP;

-- Q6. TICKETS: un renglón por ticket
WITH l AS (
  SELECT SUCURSAL_DESCRIP suc, USULOGIN u, TICKET_KEY tk, HORA, SOBREVENTA sv, PROMOCION_TIPO pt, PROMO,
         ART_GRUPO_DESCRIP grp, ART_DESCRIP art, CANTIDAD, IMPORTE, VTAIMPORTE, ES_PLATAFORMA_DELIVERY plat, PLATAFORMA
  FROM dbo.TRX_HUELLA_VENTA
  WHERE FECHA_OPERATIVA = @fecha AND ES_ANULADA = 0 AND SUCURSAL_DESCRIP IN (...)),
t AS (SELECT suc, u, tk, MIN(HORA) hora, MAX(sv) sv, MAX(CAST(plat AS int)) plat,
             MAX(ISNULL(PLATAFORMA,'')) plataforma, MAX(VTAIMPORTE) importe
      FROM l GROUP BY suc, u, tk),
mainp AS (SELECT tk, grp, ROW_NUMBER() OVER (PARTITION BY tk ORDER BY IMPORTE DESC, CANTIDAD DESC) rn
          FROM l WHERE ISNULL(pt,'') <> 'SOBREVENTA' AND ISNULL(PROMO,0) <> 2),
prod AS (SELECT tk, STRING_AGG(CAST(CONCAT(CAST(CAST(CANTIDAD AS decimal(9,0)) AS varchar(10)), ' ', LTRIM(RTRIM(art))) AS nvarchar(max)), ' + ')
                    WITHIN GROUP (ORDER BY IMPORTE DESC) productos
         FROM l WHERE ISNULL(PROMO,0) <> 2 AND ISNULL(pt,'') <> 'SOBREVENTA' GROUP BY tk),
psv AS (SELECT tk, STRING_AGG(CAST(CONCAT(CAST(CAST(CANTIDAD AS decimal(9,0)) AS varchar(10)), ' ', LTRIM(RTRIM(art))) AS nvarchar(max)), ' + ')
                   WITHIN GROUP (ORDER BY IMPORTE DESC) productos_sv
        FROM l WHERE pt = 'SOBREVENTA' AND PROMO = 1 GROUP BY tk)
SELECT t.suc AS Sucursal, t.u AS Cajero, t.hora AS Hora,
       CASE WHEN t.plat = 0 THEN 'Salón' WHEN t.plataforma = 'PosLocal' THEN 'Delivery propio' WHEN t.plataforma <> '' THEN t.plataforma ELSE 'Delivery' END AS Canal,
       t.importe AS Importe, ISNULL(LTRIM(RTRIM(m.grp)),'(sin dato)') AS RubroPrincipal,
       p.productos AS ProductoLlevado,
       CASE WHEN t.sv = 'ACEPTADA' THEN 'Aceptada' WHEN t.sv = 'RECHAZADA' THEN 'Rechazada' ELSE 'No ofrecida' END AS Sobreventa,
       s.productos_sv AS ProductoLlevadoEnSV
FROM t LEFT JOIN mainp m ON m.tk = t.tk AND m.rn = 1
       LEFT JOIN prod p ON p.tk = t.tk
       LEFT JOIN psv s ON s.tk = t.tk;
-- Orden: sucursal (orden del Informe Diario), cajero, hora, ticket.
-- Cajero: USULOGIN viene en minúscula (ej. "ailen"); se muestra con el nombre tal como figura en el Informe Diario (match sin distinguir mayúsculas).
-- Importe = VTAIMPORTE del ticket: la suma da exactamente la venta del Informe Diario.

-- (Control) Q5. SOBREVENTAS ofrecidas / aceptadas por sucursal: debe coincidir con J y K del Informe Diario
WITH t AS (SELECT SUCURSAL_DESCRIP suc, TICKET_KEY, MAX(SOBREVENTA) sv
           FROM dbo.TRX_HUELLA_VENTA
           WHERE FECHA_OPERATIVA = @fecha AND ES_ANULADA = 0 AND SUCURSAL_DESCRIP IN (...)
           GROUP BY SUCURSAL_DESCRIP, TICKET_KEY)
SELECT suc, SUM(CASE WHEN sv IN ('ACEPTADA','RECHAZADA') THEN 1 ELSE 0 END) AS Ofrecidas,
            SUM(CASE WHEN sv = 'ACEPTADA' THEN 1 ELSE 0 END) AS Aceptadas
FROM t GROUP BY suc;
```

---

## 5. Diseño de las hojas

### Estilo general (igual en las 4 hojas)

- **Tipografía:** Arial 9 en el cuerpo. Sin líneas de cuadrícula. Zoom 90%.
- **Encabezado:**
  - Fila 1: banner fondo `#1E2D3D`, texto blanco Arial 16 negrita.
  - Fila 2: subtítulo fondo `#2C3E50`, texto `#D5DBE1` Arial 9.
  - Fila 3: vacía (separador).
- **Filas de encabezado de tabla:** texto blanco negrita, centrado, con ajuste de línea, alto 30.
- **Fila TOTAL:** fondo `#1A252F`, texto blanco negrita, con fórmulas `SUM`.
- **Colores de sucursal:** salen del propio Informe Diario, de la fila de sucursal y de las de cajeros.

  | Sucursal | Oscuro | Claro |
  |---|---|---|
  | Fiorito | `#4A7C59` | `#EBF5EE` |
  | Escalada | `#2E4053` | `#EAF0FB` |
  | Lanus Oeste | `#784212` | `#FEF5E7` |

  - En las tablas de detalle, cada fila lleva fondo claro de su sucursal, y la columna Sucursal va en negrita con el color oscuro.
- **Formatos:** cantidad `#,##0` · kilos `#,##0.0` · pesos `$#,##0` · porcentaje `0.0%`.
- **Paleta para ítems varios** (productos de sobreventa, donas): `#784212, #C0392B, #1F618D, #4A7C59, #D68910, #7D3C98, #5D6D7E, #A04000, #117A65, #2E4053`.
- **Color de la pestaña:** Productos `#784212` · Promociones `#1F618D` · Sobreventas `#4A7C59` · Tickets `#5D6D7E` · Efemérides `#7D3C98`.

### 5.1 Hoja «Productos»

- **Banner:** «PRODUCTOS VENDIDOS · dd/mm/aaaa». Subtítulo: «Todas las unidades vendidas por sucursal, incluidas las que salieron dentro de promociones y sobreventas.»
- **Tabla de detalle (izquierda):**
  - Encabezado en la fila 4, columnas A a F: **Sucursal | Rubro | Producto | Cantidad | Kilos | Venta** (fondo `#1E2D3D`).
  - Datos desde la fila 5, con la consulta Q1.
  - Fila TOTAL al final.
  - Autofiltro en A4:F(última fila). Paneles inmovilizados debajo de la fila 4. Barra de datos en Cantidad (`#C39B77`).
- **Top 10 de las 3 sucursales juntas (derecha, arranca en la fila 4, columnas H a M):**
  - **Título:** «TOP 10 PRODUCTOS POR CANTIDAD · LAS 3 SUCURSALES JUNTAS», fondo `#1E2D3D`.
  - **Encabezado:** **Producto | Fiorito | Escalada | Lanus Oeste | Total | % de las unidades**. Cada columna de sucursal con su color oscuro; Total en `#1A252F`.
  - **Filas:** los 10 productos con más cantidad sumando las 3 sucursales (mismas exclusiones que abajo).
    - Cada sucursal = `SUMIFS(D:D; A:A; "Sucursal"; C:C; H<fila>)`.
    - Total = `SUM` de las sucursales.
    - % = Total / `SUM(D:D)`.
  - **Formato:** filas alternadas blanco y `#EAEDED`. Barra de datos en Total.
  - **Gráfico:** barras horizontales **apiladas**, una serie por sucursal con su color, para ver **cuánto aporta cada sucursal a cada producto**. Es el mismo estilo que el de Promociones y va a la derecha del bloque (desde la columna O).
- **Top 10 por sucursal (debajo del anterior, columnas H a K):** un bloque por sucursal, apilados. Cada bloque ocupa 22 filas y el primero arranca en la fila 26.
  - **Título:** «TOP 10 PRODUCTOS POR CANTIDAD · SUCURSAL», fondo del color oscuro de la sucursal.
  - **Encabezado:** **Producto | Cantidad | Venta | % de las unidades**, fondo oscuro de la sucursal.
  - **Filas:** los 10 productos con más cantidad de esa sucursal (agrupados por nombre). Se excluyen el rubro `DELIVERY`, los productos que empiezan con `ENVIO` y las cantidades ≤ 0.
  - **Fórmulas** (para que siga a la tabla de detalle):
    - Cantidad = `SUMIFS(D:D; A:A; "Sucursal"; C:C; H<fila>)`
    - Venta = `SUMIFS(F:F; A:A; "Sucursal"; C:C; H<fila>)`
    - % = Cantidad / `SUMIF(A:A; "Sucursal"; D:D)`
    - Los rangos van acotados a las filas del detalle.
  - **Formato de filas:** alternadas, blanco y color claro de la sucursal. Barra de datos en Cantidad con el color oscuro.
  - **Gráfico:** barras horizontales con el top 10, color de la sucursal, etiquetas de valor, el mayor arriba y sin eje de valores. Va al lado del bloque (columnas O a W).
- **Anchos de columna:** A 13 · B 18 · C 34 · D 10 · E 10 · F 13 · G 3 · H 32 · I a M 12 · N 3.

### 5.2 Hoja «Promociones»

- **Banner:** «PROMOCIONES · dd/mm/aaaa». Subtítulo: «Qué productos salieron dentro de cada promoción y cuántas veces se usó cada una.»
- **Tabla de detalle (izquierda):**
  - Encabezado en la fila 4, columnas A a G: **Sucursal | Promoción | Producto | Cantidad | Kilos | Venta | Descuento** (fondo `#1F618D`).
  - Datos con la consulta Q2 y fila TOTAL. Autofiltro y paneles inmovilizados en la fila 4.
  - Si no hubo promos, poner el texto «Sin promociones en el día».
- **Usos por promoción (derecha, desde la columna I):**
  - **Fila 4:** título «USOS POR PROMOCIÓN», fondo `#1F618D`.
  - **Fila 5, encabezado:** **Promoción | <una columna por sucursal> | Total**. Cada columna de sucursal lleva su color oscuro y Total va en `#1A252F`.
  - **Filas:** consulta Q3 pivoteada. Total = `SUM` de la fila. Filas alternadas `#EBF5FB` / blanco. Fila TOTAL con `SUM`.
  - **Nota debajo:** «Usos = veces que se aplicó la promoción. Las promos de apps (PedidosYa / Apps) no registran descuento en el POS.»
  - **Gráfico:** barras horizontales **apiladas**, una serie por sucursal con su color, categorías = promociones. Va debajo de la tabla de usos.
- **Anchos de columna:** A 13 · B 36 · C 30 · D 10 · E 10 · F 13 · G 13 · H 3 · I 40 · una columna de 12 por cada sucursal · Total 11.

### 5.3 Hoja «Sobreventas»

- **Banner:** «SOBREVENTAS · dd/mm/aaaa». Subtítulo: «Qué productos se llevaron como sobreventa y cómo convirtió cada sucursal. Ofrecidas y aceptadas salen de la hoja «Informe Diario».»
- **Tabla de detalle (izquierda):**
  - Encabezado en la fila 4, columnas A a G: **Sucursal | Sobreventa | Producto | Cantidad | Kilos | Venta | Descuento** (fondo `#6B4226`).
  - Datos con la consulta Q4 y fila TOTAL. Autofiltro y paneles inmovilizados.
- **Ofrecidas y aceptadas (derecha, columnas I a N):**
  - **Fila 4:** título «OFRECIDAS Y ACEPTADAS · según Informe Diario», fondo `#6B4226`.
  - **Fila 5, encabezado:** **Sucursal | Ofrecidas | Aceptadas | Rechazadas | % aceptación | Estándar**.
  - **Una fila por sucursal:**
    - Sucursal = `='Informe Diario'!A<fila sucursal>`
    - Ofrecidas = `='Informe Diario'!J<fila sucursal>`
    - Aceptadas = `='Informe Diario'!K<fila sucursal>`
    - Rechazadas = Ofrecidas − Aceptadas
    - % = Aceptadas / Ofrecidas
    - Estándar = 15%
  - **Fila TOTAL:** `SUM` de las columnas y el % recalculado.
  - **Formato condicional en %:** si es menor al estándar, fondo `#C0392B` y texto blanco negrita; si es mayor o igual, fondo `#1E8449` y texto blanco negrita.
- **Aceptadas por producto:** 3 filas debajo del total.
  - **Título:** «ACEPTADAS POR PRODUCTO».
  - **Encabezado:** **Producto | Cantidad | Venta | % de las unidades**.
  - **Filas:** una por producto (sumando las 3 sucursales), ordenadas por cantidad. Cantidad y Venta con `SUMIF` sobre la tabla de detalle.
  - La celda Producto lleva un color de la paleta.
  - **Nota:** «Un ticket puede llevar más de una sobreventa: por eso la suma por producto puede superar las aceptadas del Informe Diario.»
- **Gráficos:**
  - Columnas **apiladas** por sucursal: Aceptadas (`#6B4226`) y Rechazadas (`#D5D8DC`).
  - **Dona** «Sobreventas por producto», con la paleta.

### 5.4 Hoja «Tickets»

- **Banner:** «TICKETS DEL DÍA · DÍA dd/mm/aaaa». Subtítulo: «Un renglón por ticket: qué se llevó el cliente y qué pasó con la sobreventa. Usá los filtros (por ejemplo «Cajero») para ver a una persona.»
- **Encabezado (fila 4, columnas A a I), exactamente estos campos:**

  | Columna | Campo | Contenido |
  |---|---|---|
  | A | **Sucursal** | Nombre de la sucursal, en negrita con su color oscuro |
  | B | **Cajero** | Nombre como figura en el Informe Diario |
  | C | **Hora** | Hora del ticket, formato «17 h» |
  | D | **Canal** | Salón / Delivery propio / PedidosYa / Rappi / PediGrido… |
  | E | **Importe** | `VTAIMPORTE` del ticket, formato `$#,##0` |
  | F | **Rubro principal** | Grupo del producto de mayor importe del ticket, sin contar la sobreventa |
  | G | **Producto llevado** | Productos del ticket sin la sobreventa, ej. «1 1 KILO + 2 CUPS BLACK X 3» |
  | H | **Sobreventa** | Aceptada / Rechazada / No ofrecida |
  | I | **Producto llevado en SV** | Productos de sobreventa del ticket, ej. «1 1/4 KILO» (vacío si no hubo) |

  Encabezados A a G con fondo `#1E2D3D` y H e I con fondo `#6B4226`.
- **Filas:** consulta Q6, una por ticket, con el fondo claro de su sucursal.
  - **Celda Sobreventa:** «Aceptada» fondo `#1E8449` con texto blanco negrita; «Rechazada» fondo `#FADBD8` con texto `#C0392B` negrita; «No ofrecida» fondo `#EAEDED` con texto gris.
  - **Producto llevado en SV:** en negrita cuando hay.
- **Autofiltro** en A4:I(última fila) y paneles inmovilizados debajo de la fila 4.
- **Fila TOTAL:** Cajero = `SUBTOTAL(103; A5:A…)` (cantidad de tickets visibles) e Importe = `SUBTOTAL(109; E5:E…)`. Con `SUBTOTAL`, al filtrar por un cajero el total muestra solo lo de ese cajero.
- **Nota al pie:** explica que el Importe es neto de descuentos de apps (coincide con el Informe Diario) y que en apps no se ofrece sobreventa.
- **Anchos de columna:** A 13 · B 13 · C 8 · D 11 · E 12 · F 18 · G 70 · H 13 · I 24.

### 5.5 Hoja «Efemérides»

- **Banner:** «EFEMÉRIDES · DÍA dd/mm/aaaa».
- **Filas 4 a 6:** cartel **«PRÓXIMAMENTE»** en A4:E6 combinadas. Arial 28 negrita `#7D3C98` sobre fondo `#F4ECF7`.
- **Fila 7:** nota «En esta solapa se van a sumar las efemérides de cada día…».
- **Sección «EL DÍA»:** título en la fila 9, fondo `#7D3C98`.
  - **Fecha** (B10, formato fecha) y **Día** (nombre del día).
  - **¿Feriado?:** «Sí» con fondo rojo `#C0392B` más el nombre, o «No» con fondo verde `#1E8449`.
  - **Efeméride:** «Sí» con fondo ámbar `#D68910` más el nombre, o «No» en gris.
  - **Próximo feriado:** fecha más «Día: nombre». Solo cuenta el tipo `Feriado`, no los puentes.
  - **Faltan (días):** `=B14-B10`.
- **Sección «CALENDARIO AAAA»:** título en la fila 17.
  - **Título:** «CALENDARIO AAAA: FERIADOS, DÍAS NO LABORABLES Y FECHAS QUE PUEDEN AFECTAR LAS VENTAS».
  - **Encabezado (fila 18):** **Fecha | Día | Qué se celebra / qué pasa | Tipo | Faltan (días) | Verificado**. Lleva autofiltro.
  - **Filas:** todos los feriados, días no laborables y puentes del año, más las efemérides del año (de `efemerides.csv`), ordenados por fecha. Faltan = `=A<fila>-$B$10` (negativo si ya pasó).
  - **Tipo:** `Feriado` / `No laborable` / `Puente` para los feriados, y «Efeméride · <Tipo>» para las efemérides (ej. «Efeméride · Escolar»).
  - **Verificado:** el valor del CSV («Sí (fecha fija)», «Sí (3er domingo de agosto)»…). Si no está confirmado se muestra **«A verificar»** en rojo.
  - **Colores:**
    - Fechas pasadas en gris `#A6ACAF`.
    - El día evaluado con fondo `#F5B7B1`.
    - El próximo feriado con fondo `#FDEBD0` y el texto «← próximo feriado».
    - Efemérides por tipo: Escolar `#EBF5FB` · Familiar `#FEF9E7` · Ingresos `#EAFAF1` · Deportivo `#FDEDEC` · Electoral `#F4F6F7` · Comercial `#FEF5E7`.
  - **Nota** sobre la fuente del calendario.
- **Calendario:** sale de dos CSV (UTF-8 con BOM, separador `;`). El equipo los mantiene.
  - `feriados.csv`: `Fecha;Nombre;Tipo;Verificado`. Tipo = `Feriado` / `No laborable` / `Puente`. Los trasladables van en el día en que se gozan. Se **cargaron de memoria**: conviene confirmar los marcados `Verificado = No`, sobre todo los puentes de 2026.
  - `efemerides.csv`: `Fecha;Nombre;Clave;Tipo;Verificado`, de 2024 a 2027. Puede haber dos filas con la misma fecha (ej. 20/07/2026: inicio del receso invernal y Día del Amigo): se muestran las dos. Incluye:
    - **Escolar** (Provincia de Buenos Aires, aplica a Lanús y Lomas de Zamora): inicio de clases, inicio y fin del receso invernal, fin de clases, Día del Maestro (11/09, sin clases) y Día del Estudiante (21/09, sin clases). Son **aproximadas: confirmar con el calendario escolar oficial de la DGCyE**.
    - **Familiar:** Pascua, Día del Padre, Día del Niño, Día de la Madre, Nochebuena y Fin de año.
    - **Ingresos:** fecha límite de pago del aguinaldo (30/06 y 18/12).
    - **Deportivo:** final de la Copa América 2024; inicio, partidos de Argentina en fase de grupos y final del Mundial 2026 (fechas a verificar).
    - **Electoral:** elecciones provinciales y nacionales 2025, generales 2027 (aprox.).
    - **Comercial:** San Valentín, Día del Amigo y Halloween.
    - **Evento:** visita del Papa León XIV (DNU 1103/2026). El 8/11/2026 llega y no es feriado. El 10/11/2026 hay feriado solo en CABA y Córdoba, que no rige en Lanús ni en Lomas de Zamora.
  - **Visita del Papa en `feriados.csv`:**
    - **9/11/2026:** feriado nacional.
    - **11/11/2026:** feriado de la **Provincia de Buenos Aires** (Tipo = `Feriado provincial`; rige en Lanús y Lomas de Zamora). Ese día es la misa en Luján, con 3 a 4 millones de personas esperadas.
  - **2027:** el calendario se muestra desde enero del año del informe **hasta el 1 de mayo del año siguiente**. Están cargados los feriados de 2027 hasta el 01/05: 1/1, Carnaval 8 y 9/2, 24/3, Jueves Santo 25/3 (no laborable), Viernes Santo 26/3, 2/4 y 1/5. Los puentes de 2027 todavía no están decretados.
  - **«Próximo feriado»:** cuenta los tipos `Feriado` y `Feriado provincial`.

---

## 6. Caso de prueba: 27/09/2026 (para validar la implementación)

| Control | Fiorito | Escalada | Lanus Oeste | Total |
|---|---|---|---|---|
| Productos: filas (sucursal-rubro-producto) | 76 | 62 | 69 | **207** |
| Productos: cantidad | 390 | 252 | 324 | **966** |
| Productos: kilos | 165,205 | 98,641 | 147,982 | **411,828** |
| Productos: venta | $2.877.953 | $1.879.880,02 | $2.519.830,03 | **$7.277.663,05** |
| Promociones: usos | 3 | 7 | 17 | **27** |
| Promociones: cantidad / venta / descuento | 5 / $68.800 / $3.500 | 9 / $98.260 / $16.140 | 25 / $204.330,03 / $35.120 | **39 / $371.390,03 / $54.760** |
| Sobreventas: unidades / venta / descuento | 23 / $115.000 / $28.600 | 15 / $72.600 / $19.800 | 13 / $69.200 / $18.400 | **51 / $256.800 / $66.800** |
| Sobreventas: ofrecidas / aceptadas (= Informe Diario J / K) | 162 / 23 | 85 / 14 | 146 / 13 | **393 / 50** |
| Top 10 Fiorito, primeros 3 | 1 KILO (43), ¼ KILO (40), ½ KILO (34) | | | |
| Top 10 de las 3 juntas: 1.º, 2.º y 3.º (Fiorito / Escalada / Lanús = Total) | | | | 1 KILO: 43 / 23 / 41 = **107** · ¼ KILO: 40 / 12 / 33 = **85** · ½ KILO: 34 / 17 / 21 = **72** |
| Tickets: renglones | | | | **496** |
| Tickets: suma de Importe (= venta del Informe Diario) | $2.837.143 | $1.775.786,02 | $2.519.830 | **$7.132.759,02** |
| Tickets: Aceptada / Rechazada / No ofrecida | | | | **50 / 343 / 103** |

El archivo de ejemplo adjunto tiene estos números.

---

## 7. Sugerencia de pedido para tu Claude

> «Tengo el Excel diario `AAAA-MM-DD_InformeDiarioGRIDO.xlsx` con la hoja "Informe Diario". Aplicá los cambios de la sección 2 bis en la hoja "Informe Diario" (Promos $, Kilos Club Grido, %Kilos CG y las 3 columnas de clima) y agregale las hojas Productos, Promociones, Sobreventas, Tickets y Efemérides siguiendo `LEEME_Hojas_Informe_Diario_GRIDO.md`: mismas consultas contra DF_DTW, mismas reglas y mismo diseño. Usá el Excel de ejemplo del 27/09/2026 como referencia visual y validá con los números de las secciones 2 bis y 6. El resto de la hoja "Informe Diario" no se toca.»

Si el Informe Diario se genera con Python / openpyxl, todo se puede hacer ahí mismo:
- Fórmulas escritas como texto: `SUMIFS`, `SUMIF`, `SUM` y referencias `'Informe Diario'!J12`.
- `PatternFill` y `Font` para los colores.
- `ConditionalFormatting` con `CellIsRule` para el % de aceptación y `DataBarRule` para las barras.
- `openpyxl.chart.BarChart` con `type="bar"`, `grouping="stacked"` y `overlap=100` para los apilados, y `DoughnutChart` para la dona.
