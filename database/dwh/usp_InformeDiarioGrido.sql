/* ===========================================================================
   DF_DTW.dbo.usp_InformeDiarioGrido
   ---------------------------------------------------------------------------
   Los datos del "Informe Diario GRIDO" (el Excel que sale por mail todos los
   dias a las 13:00) para un rango de jornadas, listos para dibujar.

   Reproduce exactamente las metricas que arma informe_grido.py, pero leyendo
   de TRX_HUELLA_VENTA en vez de ir a la base productiva. La unica excepcion
   son los socios nuevos, que salen de TARJETAS porque no estan en la huella.

   GRANO
   -----
   Una fila por (jornada, sucursal, turno, caja, cajero), igual que el Excel.
   Elegir un solo dia devuelve exactamente las mismas filas que ese Excel; un
   rango simplemente devuelve mas. Los subtotales por sucursal y el total los
   arma el consumidor.

   DETALLES QUE PARECEN CAPRICHOS Y NO LO SON
   ------------------------------------------
   - VENTAS sale del importe de CABECERA del ticket (IMPORTE_TICKET), no de la
     suma de las lineas. Es lo que hace el informe, y las dos cosas no dan
     igual: ver la nota de PROMO=2 en TRX_HUELLA_VENTA.
   - SOCIOS se le imputa SOLO al primer turno de cada cajero en la jornada.
     TARJETAS no permite saber en que turno se activo cada tarjeta, asi que el
     informe las carga todas al primer turno. Repetirlo en cada turno duplicaria
     el total.
   - PROMOS va en cero: el informe todavia no lo calcula, la columna esta
     reservada.

   Creado: 2026-09-16
   =========================================================================== */

USE DF_DTW;
GO

