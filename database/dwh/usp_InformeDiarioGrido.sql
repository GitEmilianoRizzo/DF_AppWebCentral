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
   - PROMOS es la venta de las lineas que forman parte de una PROMOCION
     (LINEA_ES_PROMOCION), con el mismo criterio que Estadistica de Ventas.
     No incluye sobreventa (tiene sus columnas) ni canjes de puntos. Sale de
     las lineas, a precio de lista, y no de la cabecera: la cabecera es del
     ticket entero y no se puede partir por linea.
   - KILOS_CLUB acompaña a VENTAS_CLUB: el %VCG se mide sobre kilos, no
     sobre pesos (pedido de Damian del 01/10/2026). 100 kg vendidos y 40 a
     socios = 40%.
   - EsCajaDelivery sale de CFG_CAJA_DELIVERY (pedido de Damian del
     02/10/2026): la leyenda "Cajas Delivery" y la marca en la columna Caja
     se arman con eso, no con un texto fijo.
   - CLIMA DE ZONA (ClimaZona*, espec de Damian del 01/10/2026): ver 2b.
     Es el que muestran la web y el Excel desde la version de octubre 2026.
     Las columnas de abajo quedan por compatibilidad con la version anterior.
   - CLIMA (pedido de Damian del 02/10/2026, reemplaza las columnas
     reservadas Personal / Productividad / Clima del Excel):
       SensacionTermica = promedio de SENSACION_TERMICA de CLIMA_ZONA_HORA
       LluviaMm         = suma de PRECIPITACION
     sobre las horas en que el turno tuvo ventas (de la hora de la primera a
     la de la ultima, inclusive). Las columnas Suc* son lo mismo pero para la
     sucursal en toda la jornada, y son las que van en el subtotal: sumar la
     lluvia de los turnos la contaria dos veces cuando las dos cajas trabajan
     a la vez.

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
        PRIMERA datetime, ULTIMA datetime, KILOS numeric(28,8),
        PROMOS numeric(28,8)
    );

    INSERT #TK
    SELECT h.FECHA_OPERATIVA, h.SUCURSAL, h.SUCURSAL_DESCRIP,
           h.TURNO, h.CAJA, h.USULOGIN, h.TICKET_KEY,
           MAX(h.VTAIMPORTE),
           MAX(CAST(h.ES_ANULADA AS int)),
           MAX(CAST(h.ES_CLUB_GRIDO AS int)),
           MAX(h.SOBREVENTA),
           MIN(h.FECHA_HORA), MAX(h.FECHA_HORA),
           SUM(h.KILOS),
           -- IMPORTE ya vale cero en las PROMO=2 y en las anuladas.
           SUM(CASE WHEN h.LINEA_ES_PROMOCION = 1 THEN h.IMPORTE ELSE 0 END)
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
    -- 2b) CLIMA DE ZONA (espec de Damian del 01/10/2026, seccion 2 bis).
    --     Columnas ClimaZona* / SucClimaZona* / DiaClimaZona*. Las columnas
    --     viejas (SensacionTermica, LluviaMm, Suc*) siguen igual porque las
    --     lee produccion hasta que se publique la version nueva.
    --
    --     - Para cada hora, la carga mas reciente entre Lanus Oeste, Escalada
    --       y Fiorito (el modelo es en grilla; lo que cambia es cuando se cargo).
    --     - Horas del turno: de la de la primera venta a la de la ultima, y la
    --       de fin cuenta solo si tiene minutos ("10:18 a 15:00" = 10 a 14).
    --     - Sensacion: promedio de las horas. Lluvia: suma. Condicion: la que
    --       mas se repite entre TODAS las filas de esas horas; en un empate
    --       gana la que aparece primero (hora, y ubicacion por nombre). Es la
    --       misma regla que reporting/informe_grido (Excel), para que den igual.
    --     - Subtotal: union de las horas de los turnos de la sucursal. TOTAL:
    --       union de las horas de todos los turnos del dia.
    -- =======================================================================
    SELECT FECHA_OPERATIVA, SUCURSAL, TURNO, CAJA, CAJERO,
           PRIMERA = MIN(CASE WHEN ES_ANULADA = 0 THEN PRIMERA END),
           ULTIMA  = MAX(CASE WHEN ES_ANULADA = 0 THEN ULTIMA END)
    INTO #TURNO
    FROM #TK
    GROUP BY FECHA_OPERATIVA, SUCURSAL, TURNO, CAJA, CAJERO;

    ;WITH N AS (SELECT TOP 48 n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 FROM sys.all_objects)
    SELECT t.FECHA_OPERATIVA, t.SUCURSAL, t.TURNO, t.CAJA, t.CAJERO,
           KH = DATEADD(hour, N.n, DATEADD(hour, DATEDIFF(hour, 0, t.PRIMERA), 0))
    INTO #HT
    FROM #TURNO t
    CROSS JOIN N
    CROSS APPLY (SELECT ini = DATEADD(hour, DATEDIFF(hour, 0, t.PRIMERA), 0),
                        fin = DATEADD(hour, DATEDIFF(hour, 0, t.ULTIMA), 0)) x
    CROSS APPLY (SELECT ult = CASE WHEN DATEPART(minute, t.ULTIMA) = 0 AND x.fin > x.ini
                                   THEN DATEADD(hour, -1, x.fin) ELSE x.fin END) y
    WHERE t.PRIMERA IS NOT NULL
      AND DATEADD(hour, N.n, x.ini) <= y.ult;

    ;WITH cz AS (
        SELECT c.CLIMA_KEY_HORA, c.SUCURSAL_NOMBRE, c.SENSACION_TERMICA, c.PRECIPITACION,
               c.DESCRIPCION_TIEMPO, c.FECHA_CARGA,
               ULTIMA_CARGA = MAX(c.FECHA_CARGA) OVER (PARTITION BY c.CLIMA_KEY_HORA)
        FROM dbo.CLIMA_ZONA_HORA c
        WHERE c.BASE_ORIGEN = @BaseOrigen
          AND c.SUCURSAL_NOMBRE IN ('Lanus Oeste', 'Escalada', 'Fiorito')
          AND c.CLIMA_KEY_HORA >= CAST(@FechaDesde AS datetime)
          AND c.CLIMA_KEY_HORA <  DATEADD(hour, 26, CAST(@FechaHasta AS datetime)))
    SELECT KH = CLIMA_KEY_HORA, UBIC = SUCURSAL_NOMBRE, ST = SENSACION_TERMICA, P = PRECIPITACION,
           D = NULLIF(LTRIM(RTRIM(DESCRIPCION_TIEMPO)), '')
    INTO #CZ
    FROM cz WHERE FECHA_CARGA = ULTIMA_CARGA;

    -- Promedio de las ubicaciones por hora (sensacion y lluvia).
    SELECT KH, ST = AVG(ST), P = AVG(P) INTO #CZH FROM #CZ GROUP BY KH;

    -- Clima de un conjunto de horas: #SET (CLAVE, KH) -> #RES (CLAVE, SENS, LLUVIA, COND).
    -- Se usa tres veces: turno, sucursal-dia y dia.
    CREATE TABLE #SET (CLAVE varchar(200), KH datetime);
    CREATE TABLE #CLIMA (NIVEL char(1), CLAVE varchar(200), SENS numeric(18,6), LLUVIA numeric(18,6), COND varchar(100));

    INSERT #SET SELECT DISTINCT
        'T|' + CONVERT(varchar(10), FECHA_OPERATIVA, 23) + '|' + CAST(SUCURSAL AS varchar(5)) + '|'
             + CAST(TURNO AS varchar(10)) + '|' + CAST(CAJA AS varchar(5)) + '|' + CAJERO, KH FROM #HT;
    INSERT #SET SELECT DISTINCT
        'S|' + CONVERT(varchar(10), FECHA_OPERATIVA, 23) + '|' + CAST(SUCURSAL AS varchar(5)), KH FROM #HT;
    INSERT #SET SELECT DISTINCT 'D|' + CONVERT(varchar(10), FECHA_OPERATIVA, 23), KH FROM #HT;

    INSERT #CLIMA (NIVEL, CLAVE, SENS, LLUVIA, COND)
    SELECT LEFT(s.CLAVE, 1), s.CLAVE, AVG(h.ST), SUM(h.P),
           (SELECT TOP 1 z.D
            FROM #SET s2 JOIN #CZ z ON z.KH = s2.KH
            WHERE s2.CLAVE = s.CLAVE AND z.D IS NOT NULL
            GROUP BY z.D
            ORDER BY COUNT(*) DESC, MIN(CONVERT(varchar(19), z.KH, 120) + z.UBIC))
    FROM #SET s
    LEFT JOIN #CZH h ON h.KH = s.KH
    GROUP BY s.CLAVE;

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
            KILOS_CLUB    = SUM(CASE WHEN ES_ANULADA = 0 AND ES_CLUB = 1 THEN KILOS ELSE 0 END),
            PROMOS        = SUM(CASE WHEN ES_ANULADA = 0 THEN PROMOS ELSE 0 END),
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
    ),
    -- La ventana de la sucursal en la jornada, para el clima del subtotal.
    SUCDIA AS (
        SELECT FECHA_OPERATIVA, SUCURSAL, PRIMERA = MIN(PRIMERA), ULTIMA = MAX(ULTIMA)
        FROM BASE
        GROUP BY FECHA_OPERATIVA, SUCURSAL
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
        Promos  = CAST(b.PROMOS AS numeric(16,4)),
        Socios  = CASE WHEN p.rn = 1 THEN ISNULL(s.SOCIOS, 0) ELSE 0 END,
        VentasClub = b.VENTAS_CLUB,
        KilosClub  = CAST(ROUND(b.KILOS_CLUB, 1) AS numeric(12,1)),
        Anuladas   = b.ANULADAS,
        DifCaja    = ISNULL(t.TURDIFERENCIA, 0),
        EsCajaDelivery = CAST(CASE WHEN cd.CAJA IS NULL THEN 0 ELSE 1 END AS bit),
        SensacionTermica    = CAST(ct.SENS AS numeric(5,1)),
        LluviaMm            = CAST(ct.LLUVIA AS numeric(7,1)),
        SucSensacionTermica = CAST(cs.SENS AS numeric(5,1)),
        SucLluviaMm         = CAST(cs.LLUVIA AS numeric(7,1)),
        -- Clima de zona (ver 2b): turno, sucursal (subtotal) y dia (TOTAL).
        ClimaZonaSens          = CAST(zt.SENS AS numeric(5,1)),
        ClimaZonaLluvia        = CAST(zt.LLUVIA AS numeric(7,1)),
        ClimaZonaCondicion     = zt.COND,
        SucClimaZonaSens       = CAST(zs.SENS AS numeric(5,1)),
        SucClimaZonaLluvia     = CAST(zs.LLUVIA AS numeric(7,1)),
        SucClimaZonaCondicion  = zs.COND,
        DiaClimaZonaSens       = CAST(zd.SENS AS numeric(5,1)),
        DiaClimaZonaLluvia     = CAST(zd.LLUVIA AS numeric(7,1)),
        DiaClimaZonaCondicion  = zd.COND
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
    LEFT JOIN dbo.CFG_CAJA_DELIVERY cd
      ON  cd.BASE_ORIGEN = @BaseOrigen AND cd.SUCURSAL = b.SUCURSAL AND cd.CAJA = b.CAJA
    -- Clima del turno: horas enteras desde la de la primera venta hasta la de
    -- la ultima. CLIMA_KEY_HORA esta en hora local, igual que FECHA_HORA.
    OUTER APPLY (
        SELECT SENS = AVG(c.SENSACION_TERMICA), LLUVIA = SUM(c.PRECIPITACION)
        FROM dbo.CLIMA_ZONA_HORA c
        WHERE c.BASE_ORIGEN = @BaseOrigen AND c.SUCURSAL = b.SUCURSAL
          AND c.CLIMA_KEY_HORA >= DATEADD(hour, DATEDIFF(hour, 0, b.PRIMERA), 0)
          AND c.CLIMA_KEY_HORA <= DATEADD(hour, DATEDIFF(hour, 0, b.ULTIMA), 0)
    ) ct
    -- Clima de la sucursal en la jornada, para el subtotal.
    JOIN SUCDIA sd
      ON  sd.FECHA_OPERATIVA = b.FECHA_OPERATIVA AND sd.SUCURSAL = b.SUCURSAL
    OUTER APPLY (
        SELECT SENS = AVG(c.SENSACION_TERMICA), LLUVIA = SUM(c.PRECIPITACION)
        FROM dbo.CLIMA_ZONA_HORA c
        WHERE c.BASE_ORIGEN = @BaseOrigen AND c.SUCURSAL = sd.SUCURSAL
          AND c.CLIMA_KEY_HORA >= DATEADD(hour, DATEDIFF(hour, 0, sd.PRIMERA), 0)
          AND c.CLIMA_KEY_HORA <= DATEADD(hour, DATEDIFF(hour, 0, sd.ULTIMA), 0)
    ) cs
    LEFT JOIN #CLIMA zt ON zt.CLAVE = 'T|' + CONVERT(varchar(10), b.FECHA_OPERATIVA, 23) + '|'
                                     + CAST(b.SUCURSAL AS varchar(5)) + '|' + CAST(b.TURNO AS varchar(10)) + '|'
                                     + CAST(b.CAJA AS varchar(5)) + '|' + b.CAJERO
    LEFT JOIN #CLIMA zs ON zs.CLAVE = 'S|' + CONVERT(varchar(10), b.FECHA_OPERATIVA, 23) + '|'
                                     + CAST(b.SUCURSAL AS varchar(5))
    LEFT JOIN #CLIMA zd ON zd.CLAVE = 'D|' + CONVERT(varchar(10), b.FECHA_OPERATIVA, 23)
    ORDER BY b.FECHA_OPERATIVA,
             CASE b.SUCURSAL WHEN 3 THEN 1 WHEN 2 THEN 2 WHEN 1 THEN 3 ELSE 9 END,
             b.TURNO, b.CAJA;
END
GO
