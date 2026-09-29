/* ===========================================================================
   DIM_ELASTICIDAD_CLIMA
   ---------------------------------------------------------------------------
   Como responde cada grupo de producto al clima.

   ESTO NO ES UN DATO, ES UNA FOTO DE UN CALCULO
   ---------------------------------------------
   La tabla NO se carga a mano ni se deja fija: la llena usp_CalibrarElasticidad
   leyendo toda la historia disponible, y se recalcula con la carga diaria.
   Congelarla significaria recomendar con el mundo de hace un ano: los
   productos cambian, los precios cambian y los habitos tambien. Cada fila
   guarda la ventana con la que se calculo y cuando, para que se pueda ver si
   esta fresca.

   DOS INDICES, PORQUE CUENTAN COSAS DISTINTAS
   -------------------------------------------
   IDX_PARTICIPACION: cuanto de la torta se lleva el grupo en esa condicion.
   IDX_ABSOLUTO:      cuanto vende por dia comparado con su propio promedio.

   La diferencia importa y engana: Helado x Kilo sube a 1,21 en participacion
   con frio, lo que lo hace parecer contraciclico, pero en pesos cae a 0,73.
   Sube su porcion de una torta que se achico. Para decidir que promocionar
   hay que mirar el ABSOLUTO; la participacion sirve para entender la rotacion
   del mix.

   LO QUE LA CALIBRACION DEJA VER
   ------------------------------
   Con frio cae practicamente todo. Los unicos grupos que sostienen o suben
   suman menos del 6% de la venta, asi que NO alcanzan para compensar. El
   modulo tiene que decirlo en vez de prometer un balanceo que no existe.
   =========================================================================== */

IF OBJECT_ID('dbo.DIM_ELASTICIDAD_CLIMA', 'U') IS NOT NULL
    DROP TABLE dbo.DIM_ELASTICIDAD_CLIMA;
GO

CREATE TABLE dbo.DIM_ELASTICIDAD_CLIMA (
    BASE_ORIGEN       varchar(30)  NOT NULL,
    GRUPO             varchar(40)  NOT NULL,
    CONDICION_TIPO    varchar(10)  NOT NULL,   -- TEMP | LLUVIA
    CONDICION         varchar(20)  NOT NULL,   -- frio | templado | calido | calor | llueve | seco
    ORDEN             int          NOT NULL,
    VENTA_DIA_PROM    numeric(18,2) NOT NULL,
    IDX_ABSOLUTO      numeric(8,3) NOT NULL,
    IDX_PARTICIPACION numeric(8,3) NOT NULL,
    PESO_PCT          numeric(8,3) NOT NULL,   -- peso del grupo en la venta total
    DIAS              int          NOT NULL,
    CONFIABLE         bit          NOT NULL,
    VENTANA_DESDE     date         NOT NULL,
    VENTANA_HASTA     date         NOT NULL,
    FECHA_CALIB       datetime2(0) NOT NULL CONSTRAINT DF_DEC_FECHA DEFAULT SYSDATETIME(),
    CONSTRAINT PK_DIM_ELASTICIDAD_CLIMA
        PRIMARY KEY (BASE_ORIGEN, GRUPO, CONDICION_TIPO, CONDICION)
);
GO


CREATE OR ALTER PROCEDURE dbo.usp_CalibrarElasticidad
    @BaseOrigen varchar(30) = 'SRV_GRIDO_ZSUR',
    @DesdeHist  date        = NULL,   -- por defecto, toda la historia disponible
    @MinDias    int         = 60,
    @PesoMinimo numeric(8,4) = 0.002  -- grupos por debajo del 0,2% no se calibran
