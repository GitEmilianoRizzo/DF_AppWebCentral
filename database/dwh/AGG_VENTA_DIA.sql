/* ===========================================================================
   AGG_VENTA_DIA
   ---------------------------------------------------------------------------
   Una fila por sucursal y jornada, con los totales del dia y el clima que hubo.

   POR QUE EXISTE
   --------------
   Medir "esperado contra real" exige, para cada dia, comparar contra el
   promedio historico de los dias parecidos. Hacer eso contra TRX_HUELLA_VENTA
   significa recorrer 2 GB en cada consulta, y este SQL Express topea el buffer
   pool en 1.410 MB: la tabla no entra en cache ni con el servidor vacio. Fue
   exactamente la causa de la consulta de 852 segundos.

   Agregado por dia y sucursal, todo el historico son unos pocos miles de
   filas. Ahi si entra en memoria y la medicion es instantanea.

   NO ES UN CACHE, ES UNA TABLA DERIVADA
   -------------------------------------
   Se puede borrar y reconstruir entera desde la huella sin perder nada. Si un
   dia se recarga la huella de una jornada, hay que recargar esta tambien: lo
   hace la tarea diaria, y a mano se puede con @Desde/@Hasta.

   EL CLIMA VA CONGELADO ACA
   -------------------------
   Y por DIA CALENDARIO (CLIMA_KEY_DIA), no por las horas que el local estuvo
   abierto. Es la misma definicion que usa usp_PronosticoDiario para el clima
   que VIENE: si se calibrara con una definicion y se pronosticara con otra, el
   modelo estaria comparando dos cosas distintas.

   La venta, en cambio, va por JORNADA COMERCIAL (FECHA_OPERATIVA), que es como
   el negocio cuenta un dia. La jornada del dia D va de las 02:00 de D a las
   02:00 de D+1, asi que solapa un 92% con el dia calendario D y las horas que
   definen la maxima caen todas adentro. La diferencia es despreciable y es a
   proposito: cambiar el clima a grano de jornada obligaria a redefinir tambien
   el pronostico.
   =========================================================================== */

