/* ===========================================================================
   DF_DTW.dbo.usp_CuadreHuella  (+ tabla dbo.LOG_CUADRE_HUELLA)
   ---------------------------------------------------------------------------
   Compara la huella contra la base de origen, por jornada, sucursal, caja y
   turno, y deja en LOG_CUADRE_HUELLA cada combinacion que no coincide.

   POR QUE EXISTE
   --------------
   Escalada 26/09: la huella tenia 122 tickets y SmartFran 267. Los locales
   sincronizan tarde y la jornada se habia cargado a medias. Nadie se entero
   hasta que lo vio el cliente comparando pantallas.
   usp_CargarHuellaPendiente ahora recarga los ultimos 7 dias, pero un local
   que sincronice despues de esa ventana vuelve a dejar un agujero. Este
   cuadre es la alarma: mira mas atras que la recarga (@Dias, 30 por defecto)
   y avisa. NO corrige solo: corregir es correr usp_CargarHuellaVenta para la
   jornada que marque, y despues usp_CargarAggVentaDia con @Desde/@Hasta.

   QUE COMPARA
   -----------
   Por (jornada, sucursal, caja, turno):
     TICKETS   todas las ventas, incluidas las anuladas
     NORMALES  las ventas NORMAL
     IMPORTE   SUM(VTAIMPORTE) de las NORMAL: el total de cabecera, el mismo
               que muestra el cierre de turno de SmartFran
   La jornada se calcula con la misma regla que la carga: [D @HoraCorte,
   D+1 @HoraCorte).

   QUE SIGNIFICA UNA DIFERENCIA
   ----------------------------
   - En una jornada dentro de la ventana de recarga, recien cargada: la carga
     dejo afuera algo (una venta sin lineas de detalle, que el INNER JOIN de
     la carga descarta) o la recarga quedo RETENIDA (ver LOG_CARGA_HUELLA).
   - En una jornada mas vieja: el local sincronizo despues de la ventana.
     Hay que recargar esa jornada a mano.

   Devuelve el resumen por jornada y sucursal, y termina con error si hubo
   alguna diferencia, para que la tarea diaria lo registre.

   Creado: 2026-10-01
   =========================================================================== */

USE DF_DTW;
GO

IF OBJECT_ID('dbo.LOG_CUADRE_HUELLA', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.LOG_CUADRE_HUELLA (
        CUADRE_ID        int IDENTITY(1,1) NOT NULL,
        -- Todas las filas de una misma corrida comparten este valor.
        FECHA_CUADRE     datetime2(0)  NOT NULL,
        BASE_ORIGEN      sysname       NOT NULL,
        FECHA_OPERATIVA  date          NOT NULL,
        SUCURSAL         int           NOT NULL,
        CAJA             int           NOT NULL,
        TURNO            int           NULL,
        TICKETS_ORIGEN   int           NOT NULL,
        TICKETS_DWH      int           NOT NULL,
        NORMALES_ORIGEN  int           NOT NULL,
        NORMALES_DWH     int           NOT NULL,
        IMPORTE_ORIGEN   numeric(18,2) NOT NULL,
        IMPORTE_DWH      numeric(18,2) NOT NULL,
        CONSTRAINT PK_LOG_CUADRE_HUELLA PRIMARY KEY (CUADRE_ID)
    );
    CREATE NONCLUSTERED INDEX IX_LCH_FECHA ON dbo.LOG_CUADRE_HUELLA (FECHA_CUADRE);
    PRINT 'LOG_CUADRE_HUELLA creada.';
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_CuadreHuella
    /* Jornadas hacia atras desde ayer. Tiene que ser bastante mas que la
       ventana de recarga de la huella: lo que interesa es lo que quedo afuera. */
    @Dias       int     = 30,
    @HoraCorte  time(0) = '02:00'
AS
BEGIN
    SET NOCOUNT ON;

    IF @Dias IS NULL OR @Dias < 1
    BEGIN
        RAISERROR('usp_CuadreHuella: @Dias debe ser 1 o mas.', 16, 1);
        RETURN;
    END

    DECLARE @ayer   date = CAST(DATEADD(day, -1, SYSDATETIME()) AS date);
    DECLARE @fDesde date = DATEADD(day, 1 - @Dias, @ayer);
    DECLARE @corte  int  = DATEDIFF(minute, 0, @HoraCorte);
    DECLARE @desde  datetime = DATEADD(minute, @corte, CAST(@fDesde AS datetime)),
            @hasta  datetime = DATEADD(minute, @corte, CAST(DATEADD(day, 1, @ayer) AS datetime));
    DECLARE @ahora  datetime2(0) = SYSDATETIME();

    CREATE TABLE #O (
        BASE_ORIGEN sysname, FECHA_OPERATIVA date, SUCURSAL int, CAJA int, TURNO int,
        TICKETS int, NORMALES int, IMPORTE numeric(18,2));

    DECLARE @base sysname, @sql nvarchar(max);
    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT BASE_ORIGEN FROM dbo.CFG_BASES_ORIGEN WHERE ACTIVA = 1 ORDER BY BASE_ORIGEN;
    OPEN cur;
    FETCH NEXT FROM cur INTO @base;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        -- Misma regla de jornada que usp_CargarHuellaVenta: correr la hora de
        -- corte hacia atras y quedarse con la fecha.
        SET @sql = N'
SELECT @pBase,
       CAST(DATEADD(minute, -@pCorte, v.VTAFECHA) AS date),
       v.SUCURSAL, v.CAJA, v.TURNO,
       COUNT(*),
       SUM(CASE WHEN v.VTAESTADO = ''NORMAL'' THEN 1 ELSE 0 END),
       SUM(CASE WHEN v.VTAESTADO = ''NORMAL'' THEN v.VTAIMPORTE ELSE 0 END)
