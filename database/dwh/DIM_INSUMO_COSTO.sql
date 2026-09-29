/* ===========================================================================
   DF_DTW.dbo.DIM_INSUMO_COSTO  +  dbo.usp_RefrescarDimInsumoCosto
   ---------------------------------------------------------------------------
   El costo de cada insumo a lo largo del tiempo, en intervalos de vigencia.

   PARA QUE
   --------
   La huella congela la RECETA al momento de la venta (sale de
   ARTICULOSHISTORICO del articulo vendido). Pero el COSTO del insumo no se
   puede congelar igual, porque la linea de venta no registra que version del
   insumo se uso. Sin esto habria que usar el costo de HOY, y eso destruye
   cualquier analisis historico: la servilleta paso de $580 a $137.405 en 65
   versiones. Un pote de 2024 costeado a valores de 2026 no dice nada.

   COMO
   ----
   ARTICULOSHISTORICO guarda una fila por cada version del articulo con su
   ARTFECESTADO. Se las ordena por fecha y se arma el intervalo
   [VIGENTE_DESDE, VIGENTE_HASTA) de cada costo. Despues, costear una venta es
   un join por rango de fecha.

   EL COSTO VIENE POR BULTO
   ------------------------
   ARTCOSTO esta expresado por BULTO, no por unidad: la servilleta figura a
   $17.532 porque es el paquete de 2000. El costo por unidad es
   ARTCOSTO / ARTUNIDXBULTO, y es lo que hay que usar contra el consumo, que
   esta en unidades. Se guarda ya dividido para que nadie se olvide.

   Creado: 2026-09-19
   =========================================================================== */

USE DF_DTW;
GO

IF OBJECT_ID('dbo.DIM_INSUMO_COSTO', 'U') IS NOT NULL
    DROP TABLE dbo.DIM_INSUMO_COSTO;
GO

CREATE TABLE dbo.DIM_INSUMO_COSTO (
    BASE_ORIGEN     sysname        NOT NULL,
    ARTICULO        int            NOT NULL,
    VIGENTE_DESDE   datetime       NOT NULL,
    VIGENTE_HASTA   datetime       NOT NULL,   -- exclusivo
    DESCRIP         varchar(50)    NULL,
    TIPO            varchar(10)    NULL,
    UNID_X_BULTO    int            NULL,
    COSTO_BULTO     numeric(16,4)  NULL,
    /* Ya dividido: es el que se multiplica por el consumo en unidades.
       NULL cuando UNID_X_BULTO es 0 o NULL, para que el error se vea en vez
       de propagarse como un costo cero silencioso. */
    COSTO_UNIT      numeric(18,6)  NULL,
    IDHISTORICO     int            NOT NULL,
    FECHA_CARGA     datetime2(0)   NOT NULL CONSTRAINT DF_DIM_INSUMO_FECHA DEFAULT (SYSDATETIME()),
    CONSTRAINT PK_DIM_INSUMO_COSTO PRIMARY KEY CLUSTERED (BASE_ORIGEN, ARTICULO, VIGENTE_DESDE)
);
GO

-- El join de costeo entra por (articulo, fecha): este es el indice que lo sirve.
CREATE INDEX IX_DIM_INSUMO_RANGO
    ON dbo.DIM_INSUMO_COSTO (BASE_ORIGEN, ARTICULO, VIGENTE_DESDE, VIGENTE_HASTA)
    INCLUDE (COSTO_UNIT, COSTO_BULTO, UNID_X_BULTO, DESCRIP);
GO