IF OBJECT_ID('dbo.usp_InformeDiarioGrido', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_InformeDiarioGrido;
GO

CREATE PROCEDURE dbo.usp_InformeDiarioGrido
    @FechaDesde   date,
    @FechaHasta   date,
    @BaseOrigen   sysname      = 'SRV_GRIDO_ZSUR',
    /* La sucursal 4 es Mayorista y el informe diario no la muestra. */
    @SucursalesExcluir varchar(100) = '4'
AS
BEGIN
    SET NOCOUNT ON;

    IF @FechaDesde IS NULL OR @FechaHasta IS NULL
    BEGIN
        RAISERROR('usp_InformeDiarioGrido: @FechaDesde y @FechaHasta son obligatorios.', 16, 1);
        RETURN;
    END
    IF @FechaDesde > @FechaHasta
    BEGIN
        RAISERROR('usp_InformeDiarioGrido: @FechaDesde no puede ser posterior a @FechaHasta.', 16, 1);
        RETURN;
    END
    IF @SucursalesExcluir LIKE '%[^0-9, ]%'
    BEGIN
        RAISERROR('usp_InformeDiarioGrido: @SucursalesExcluir solo acepta enteros separados por coma.', 16, 1);
        RETURN;
    END
    IF LTRIM(RTRIM(ISNULL(@SucursalesExcluir, ''))) IN ('', ',') SET @SucursalesExcluir = NULL;

    DECLARE @excluir TABLE (SUCURSAL int PRIMARY KEY);
    IF @SucursalesExcluir IS NOT NULL
        INSERT @excluir
        SELECT DISTINCT CAST(LTRIM(RTRIM(value)) AS int)
        FROM STRING_SPLIT(@SucursalesExcluir, ',')
        WHERE LTRIM(RTRIM(value)) <> '';

    -- =======================================================================
    -- 1) Ticket a ticket: el importe de venta sale de la cabecera, no de las
    --    lineas, asi que primero se colapsa la huella a un renglon por ticket.
    -- =======================================================================
    CREATE TABLE #TK (
        FECHA_OPERATIVA date, SUCURSAL int, SUCURSAL_DESCRIP varchar(30),
        TURNO int, CAJA int, CAJERO varchar(20),
        TICKET_KEY varchar(90), IMPORTE numeric(16,4),
        ES_ANULADA bit, ES_CLUB bit, SOBREVENTA varchar(10),
        PRIMERA datetime, ULTIMA datetime, KILOS numeric(28,8)
    );

    INSERT #TK
    SELECT h.FECHA_OPERATIVA, h.SUCURSAL, h.SUCURSAL_DESCRIP,
           h.TURNO, h.CAJA, h.USULOGIN, h.TICKET_KEY,
           MAX(h.VTAIMPORTE),
           MAX(CAST(h.ES_ANULADA AS int)),
           MAX(CAST(h.ES_CLUB_GRIDO AS int)),
           MAX(h.SOBREVENTA),
           MIN(h.FECHA_HORA), MAX(h.FECHA_HORA),
           SUM(h.KILOS)
    FROM dbo.TRX_HUELLA_VENTA h
    WHERE h.BASE_ORIGEN = @BaseOrigen
      AND h.FECHA_OPERATIVA BETWEEN @FechaDesde AND @FechaHasta
      AND NOT EXISTS (SELECT 1 FROM @excluir e WHERE e.SUCURSAL = h.SUCURSAL)
    GROUP BY h.FECHA_OPERATIVA, h.SUCURSAL, h.SUCURSAL_DESCRIP,
             h.TURNO, h.CAJA, h.USULOGIN, h.TICKET_KEY;

    -- =======================================================================
    -- 2) Socios nuevos. No estan en la huella: salen de TARJETAS de la base de
    --    origen. OPERACION 'N' es alta en salon y 'W' alta por web.
    --    Se cuentan por jornada y cajero, y despues se imputan al primer turno.
    -- =======================================================================
    CREATE TABLE #SOC (FECHA_OPERATIVA date, SUCURSAL int, CAJERO varchar(20), SOCIOS int);

    /* La jornada D va de D 02:00 a D+1 02:00, asi que restarle 2 horas a
       TARFECHA y quedarse con la fecha YA da la jornada. No lleva "+1 dia":
       esa era la convencion vieja del informe, corregida el 07/09/2026 en
       rango_dia_operativo(). Con el +1 los socios caian en la jornada
       siguiente y la columna daba todo cero. */
    DECLARE @sql nvarchar(max) = N'
    INSERT #SOC
    SELECT
        CAST(DATEADD(hour, -2, t.TARFECHA) AS date),
        t.SUCURSAL, RTRIM(t.USULOGIN), COUNT(*)
    FROM ' + QUOTENAME(@BaseOrigen) + N'.dbo.TARJETAS t
    WHERE RTRIM(t.OPERACION) IN (''N'', ''W'')
      AND t.TARFECHA >= @pDesde AND t.TARFECHA < @pHasta
    GROUP BY CAST(DATEADD(hour, -2, t.TARFECHA) AS date),
             t.SUCURSAL, RTRIM(t.USULOGIN);';

    -- La jornada va de 02:00 a 02:00, asi que el rango real de TARFECHA
    -- arranca a las 02:00 del primer dia y termina a las 02:00 del siguiente
    -- al ultimo.
    DECLARE @d datetime = DATEADD(hour, 2, CAST(@FechaDesde AS datetime)),
            @h datetime = DATEADD(hour, 2, CAST(DATEADD(day, 1, @FechaHasta) AS datetime));

    EXEC sp_executesql @sql, N'@pDesde datetime, @pHasta datetime', @pDesde = @d, @pHasta = @h;

    -- =======================================================================
    -- 3) Una fila por turno de cajero
    -- =======================================================================
    ;WITH BASE AS (
        SELECT
            FECHA_OPERATIVA, SUCURSAL, SUCURSAL_DESCRIP, TURNO, CAJA, CAJERO,
            VENTAS        = SUM(CASE WHEN ES_ANULADA = 0 THEN IMPORTE ELSE 0 END),
            TICKETS       = SUM(CASE WHEN ES_ANULADA = 0 THEN 1 ELSE 0 END),
            ANULADAS      = SUM(CASE WHEN ES_ANULADA = 1 THEN 1 ELSE 0 END),
            VENTAS_CLUB   = SUM(CASE WHEN ES_ANULADA = 0 AND ES_CLUB = 1 THEN IMPORTE ELSE 0 END),
            SV_ACEPTADAS  = SUM(CASE WHEN ES_ANULADA = 0 AND SOBREVENTA = 'ACEPTADA'  THEN 1 ELSE 0 END),
            SV_RECHAZADAS = SUM(CASE WHEN ES_ANULADA = 0 AND SOBREVENTA = 'RECHAZADA' THEN 1 ELSE 0 END),
            KILOS         = SUM(KILOS),
            PRIMERA       = MIN(CASE WHEN ES_ANULADA = 0 THEN PRIMERA END),
            ULTIMA        = MAX(CASE WHEN ES_ANULADA = 0 THEN ULTIMA END)
        FROM #TK
        GROUP BY FECHA_OPERATIVA, SUCURSAL, SUCURSAL_DESCRIP, TURNO, CAJA, CAJERO
    ),
    -- El primer turno de cada cajero en la jornada, para imputarle los socios.
    PRIMERO AS (
        SELECT FECHA_OPERATIVA, SUCURSAL, CAJERO, TURNO,
               rn = ROW_NUMBER() OVER (PARTITION BY FECHA_OPERATIVA, SUCURSAL, CAJERO
                                       ORDER BY ISNULL(PRIMERA, '9999-12-31'), TURNO)
        FROM BASE
    )
    /* Los alias van en PascalCase y NO en MAYUSCULA_CON_GUIONES a proposito.
       Dapper mapea columna a propiedad por nombre y no ignora los guiones
       bajos: con FECHA_OPERATIVA la propiedad FechaOperativa quedaba en su
       valor por defecto y las fechas salian como 0001-01-01. Lo mismo pasaba
       con SvActivadas, SvAceptadas, VentasClub, DifCaja, SucursalRotulo y
       OrdenSucursal. Se resuelve aca y no con
       DefaultTypeMap.MatchNamesWithUnderscores para no cambiarle el
       comportamiento global a las demas consultas de la app. */
    SELECT
        FechaOperativa  = b.FECHA_OPERATIVA,
        Sucursal        = b.SUCURSAL,
        SucursalDescrip = RTRIM(b.SUCURSAL_DESCRIP),
        -- El informe rotula la sucursal 1 como "Lanus Oeste"
        SucursalRotulo  = CASE b.SUCURSAL WHEN 1 THEN 'Lanus Oeste' ELSE RTRIM(b.SUCURSAL_DESCRIP) END,
        -- Orden del informe: Fiorito, Escalada, Lanus
        OrdenSucursal   = CASE b.SUCURSAL WHEN 3 THEN 1 WHEN 2 THEN 2 WHEN 1 THEN 3 ELSE 9 END,
        Turno           = b.TURNO,
        Caja            = b.CAJA,
        -- El Excel lo muestra capitalizado
        Cajero  = UPPER(LEFT(b.CAJERO,1)) + LOWER(SUBSTRING(b.CAJERO,2,19)),
        Horario = CASE WHEN b.PRIMERA IS NULL THEN ''
                       ELSE CONVERT(varchar(5), b.PRIMERA, 108) + ' a ' + CONVERT(varchar(5), b.ULTIMA, 108) END,
        Horas   = CAST(ROUND(ISNULL(DATEDIFF(second, b.PRIMERA, b.ULTIMA), 0) / 3600.0, 1) AS numeric(6,1)),
        Kilos   = CAST(ROUND(b.KILOS, 1) AS numeric(12,1)),
        Ventas  = b.VENTAS,
        Tickets = b.TICKETS,
        SvActivadas = b.SV_ACEPTADAS + b.SV_RECHAZADAS,
        SvAceptadas = b.SV_ACEPTADAS,
        Promos  = CAST(0 AS numeric(16,4)),   -- reservado: el informe no lo calcula
        Socios  = CASE WHEN p.rn = 1 THEN ISNULL(s.SOCIOS, 0) ELSE 0 END,
        VentasClub = b.VENTAS_CLUB,
        Anuladas   = b.ANULADAS,
        DifCaja    = ISNULL(t.TURDIFERENCIA, 0)
    FROM BASE b
    JOIN PRIMERO p
      ON  p.FECHA_OPERATIVA = b.FECHA_OPERATIVA AND p.SUCURSAL = b.SUCURSAL
      AND p.CAJERO = b.CAJERO AND p.TURNO = b.TURNO
    LEFT JOIN #SOC s
      ON  s.FECHA_OPERATIVA = b.FECHA_OPERATIVA AND s.SUCURSAL = b.SUCURSAL
      AND s.CAJERO = b.CAJERO
    -- La diferencia de caja es del TURNO, no del cajero: se toma una sola vez.
    OUTER APPLY (
        SELECT TOP 1 h2.TURNO_DIFERENCIA AS TURDIFERENCIA
        FROM dbo.TRX_HUELLA_VENTA h2
        WHERE h2.BASE_ORIGEN = @BaseOrigen AND h2.FECHA_OPERATIVA = b.FECHA_OPERATIVA
          AND h2.SUCURSAL = b.SUCURSAL AND h2.TURNO = b.TURNO AND h2.CAJA = b.CAJA
    ) t
    ORDER BY b.FECHA_OPERATIVA,
             CASE b.SUCURSAL WHEN 3 THEN 1 WHEN 2 THEN 2 WHEN 1 THEN 3 ELSE 9 END,
             b.TURNO, b.CAJA;
END
GO