FROM ' + QUOTENAME(@base) + N'.dbo.VENTAS v
WHERE v.VTAFECHA >= @pDesde AND v.VTAFECHA < @pHasta
GROUP BY CAST(DATEADD(minute, -@pCorte, v.VTAFECHA) AS date), v.SUCURSAL, v.CAJA, v.TURNO;';

        INSERT #O
        EXEC sp_executesql @sql,
             N'@pBase sysname, @pCorte int, @pDesde datetime, @pHasta datetime',
             @pBase = @base, @pCorte = @corte, @pDesde = @desde, @pHasta = @hasta;

        FETCH NEXT FROM cur INTO @base;
    END
    CLOSE cur;
    DEALLOCATE cur;

    -- La huella tiene una fila por linea: primero se colapsa a una por ticket.
    SELECT d.BASE_ORIGEN, d.FECHA_OPERATIVA, d.SUCURSAL, d.CAJA, d.TURNO,
           TICKETS  = COUNT(*),
           NORMALES = SUM(CASE WHEN d.anulada = 0 THEN 1 ELSE 0 END),
           IMPORTE  = SUM(CASE WHEN d.anulada = 0 THEN d.importe ELSE 0 END)
    INTO #D
    FROM (SELECT h.BASE_ORIGEN, h.FECHA_OPERATIVA, h.SUCURSAL, h.CAJA,
                 TURNO   = MAX(h.TURNO),
                 anulada = MAX(CAST(h.ES_ANULADA AS int)),
                 importe = MAX(h.VTAIMPORTE)
          FROM dbo.TRX_HUELLA_VENTA h
          WHERE h.FECHA_OPERATIVA BETWEEN @fDesde AND @ayer
            AND h.BASE_ORIGEN IN (SELECT BASE_ORIGEN FROM dbo.CFG_BASES_ORIGEN WHERE ACTIVA = 1)
          GROUP BY h.BASE_ORIGEN, h.FECHA_OPERATIVA, h.SUCURSAL, h.CAJA, h.TICKET_KEY) d
    GROUP BY d.BASE_ORIGEN, d.FECHA_OPERATIVA, d.SUCURSAL, d.CAJA, d.TURNO;

    INSERT dbo.LOG_CUADRE_HUELLA
        (FECHA_CUADRE, BASE_ORIGEN, FECHA_OPERATIVA, SUCURSAL, CAJA, TURNO,
         TICKETS_ORIGEN, TICKETS_DWH, NORMALES_ORIGEN, NORMALES_DWH,
         IMPORTE_ORIGEN, IMPORTE_DWH)
    SELECT @ahora,
           ISNULL(o.BASE_ORIGEN, d.BASE_ORIGEN), ISNULL(o.FECHA_OPERATIVA, d.FECHA_OPERATIVA),
           ISNULL(o.SUCURSAL, d.SUCURSAL), ISNULL(o.CAJA, d.CAJA), ISNULL(o.TURNO, d.TURNO),
           ISNULL(o.TICKETS, 0),  ISNULL(d.TICKETS, 0),
           ISNULL(o.NORMALES, 0), ISNULL(d.NORMALES, 0),
           ISNULL(o.IMPORTE, 0),  ISNULL(d.IMPORTE, 0)
    FROM #O o
    FULL JOIN #D d
           ON  d.BASE_ORIGEN = o.BASE_ORIGEN AND d.FECHA_OPERATIVA = o.FECHA_OPERATIVA
           AND d.SUCURSAL = o.SUCURSAL AND d.CAJA = o.CAJA
           AND (d.TURNO = o.TURNO OR (d.TURNO IS NULL AND o.TURNO IS NULL))
    WHERE ISNULL(o.TICKETS, 0)  <> ISNULL(d.TICKETS, 0)
       OR ISNULL(o.NORMALES, 0) <> ISNULL(d.NORMALES, 0)
       -- VTAIMPORTE es money en el origen: se tolera el redondeo a centavos.
       OR ABS(ISNULL(o.IMPORTE, 0) - ISNULL(d.IMPORTE, 0)) > 0.05;

    DECLARE @dif int = @@ROWCOUNT;

    -- Resumen para la bitacora de la tarea.
    SELECT BASE_ORIGEN, FECHA_OPERATIVA, SUCURSAL,
           TICKETS_ORIGEN = SUM(NORMALES_ORIGEN), TICKETS_DWH = SUM(NORMALES_DWH),
           IMPORTE_ORIGEN = SUM(IMPORTE_ORIGEN), IMPORTE_DWH = SUM(IMPORTE_DWH),
           TURNOS_CON_DIFERENCIA = COUNT(*)
    FROM dbo.LOG_CUADRE_HUELLA
    WHERE FECHA_CUADRE = @ahora
    GROUP BY BASE_ORIGEN, FECHA_OPERATIVA, SUCURSAL
    ORDER BY BASE_ORIGEN, FECHA_OPERATIVA, SUCURSAL;

    IF @dif = 0
    BEGIN
        PRINT 'Cuadre OK: ' + CONVERT(varchar(10), @fDesde, 23) + ' a '
            + CONVERT(varchar(10), @ayer, 23) + ', la huella coincide con el origen.';
        RETURN;
    END

    DECLARE @txt varchar(10) = CAST(@dif AS varchar(10)),
            @ts  varchar(19) = CONVERT(varchar(19), @ahora, 120);
    RAISERROR('usp_CuadreHuella: %s turno(s) no coinciden con el origen. Ver dbo.LOG_CUADRE_HUELLA WHERE FECHA_CUADRE = ''%s''.',
              16, 1, @txt, @ts);
END
GO