AS
BEGIN
    SET NOCOUNT ON;

    IF @DesdeHist IS NULL
        SELECT @DesdeHist = MIN(FECHA_OPERATIVA) FROM dbo.TRX_HUELLA_VENTA
        WHERE BASE_ORIGEN = @BaseOrigen;

    DECLARE @hasta date = (SELECT MAX(FECHA_OPERATIVA) FROM dbo.TRX_HUELLA_VENTA
                           WHERE BASE_ORIGEN = @BaseOrigen);

    /* Venta por grupo, sucursal y jornada, con el clima de ese dia.
       Se trabaja por dia y no por linea: la pregunta es como se comporta un
       dia frio contra uno caluroso, no una linea contra otra. */
    CREATE TABLE #D (
        GRUPO varchar(40), SUCURSAL int, DIA date, VENTA numeric(18,4),
        TRAMO varchar(20), ORDEN int, LLOVIO bit
    );

    INSERT #D
    SELECT v.GRUPO, v.SUCURSAL, v.DIA, v.VENTA,
           CASE WHEN c.TMAX < 18 THEN 'frio'
                WHEN c.TMAX < 24 THEN 'templado'
                WHEN c.TMAX < 30 THEN 'calido'
                ELSE 'calor' END,
           CASE WHEN c.TMAX < 18 THEN 1 WHEN c.TMAX < 24 THEN 2
                WHEN c.TMAX < 30 THEN 3 ELSE 4 END,
           c.LLOVIO
    FROM (SELECT GRUPO = ISNULL(NULLIF(RTRIM(ART_GRUPO_DESCRIP), ''), '(Sin grupo)'),
                 SUCURSAL, DIA = FECHA_OPERATIVA, VENTA = SUM(IMPORTE)
          FROM dbo.TRX_HUELLA_VENTA
          WHERE BASE_ORIGEN = @BaseOrigen AND ES_ANULADA = 0
            AND FECHA_OPERATIVA >= @DesdeHist AND IMPORTE > 0
          GROUP BY ISNULL(NULLIF(RTRIM(ART_GRUPO_DESCRIP), ''), '(Sin grupo)'),
                   SUCURSAL, FECHA_OPERATIVA) v
    JOIN (SELECT SUCURSAL, DIA = CAST(CLIMA_KEY_HORA AS date),
                 TMAX = MAX(TEMPERATURA),
                 LLOVIO = MAX(CASE WHEN LLUVIA > 0 THEN 1 ELSE 0 END)
          FROM dbo.CLIMA_ZONA_HORA WHERE BASE_ORIGEN = @BaseOrigen
          GROUP BY SUCURSAL, CAST(CLIMA_KEY_HORA AS date)) c
      ON c.SUCURSAL = v.SUCURSAL AND c.DIA = v.DIA;

    DECLARE @ventaTotal numeric(38,4) = (SELECT SUM(VENTA) FROM #D);

    CREATE TABLE #G (GRUPO varchar(40), PROM numeric(18,4), TOTAL numeric(38,4),
                     PESO numeric(12,6), DIAS int);
    INSERT #G
    SELECT GRUPO, AVG(VENTA), SUM(VENTA), SUM(VENTA) / @ventaTotal, COUNT(*)
    FROM #D GROUP BY GRUPO;

    DELETE FROM dbo.DIM_ELASTICIDAD_CLIMA WHERE BASE_ORIGEN = @BaseOrigen;

    -- Temperatura
    INSERT dbo.DIM_ELASTICIDAD_CLIMA
        (BASE_ORIGEN, GRUPO, CONDICION_TIPO, CONDICION, ORDEN, VENTA_DIA_PROM,
         IDX_ABSOLUTO, IDX_PARTICIPACION, PESO_PCT, DIAS, CONFIABLE,
         VENTANA_DESDE, VENTANA_HASTA)
    SELECT @BaseOrigen, g.GRUPO, 'TEMP', d.TRAMO, MAX(d.ORDEN),
           CAST(AVG(d.VENTA) AS numeric(18,2)),
           CAST(AVG(d.VENTA) / NULLIF(g.PROM, 0) AS numeric(8,3)),
           CAST((SUM(d.VENTA) / NULLIF(t.VENTA_TRAMO, 0)) / NULLIF(g.PESO, 0) AS numeric(8,3)),
           CAST(100.0 * g.PESO AS numeric(8,3)),
           COUNT(*),
           CASE WHEN COUNT(*) >= @MinDias THEN 1 ELSE 0 END,
           @DesdeHist, @hasta
    FROM #D d
    JOIN #G g ON g.GRUPO = d.GRUPO
    JOIN (SELECT TRAMO, VENTA_TRAMO = SUM(VENTA) FROM #D GROUP BY TRAMO) t
      ON t.TRAMO = d.TRAMO
    WHERE g.PESO >= @PesoMinimo
    GROUP BY g.GRUPO, d.TRAMO, g.PROM, g.PESO, t.VENTA_TRAMO;

    -- Lluvia
    INSERT dbo.DIM_ELASTICIDAD_CLIMA
        (BASE_ORIGEN, GRUPO, CONDICION_TIPO, CONDICION, ORDEN, VENTA_DIA_PROM,
         IDX_ABSOLUTO, IDX_PARTICIPACION, PESO_PCT, DIAS, CONFIABLE,
         VENTANA_DESDE, VENTANA_HASTA)
    SELECT @BaseOrigen, g.GRUPO, 'LLUVIA',
           CASE WHEN d.LLOVIO = 1 THEN 'llueve' ELSE 'seco' END,
           CASE WHEN d.LLOVIO = 1 THEN 2 ELSE 1 END,
           CAST(AVG(d.VENTA) AS numeric(18,2)),
           CAST(AVG(d.VENTA) / NULLIF(g.PROM, 0) AS numeric(8,3)),
           CAST((SUM(d.VENTA) / NULLIF(t.VENTA_COND, 0)) / NULLIF(g.PESO, 0) AS numeric(8,3)),
           CAST(100.0 * g.PESO AS numeric(8,3)),
           COUNT(*),
           CASE WHEN COUNT(*) >= @MinDias THEN 1 ELSE 0 END,
           @DesdeHist, @hasta
    FROM #D d
    JOIN #G g ON g.GRUPO = d.GRUPO
    JOIN (SELECT LLOVIO, VENTA_COND = SUM(VENTA) FROM #D GROUP BY LLOVIO) t
      ON t.LLOVIO = d.LLOVIO
    WHERE g.PESO >= @PesoMinimo
    GROUP BY g.GRUPO, d.LLOVIO, g.PROM, g.PESO, t.VENTA_COND;

    DROP TABLE #D; DROP TABLE #G;

    SELECT GRUPOS = COUNT(DISTINCT GRUPO), FILAS = COUNT(*),
           VENTANA = CONCAT(MIN(VENTANA_DESDE), ' a ', MAX(VENTANA_HASTA))
    FROM dbo.DIM_ELASTICIDAD_CLIMA WHERE BASE_ORIGEN = @BaseOrigen;
END
GO

EXEC dbo.usp_CalibrarElasticidad;
GO