IF OBJECT_ID('dbo.usp_RefrescarDimInsumoCosto', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_RefrescarDimInsumoCosto;
GO

CREATE PROCEDURE dbo.usp_RefrescarDimInsumoCosto
    @BaseOrigen sysname = 'SRV_GRIDO_ZSUR'
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = @BaseOrigen AND state = 0)
    BEGIN
        RAISERROR('usp_RefrescarDimInsumoCosto: la base "%s" no existe o no esta ONLINE.', 16, 1, @BaseOrigen);
        RETURN;
    END

    DECLARE @sql nvarchar(max) = N'
    DELETE FROM dbo.DIM_INSUMO_COSTO WHERE BASE_ORIGEN = @pBase;

    INSERT dbo.DIM_INSUMO_COSTO
        (BASE_ORIGEN, ARTICULO, VIGENTE_DESDE, VIGENTE_HASTA, DESCRIP, TIPO,
         UNID_X_BULTO, COSTO_BULTO, COSTO_UNIT, IDHISTORICO)
    SELECT
        @pBase,
        v.ARTICULO,
        v.DESDE,
        -- El intervalo llega hasta que empieza la version siguiente. La ultima
        -- queda abierta hasta 9999 para que una venta de hoy siempre matchee.
        ISNULL(LEAD(v.DESDE) OVER (PARTITION BY v.ARTICULO ORDER BY v.DESDE), ''9999-12-31''),
        v.DESCRIP, v.TIPO, v.UNID_X_BULTO, v.COSTO_BULTO,
        CASE WHEN ISNULL(v.UNID_X_BULTO, 0) > 0
             THEN v.COSTO_BULTO / v.UNID_X_BULTO END,
        v.IDHISTORICO
    FROM (
        SELECT
            h.ARTICULO,
            -- Varias versiones pueden compartir ARTFECESTADO; se queda la de
            -- mayor IDHISTORICO, que es la ultima cargada.
            DESDE = h.ARTFECESTADO,
            DESCRIP = RTRIM(h.ARTDESCRIP),
            TIPO = RTRIM(h.ARTTIPO),
            UNID_X_BULTO = h.ARTUNIDXBULTO,
            COSTO_BULTO = h.ARTCOSTO,
            IDHISTORICO = h.IDHISTORICO,
            rn = ROW_NUMBER() OVER (PARTITION BY h.ARTICULO, h.ARTFECESTADO ORDER BY h.IDHISTORICO DESC)
        FROM ' + QUOTENAME(@BaseOrigen) + N'.dbo.ARTICULOSHISTORICO h
        WHERE h.ARTFECESTADO IS NOT NULL
    ) v
    WHERE v.rn = 1;';

    EXEC sp_executesql @sql, N'@pBase sysname', @pBase = @BaseOrigen;

    /* Los articulos sin ninguna version fechada quedarian sin costo. Se les
       arma un intervalo unico abierto desde 1900 con el maestro actual, asi
       una venta vieja de un insumo nunca versionado igual coste. */
    SET @sql = N'
    INSERT dbo.DIM_INSUMO_COSTO
        (BASE_ORIGEN, ARTICULO, VIGENTE_DESDE, VIGENTE_HASTA, DESCRIP, TIPO,
         UNID_X_BULTO, COSTO_BULTO, COSTO_UNIT, IDHISTORICO)
    SELECT @pBase, a.ARTICULO, ''1900-01-01'', ''9999-12-31'',
           RTRIM(a.ARTDESCRIP), RTRIM(a.ARTTIPO), a.ARTUNIDXBULTO, a.ARTCOSTO,
           CASE WHEN ISNULL(a.ARTUNIDXBULTO,0) > 0 THEN a.ARTCOSTO / a.ARTUNIDXBULTO END,
           0
    FROM ' + QUOTENAME(@BaseOrigen) + N'.dbo.ARTICULOS a
    WHERE NOT EXISTS (SELECT 1 FROM dbo.DIM_INSUMO_COSTO d
                      WHERE d.BASE_ORIGEN = @pBase AND d.ARTICULO = a.ARTICULO);';

    EXEC sp_executesql @sql, N'@pBase sysname', @pBase = @BaseOrigen;

    SELECT
        BASE_ORIGEN,
        INTERVALOS   = COUNT(*),
        ARTICULOS    = COUNT(DISTINCT ARTICULO),
        SIN_COSTOUNIT= SUM(CASE WHEN COSTO_UNIT IS NULL THEN 1 ELSE 0 END),
        DESDE        = MIN(VIGENTE_DESDE)
    FROM dbo.DIM_INSUMO_COSTO
    WHERE BASE_ORIGEN = @BaseOrigen
    GROUP BY BASE_ORIGEN;
END
GO
