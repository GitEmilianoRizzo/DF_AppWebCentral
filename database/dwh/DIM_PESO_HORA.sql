/* ===========================================================================
   DIM_PESO_HORA
   ---------------------------------------------------------------------------
   Que porcentaje de la venta del dia ocurre en cada hora, por sucursal.

   PARA QUE SIRVE
   --------------
   Para pesar la lluvia. Llover a las 7 de la mañana y llover a las 19 no es
   lo mismo: a las 7 no hay nadie y a las 19 pasa el 9,1% de la venta del dia.
   Con este peso se puede calcular, para cada dia, QUE PORCENTAJE DE LA VENTA
   ESTUVO EXPUESTO a la lluvia, que es la variable que de verdad explica la
   caida.

   POR QUE UNA TABLA Y NO UN CALCULO AL VUELO
   ------------------------------------------
   Sacar estos pesos de TRX_HUELLA_VENTA es un recorrido completo de la huella.
   Se hace una vez por dia en la recalibracion y queda disponible para todo lo
   demas sin volver a tocar los 2 GB.

   POR SUCURSAL
   ------------
   Mayorista vende temprano y los locales de mostrador a la tarde. Un peso
   unico pondria la lluvia de la mañana como irrelevante para todos, y para
   Mayorista es justo al reves.
   =========================================================================== */

IF OBJECT_ID('dbo.DIM_PESO_HORA', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.DIM_PESO_HORA (
        BASE_ORIGEN  varchar(30)  NOT NULL,
        SUCURSAL     int          NOT NULL,
        HORA         tinyint      NOT NULL,
        PESO         numeric(10,6) NOT NULL,   -- fraccion, suma 1 por sucursal
        VENTA_HIST   numeric(18,2) NULL,
        FECHA_CALIB  datetime2(0) NOT NULL CONSTRAINT DF_DPH_CALIB DEFAULT SYSDATETIME(),
        CONSTRAINT PK_DIM_PESO_HORA PRIMARY KEY (BASE_ORIGEN, SUCURSAL, HORA)
    );
    PRINT 'DIM_PESO_HORA creada.';
END
ELSE
    PRINT 'DIM_PESO_HORA ya existia.';
GO


CREATE OR ALTER PROCEDURE dbo.usp_CalibrarPesoHora
    @DesdeHist  date        = '2024-01-01',
    @BaseOrigen varchar(30) = 'SRV_GRIDO_ZSUR'
AS
BEGIN
    SET NOCOUNT ON;

    CREATE TABLE #p (SUCURSAL int, HORA tinyint, VENTA numeric(18,2), PESO numeric(10,6));

    INSERT #p (SUCURSAL, HORA, VENTA, PESO)
    SELECT h.SUCURSAL, h.HORA, SUM(h.IMPORTE),
           CAST(SUM(h.IMPORTE) * 1.0 / SUM(SUM(h.IMPORTE)) OVER (PARTITION BY h.SUCURSAL) AS numeric(10,6))
    FROM dbo.TRX_HUELLA_VENTA h
    WHERE h.BASE_ORIGEN = @BaseOrigen
      AND h.ES_ANULADA = 0
      AND h.FECHA_OPERATIVA >= @DesdeHist
    GROUP BY h.SUCURSAL, h.HORA
    HAVING SUM(h.IMPORTE) > 0;

    DELETE FROM dbo.DIM_PESO_HORA WHERE BASE_ORIGEN = @BaseOrigen;

    INSERT dbo.DIM_PESO_HORA (BASE_ORIGEN, SUCURSAL, HORA, PESO, VENTA_HIST)
    SELECT @BaseOrigen, SUCURSAL, HORA, PESO, VENTA FROM #p;

    SELECT Sucursales = COUNT(DISTINCT SUCURSAL), Filas = COUNT(*),
           HoraPico = (SELECT TOP 1 HORA FROM #p GROUP BY HORA ORDER BY SUM(VENTA) DESC)
    FROM #p;

    DROP TABLE #p;
END
GO

PRINT '';
PRINT 'Peso por hora listo.';
GO
