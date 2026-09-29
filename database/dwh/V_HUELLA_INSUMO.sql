/* ===========================================================================
   DF_DTW.dbo.V_HUELLA_INSUMO
   ---------------------------------------------------------------------------
   La contribucion marginal abierta INSUMO POR INSUMO.

   TRX_HUELLA_VENTA guarda una fila por linea de venta, con la receta resuelta
   en siete slots de columnas. Esta vista desarma esos slots: devuelve una fila
   por (linea de venta x insumo consumido).

   No duplica nada en la tabla: la huella sigue teniendo una fila por venta.
   La explosion ocurre al consultar.

   COMO SUMAR SIN CONTAR DOS VECES
   -------------------------------
   En esta vista, IMPORTE y COSTO_PRODUCTO estan REPETIDOS en cada insumo de la
   misma linea: son de la linea, no del insumo. Sumarlos aca multiplica la
   venta por la cantidad de insumos.
     - Consumo y costo de insumos  -> sumar en esta vista.
     - Venta, costo de producto,
       contribucion marginal total -> sumar en TRX_HUELLA_VENTA.
   Para repartir la contribucion marginal entre insumos esta CM_IMPUTADA, que
   prorratea la contribucion de la linea segun lo que pesa cada insumo en el
   costo de descartables. Esa SI suma bien aca.

   Creado: 2026-09-19
   =========================================================================== */

USE DF_DTW;
GO

IF OBJECT_ID('dbo.V_HUELLA_INSUMO', 'V') IS NOT NULL
    DROP VIEW dbo.V_HUELLA_INSUMO;
GO

CREATE VIEW dbo.V_HUELLA_INSUMO
AS
SELECT
    -- ---- de donde viene ----
    h.BASE_ORIGEN,
    h.ZONA,
    h.FECHA_OPERATIVA,
    h.FECHA_HORA,
    h.SUCURSAL,
    h.SUCURSAL_DESCRIP,
    h.CAJA,
    h.VENTA,
    h.DETVENTA,
    h.TICKET_KEY,
    h.LINEA_KEY,
    h.USULOGIN,
    h.TURNO,
    h.ES_FACTURABLE,
    h.ES_ANULADA,

    -- ---- el articulo que se vendio ----
    h.ARTICULO,
    h.ART_DESCRIP,
    h.ART_GRUPO_DESCRIP,
    h.ART_RUBROCOM_DESCRIP,
    h.CANTIDAD                AS CANT_VENDIDA,

    -- ---- el insumo que consumio ----
    x.SLOT,
    x.INSUMO_ARTICULO,
    INSUMO_DESCRIP = dic.DESCRIP,
    INSUMO_TIPO    = dic.TIPO,
    x.CONSUMO,                                  -- en unidades
    UNID_X_BULTO   = dic.UNID_X_BULTO,
    COSTO_BULTO    = dic.COSTO_BULTO,           -- lo que figura en el maestro
    x.COSTO_UNIT,                               -- ya dividido por bulto
    x.COSTO_INSUMO,                             -- CONSUMO * COSTO_UNIT

    /* Un comp de tipo M. PRIMA no es un descartable: es el producto vendido
       referenciado desde su propia receta, y su costo ya esta en
       COSTO_PRODUCTO_LINEA. Se deja visible (sirve para stock: cuantas tortas
       salieron) pero NO entra en el costo de insumos ni en el prorrateo.
       Para analizar descartables: WHERE ES_DESCARTABLE = 1. */
    ES_DESCARTABLE = CAST(CASE WHEN ISNULL(dic.TIPO, '') = 'M. PRIMA' THEN 0 ELSE 1 END AS bit),

    -- ---- de la linea: REPETIDO por insumo, no sumar aca ----
    h.IMPORTE                 AS IMPORTE_LINEA,
    h.COSTO                   AS COSTO_PRODUCTO_LINEA,
    h.INSUMOS_COSTO           AS INSUMOS_COSTO_LINEA,
    h.CONTRIB_MARGINAL        AS CM_LINEA,

    /* Contribucion marginal imputada a este insumo.
       Se reparte la CM de la linea en proporcion a lo que pesa el insumo
       dentro del costo total de descartables de esa linea. Sirve para
       responder "que me deja cada envase" sin contar la venta varias veces:
       la suma de CM_IMPUTADA de una linea da su CM_LINEA.
       Cuando la linea no tiene costo de insumos se reparte en partes iguales,
       para no perder la contribucion por una division por cero. */
    CM_IMPUTADA = CAST(
        CASE
            WHEN ISNULL(dic.TIPO, '') = 'M. PRIMA' THEN 0
            WHEN ISNULL(h.INSUMOS_COSTO, 0) > 0
                THEN h.CONTRIB_MARGINAL * (x.COSTO_INSUMO / h.INSUMOS_COSTO)
            ELSE 0
        END AS numeric(18,4))
FROM dbo.TRX_HUELLA_VENTA h
CROSS APPLY (VALUES
    (1, h.INSUMO1_ARTICULO, h.INSUMO1_CONSUMO, h.INSUMO1_COSTO_UNIT, h.INSUMO1_COSTO),
    (2, h.INSUMO2_ARTICULO, h.INSUMO2_CONSUMO, h.INSUMO2_COSTO_UNIT, h.INSUMO2_COSTO),
    (3, h.INSUMO3_ARTICULO, h.INSUMO3_CONSUMO, h.INSUMO3_COSTO_UNIT, h.INSUMO3_COSTO),
    (4, h.INSUMO4_ARTICULO, h.INSUMO4_CONSUMO, h.INSUMO4_COSTO_UNIT, h.INSUMO4_COSTO),
    (5, h.INSUMO5_ARTICULO, h.INSUMO5_CONSUMO, h.INSUMO5_COSTO_UNIT, h.INSUMO5_COSTO),
    (6, h.INSUMO6_ARTICULO, h.INSUMO6_CONSUMO, h.INSUMO6_COSTO_UNIT, h.INSUMO6_COSTO),
    (7, h.INSUMO7_ARTICULO, h.INSUMO7_CONSUMO, h.INSUMO7_COSTO_UNIT, h.INSUMO7_COSTO)
) x(SLOT, INSUMO_ARTICULO, CONSUMO, COSTO_UNIT, COSTO_INSUMO)
LEFT JOIN dbo.DIM_INSUMO_COSTO dic
       ON dic.BASE_ORIGEN = h.BASE_ORIGEN
      AND dic.ARTICULO    = x.INSUMO_ARTICULO
      AND h.FECHA_HORA   >= dic.VIGENTE_DESDE
      AND h.FECHA_HORA    < dic.VIGENTE_HASTA
WHERE x.INSUMO_ARTICULO IS NOT NULL;
GO