IF OBJECT_ID('dbo.AGG_VENTA_DIA', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.AGG_VENTA_DIA (
        BASE_ORIGEN       varchar(30)  NOT NULL,
        SUCURSAL          int          NOT NULL,
        FECHA             date         NOT NULL,   -- jornada comercial
        DIA_SEMANA        tinyint      NOT NULL,   -- 1 = lunes .. 7 = domingo
        -- medidas del dia
        TICKETS           int          NOT NULL,
        IMPORTE           numeric(18,2) NOT NULL,
        UNIDADES          numeric(18,4) NULL,
        KILOS             numeric(18,4) NULL,
        COSTO             numeric(18,2) NULL,
        UTILIDAD          numeric(18,2) NULL,
        CONTRIB_MARGINAL  numeric(18,2) NULL,
        DESCUENTOS        numeric(18,2) NULL,
        -- el clima que hubo, congelado
        TMAX              numeric(6,2) NULL,
        TMIN              numeric(6,2) NULL,
        TMEDIA            numeric(6,2) NULL,
        /* Franja de dos grados de la maxima: es la dimension con la que se
           agrupa el historico. Se guarda calculada para no repetir el FLOOR en
           cada consulta y, sobre todo, para que sea imposible que dos lugares
           del codigo la calculen distinto. */
        FRANJA_TMAX       int          NULL,
        /* Maxima del dia ANTERIOR. Va guardada y no calculada con un LAG
           porque un LAG sobre esta tabla devuelve el dia anterior QUE ABRIO, y
           si el local estuvo cerrado eso no es "ayer": el salto termico se
           mediria contra otra cosa. */
        TMAX_AYER         numeric(6,2) NULL,
        LLOVIO            bit          NULL,
        HORAS_LLUVIA      tinyint      NULL,
        LLUVIA_MM         numeric(8,2) NULL,
        /* Que porcentaje de la venta tipica del dia cayo en horas con lluvia.
           Es LA variable de lluvia: el bit LLOVIO mete en la misma bolsa una
           garua de las 7 de la mañana (indice 1,03) con un temporal de las 19
           (indice 0,71). Medido sobre 2024-2026, el bit reduce el error del
           modelo en 0,11 puntos y esta en 0,44: cuatro veces mas. */
        EXPOS_LLUVIA      numeric(6,2) NULL,
        /* El tramo con el que agrupa el modelo. Se guarda calculado para que
           sea imposible que dos lugares del codigo lo corten distinto.
           0 nada | 1 hasta 10% | 2 10-25% | 3 25-50% | 4 mas de 50% */
        TRAMO_LLUVIA      tinyint      NULL,
        CALCULADO_EL      datetime2(0) NOT NULL CONSTRAINT DF_AVD_CALC DEFAULT SYSDATETIME(),
        CONSTRAINT PK_AGG_VENTA_DIA PRIMARY KEY (BASE_ORIGEN, SUCURSAL, FECHA)
    );

    /* Para el promedio historico: se busca por (sucursal, dia de semana,
       franja, llovio). El orden sigue el de los niveles de retroceso del
       modelo, del mas preciso al menos. */
    CREATE NONCLUSTERED INDEX IX_AVD_MODELO
        ON dbo.AGG_VENTA_DIA (BASE_ORIGEN, SUCURSAL, DIA_SEMANA, FRANJA_TMAX, LLOVIO)
        INCLUDE (FECHA, IMPORTE, KILOS, UTILIDAD, CONTRIB_MARGINAL, TICKETS);

    PRINT 'AGG_VENTA_DIA creada.';
END
ELSE
    PRINT 'AGG_VENTA_DIA ya existia.';
GO

IF COL_LENGTH('dbo.AGG_VENTA_DIA', 'TMAX_AYER') IS NULL
BEGIN
    ALTER TABLE dbo.AGG_VENTA_DIA ADD TMAX_AYER numeric(6,2) NULL;
    PRINT 'AGG_VENTA_DIA: columna TMAX_AYER agregada. Hay que recargar con @Rehacer = 1.';
END
GO

IF COL_LENGTH('dbo.AGG_VENTA_DIA', 'EXPOS_LLUVIA') IS NULL
BEGIN
    ALTER TABLE dbo.AGG_VENTA_DIA ADD EXPOS_LLUVIA numeric(6,2) NULL, TRAMO_LLUVIA tinyint NULL;
    PRINT 'AGG_VENTA_DIA: columnas de exposicion a la lluvia agregadas. Hay que recargar con @Rehacer = 1.';
END
GO

/* El indice del modelo agrupa por tramo de lluvia, no por el bit. */
IF EXISTS (SELECT 1 FROM sys.indexes
           WHERE object_id = OBJECT_ID('dbo.AGG_VENTA_DIA') AND name = 'IX_AVD_MODELO')
   AND NOT EXISTS (SELECT 1 FROM sys.index_columns ic
                   JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                   WHERE ic.object_id = OBJECT_ID('dbo.AGG_VENTA_DIA')
                     AND ic.index_id = INDEXPROPERTY(OBJECT_ID('dbo.AGG_VENTA_DIA'), 'IX_AVD_MODELO', 'IndexID')
                     AND c.name = 'TRAMO_LLUVIA')
BEGIN
    DROP INDEX IX_AVD_MODELO ON dbo.AGG_VENTA_DIA;
    CREATE NONCLUSTERED INDEX IX_AVD_MODELO
        ON dbo.AGG_VENTA_DIA (BASE_ORIGEN, SUCURSAL, DIA_SEMANA, FRANJA_TMAX, TRAMO_LLUVIA)
        INCLUDE (FECHA, IMPORTE, KILOS, UTILIDAD, CONTRIB_MARGINAL, TICKETS);
    PRINT 'AGG_VENTA_DIA: IX_AVD_MODELO rehecho sobre TRAMO_LLUVIA.';
END
GO


/* ---------------------------------------------------------------------------
   Carga o recarga el agregado.

   Sin parametros hace lo incremental: desde el dia siguiente al ultimo que
   tiene hasta la ultima jornada que hay en la huella. Es lo que corre la tarea
   diaria.

   Con @Desde/@Hasta recarga ese rango pisando lo que hubiera. Es lo que hay
   que usar cuando se recargo la huella de una jornada vieja.

   @Rehacer = 1 lo reconstruye todo desde cero.
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_CargarAggVentaDia
    @Desde      date        = NULL,
    @Hasta      date        = NULL,
    @Rehacer    bit         = 0,
    @BaseOrigen varchar(30) = 'SRV_GRIDO_ZSUR'
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @minHuella date, @maxHuella date, @ultimo date;

    SELECT @minHuella = MIN(FECHA_OPERATIVA), @maxHuella = MAX(FECHA_OPERATIVA)
    FROM dbo.TRX_HUELLA_VENTA WHERE BASE_ORIGEN = @BaseOrigen;

    IF @maxHuella IS NULL
    BEGIN
        PRINT 'La huella no tiene datos para ' + @BaseOrigen + ': no hay nada que agregar.';
        RETURN;
    END

    IF @Rehacer = 1
    BEGIN
        DELETE FROM dbo.AGG_VENTA_DIA WHERE BASE_ORIGEN = @BaseOrigen;
        SET @Desde = @minHuella;
        SET @Hasta = @maxHuella;
    END
    ELSE IF @Desde IS NULL
    BEGIN
        SELECT @ultimo = MAX(FECHA) FROM dbo.AGG_VENTA_DIA WHERE BASE_ORIGEN = @BaseOrigen;
        /* La ultima jornada agregada se RECARGA en vez de saltearse: cuando la
           tarea corre mientras esa jornada todavia se estaba completando, el
           total guardado quedo corto. Recargarla cuesta un dia de lectura. */
        SET @Desde = ISNULL(@ultimo, @minHuella);
        SET @Hasta = @maxHuella;
    END

    IF @Hasta IS NULL SET @Hasta = @maxHuella;

    IF @Hasta < @Desde
    BEGIN
        PRINT 'Nada que agregar: el agregado ya esta al dia.';
        RETURN;
    END

    PRINT 'Agregando de ' + CONVERT(varchar(10), @Desde, 120)
        + ' a ' + CONVERT(varchar(10), @Hasta, 120) + '...';

    -- 1) La venta del dia, por sucursal y jornada -----------------------------
    CREATE TABLE #V (
        SUCURSAL         int NOT NULL,
        FECHA            date NOT NULL,
        TICKETS          int NOT NULL,
        IMPORTE          numeric(18,2) NOT NULL,
        UNIDADES         numeric(18,4) NULL,
        KILOS            numeric(18,4) NULL,
        COSTO            numeric(18,2) NULL,
        UTILIDAD         numeric(18,2) NULL,
        CONTRIB_MARGINAL numeric(18,2) NULL,
        DESCUENTOS       numeric(18,2) NULL,
        PRIMARY KEY (SUCURSAL, FECHA)
    );

    INSERT #V
    SELECT h.SUCURSAL,
           h.FECHA_OPERATIVA,
           /* Tickets DISTINTOS, no lineas: es la unidad con la que se cuenta
              un cliente. Sumar lineas contaria varias veces al mismo. */
           COUNT(DISTINCT h.TICKET_KEY),
           SUM(h.IMPORTE),
           SUM(h.CANTIDAD),
           SUM(h.KILOS),
           SUM(h.COSTO),
           SUM(h.UTILIDAD),
           SUM(h.CONTRIB_MARGINAL),
           SUM(h.DESCUENTOS)
    FROM dbo.TRX_HUELLA_VENTA h
    WHERE h.BASE_ORIGEN = @BaseOrigen
      AND h.FECHA_OPERATIVA BETWEEN @Desde AND @Hasta
      AND h.ES_ANULADA = 0
    GROUP BY h.SUCURSAL, h.FECHA_OPERATIVA;

    -- 2) El clima de cada dia calendario, por sucursal ------------------------
    CREATE TABLE #C (
        SUCURSAL     int NOT NULL,
        DIA          date NOT NULL,
        TMAX         numeric(6,2) NULL,
        TMIN         numeric(6,2) NULL,
        TMEDIA       numeric(6,2) NULL,
        LLOVIO       bit NULL,
        HORAS_LLUVIA tinyint NULL,
        LLUVIA_MM    numeric(8,2) NULL,
        EXPOS_LLUVIA numeric(6,2) NULL,
        PRIMARY KEY (SUCURSAL, DIA)
    );

    /* La exposicion se pondera con DIM_PESO_HORA. Si por lo que sea todavia no
       esta calibrada, la lluvia queda sin ponderar (NULL) en vez de contarse
       como si fuera pareja a toda hora: un dato ausente es mejor que uno
       inventado, y el modelo tiene con que retroceder.

       OJO AL ORDEN: en la tarea diaria esta carga corre ANTES de la
       recalibracion, asi que usa los pesos de la corrida anterior. Es a
       proposito y no importa: los pesos salen de dos años y medio de historia
       y no se mueven de un dia para el otro. Al reves seria peor, porque
       usp_CalibrarImpactoLluvia lee esta misma tabla y habria que elegir cual
       de las dos queda vieja. */
    INSERT #C
    SELECT c.SUCURSAL, c.CLIMA_KEY_DIA,
           MAX(c.TEMPERATURA), MIN(c.TEMPERATURA),
           CAST(AVG(c.TEMPERATURA) AS numeric(6,2)),
           MAX(CASE WHEN c.LLUVIA > 0 THEN 1 ELSE 0 END),
           SUM(CASE WHEN c.LLUVIA > 0 THEN 1 ELSE 0 END),
           CAST(SUM(ISNULL(c.PRECIPITACION, 0)) AS numeric(8,2)),
           CASE WHEN COUNT(p.PESO) = 0 THEN NULL
                ELSE CAST(SUM(CASE WHEN c.LLUVIA > 0 THEN ISNULL(p.PESO, 0) ELSE 0 END) * 100
                          AS numeric(6,2)) END
    FROM dbo.CLIMA_ZONA_HORA c
    LEFT JOIN dbo.DIM_PESO_HORA p
           ON p.BASE_ORIGEN = c.BASE_ORIGEN AND p.SUCURSAL = c.SUCURSAL AND p.HORA = c.HORA
    WHERE c.BASE_ORIGEN = @BaseOrigen
      -- Un dia mas atras: hace falta la maxima de ayer del primer dia.
      AND c.CLIMA_KEY_DIA BETWEEN DATEADD(day, -1, @Desde) AND @Hasta
    GROUP BY c.SUCURSAL, c.CLIMA_KEY_DIA;

    -- 3) Se junta y se graba --------------------------------------------------
    MERGE dbo.AGG_VENTA_DIA AS d
    USING (
        SELECT v.SUCURSAL, v.FECHA,
               DIA_SEMANA = CAST((DATEDIFF(day, '1900-01-01', v.FECHA) % 7) + 1 AS tinyint),
               v.TICKETS, v.IMPORTE, v.UNIDADES, v.KILOS, v.COSTO, v.UTILIDAD,
               v.CONTRIB_MARGINAL, v.DESCUENTOS,
               c.TMAX, c.TMIN, c.TMEDIA,
               FRANJA_TMAX = CASE WHEN c.TMAX IS NULL THEN NULL
                                  ELSE CAST(FLOOR(c.TMAX / 2) * 2 AS int) END,
               TMAX_AYER = ca.TMAX,
               c.LLOVIO, c.HORAS_LLUVIA, c.LLUVIA_MM,
               c.EXPOS_LLUVIA,
               /* Los cortes salen de la medicion sobre 2024-2026: el indice va
                  1,06 / 1,03 / 0,93 / 0,83 / 0,71. El primer tramo casi no
                  mueve la aguja y el ultimo se lleva un tercio del dia. */
               TRAMO_LLUVIA = CASE
                   WHEN c.EXPOS_LLUVIA IS NULL THEN NULL
                   WHEN c.EXPOS_LLUVIA = 0  THEN 0
                   WHEN c.EXPOS_LLUVIA < 10 THEN 1
                   WHEN c.EXPOS_LLUVIA < 25 THEN 2
                   WHEN c.EXPOS_LLUVIA < 50 THEN 3
                   ELSE 4 END
        FROM #V v
        LEFT JOIN #C c  ON c.SUCURSAL  = v.SUCURSAL AND c.DIA  = v.FECHA
        -- El dia calendario anterior, de verdad: por eso #C carga un dia mas atras.
        LEFT JOIN #C ca ON ca.SUCURSAL = v.SUCURSAL AND ca.DIA = DATEADD(day, -1, v.FECHA)
    ) AS o
        ON  d.BASE_ORIGEN = @BaseOrigen
        AND d.SUCURSAL = o.SUCURSAL
        AND d.FECHA = o.FECHA
    WHEN MATCHED THEN UPDATE SET
        d.DIA_SEMANA = o.DIA_SEMANA, d.TICKETS = o.TICKETS, d.IMPORTE = o.IMPORTE,
        d.UNIDADES = o.UNIDADES, d.KILOS = o.KILOS, d.COSTO = o.COSTO,
        d.UTILIDAD = o.UTILIDAD, d.CONTRIB_MARGINAL = o.CONTRIB_MARGINAL,
        d.DESCUENTOS = o.DESCUENTOS, d.TMAX = o.TMAX, d.TMIN = o.TMIN,
        d.TMEDIA = o.TMEDIA, d.FRANJA_TMAX = o.FRANJA_TMAX,
        d.TMAX_AYER = o.TMAX_AYER, d.LLOVIO = o.LLOVIO,
        d.HORAS_LLUVIA = o.HORAS_LLUVIA, d.LLUVIA_MM = o.LLUVIA_MM,
        d.EXPOS_LLUVIA = o.EXPOS_LLUVIA, d.TRAMO_LLUVIA = o.TRAMO_LLUVIA,
        d.CALCULADO_EL = SYSDATETIME()
    WHEN NOT MATCHED BY TARGET THEN INSERT
        (BASE_ORIGEN, SUCURSAL, FECHA, DIA_SEMANA, TICKETS, IMPORTE, UNIDADES,
         KILOS, COSTO, UTILIDAD, CONTRIB_MARGINAL, DESCUENTOS, TMAX, TMIN,
         TMEDIA, FRANJA_TMAX, TMAX_AYER, LLOVIO, HORAS_LLUVIA, LLUVIA_MM,
         EXPOS_LLUVIA, TRAMO_LLUVIA)
        VALUES
        (@BaseOrigen, o.SUCURSAL, o.FECHA, o.DIA_SEMANA, o.TICKETS, o.IMPORTE,
         o.UNIDADES, o.KILOS, o.COSTO, o.UTILIDAD, o.CONTRIB_MARGINAL,
         o.DESCUENTOS, o.TMAX, o.TMIN, o.TMEDIA, o.FRANJA_TMAX, o.TMAX_AYER,
         o.LLOVIO, o.HORAS_LLUVIA, o.LLUVIA_MM, o.EXPOS_LLUVIA, o.TRAMO_LLUVIA);

    DECLARE @filas int = @@ROWCOUNT;

    DROP TABLE #V;
    DROP TABLE #C;

    PRINT CAST(@filas AS varchar(10)) + ' dia(s)-sucursal agregados.';

    SELECT Dias = @filas,
           Desde = @Desde, Hasta = @Hasta,
           TotalEnTabla = (SELECT COUNT(*) FROM dbo.AGG_VENTA_DIA WHERE BASE_ORIGEN = @BaseOrigen),
           SinClima = (SELECT COUNT(*) FROM dbo.AGG_VENTA_DIA
                       WHERE BASE_ORIGEN = @BaseOrigen AND TMAX IS NULL);
END
GO

PRINT '';
PRINT 'Agregado diario listo.';
GO
