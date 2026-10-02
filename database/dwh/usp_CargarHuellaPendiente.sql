/* ===========================================================================
   DF_DTW.dbo.usp_CargarHuellaPendiente
   ---------------------------------------------------------------------------
   Puesta al dia de TRX_HUELLA_VENTA.

   Para cada base activa averigua cual fue la ultima jornada cargada y avanza
   desde la siguiente hasta AYER, llamando a usp_CargarHuellaVenta una vez por
   dia. Es lo que corre la tarea diaria PILL_huellaventaDiaria.

   POR QUE "DESDE LA ULTIMA + 1" Y NO "AYER"
   -----------------------------------------
   Si el equipo estuvo apagado, o la tarea fallo, o el restore de la base de
   origen no corrio, cargar solo ayer dejaria un agujero permanente. Asi la
   tarea se pone al dia sola.

   POR QUE HASTA AYER Y NO HASTA HOY
   ---------------------------------
   La jornada D va de D 02:00 a D+1 02:00, o sea que la de hoy todavia no
   termino. Cargarla daria un dia incompleto que despues nadie recarga.

   AUTOREPARACION
   --------------
   El arranque sale de MAX(FECHA_OPERATIVA), que solo avanza con jornadas que
   trajeron filas. Si la ultima quedo vacia porque el origen no habia
   sincronizado, la proxima corrida la vuelve a intentar sola. Un dia sin
   ventas en el medio no se reintenta para siempre: el MAX ya lo paso.

   RECARGA DE LOS ULTIMOS @DiasRecarga DIAS (agregado el 01/10/2026)
   -----------------------------------------------------------------
   Los locales sincronizan con el servidor central cuando pueden, a veces dias
   despues. Una jornada que se cargo con la sincronizacion a medias movia el
   MAX y no se volvia a mirar nunca: Escalada 26/09 quedo con 122 tickets de
   267 (falto la caja 1 entera y el ultimo turno de la caja 2).
   Por eso cada corrida, ademas de avanzar, vuelve a cargar las ultimas
   @DiasRecarga jornadas hasta ayer. Cuesta poco: unas 1.200 filas por
   jornada, una transaccion por dia, y la base esta en recuperacion SIMPLE.
   Lo que sincronice despues de esa ventana lo detecta usp_CuadreHuella.

   Creado: 2026-09-15
   =========================================================================== */

USE DF_DTW;
GO

IF OBJECT_ID('dbo.usp_CargarHuellaPendiente', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_CargarHuellaPendiente;
GO

CREATE PROCEDURE dbo.usp_CargarHuellaPendiente
    /* Tope de jornadas por corrida y por base. Existe para que un hueco largo
       no convierta la tarea diaria en un proceso de horas: lo que falte se
       termina de cubrir en las corridas siguientes. */
    @MaxDias        int     = 45,
    /* Solo se usa si la tabla esta vacia para esa base. El default evita que
       un alta nueva dispare sin querer un backfill de anos. */
    @DesdeSiVacia   date    = NULL,
    @HoraCorte      time(0) = '02:00',
    /* Jornadas ya cargadas que se vuelven a cargar en cada corrida. 0 = solo
       avanzar, como antes. */
    @DiasRecarga    int     = 7,
    @Debug          bit     = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ayer date = CAST(DATEADD(day, -1, SYSDATETIME()) AS date);

    IF @DesdeSiVacia IS NULL SET @DesdeSiVacia = @ayer;

    IF @MaxDias IS NULL OR @MaxDias < 1
    BEGIN
        RAISERROR('usp_CargarHuellaPendiente: @MaxDias debe ser 1 o mas.', 16, 1);
        RETURN;
    END

    IF @DiasRecarga IS NULL OR @DiasRecarga < 0
    BEGIN
        RAISERROR('usp_CargarHuellaPendiente: @DiasRecarga debe ser 0 o mas.', 16, 1);
        RETURN;
    END

    DECLARE @res TABLE (
        BASE_ORIGEN sysname, DESDE date, HASTA date,
        JORNADAS int, TRUNCADO bit, MENSAJE varchar(200));

    -- Primera jornada de la ventana de recarga (si @DiasRecarga = 0 queda despues de ayer).
    DECLARE @inicioRecarga date = DATEADD(day, 1 - @DiasRecarga, @ayer);

    /* Marca de agua de la bitacora ANTES de empezar. El control de errores del
       final mira solo lo que escribio ESTA corrida.
       Antes miraba "las ultimas 2 horas" de reloj, y con eso un error viejo
       -por ejemplo de una prueba a mano- hacia fallar la tarea diaria durante
       dos horas sin que hubiera pasado nada. Una alarma que suena sola es peor
       que no tener alarma: ensena a ignorarla. */
    DECLARE @logIdInicio int = ISNULL((SELECT MAX(LOG_ID) FROM dbo.LOG_CARGA_HUELLA), 0);

    DECLARE @base sysname, @primera date, @ultima date, @d date, @hasta date, @n int, @trunc bit;

    /* La dimension de costos de insumo se refresca ANTES de cargar. Si un
       insumo cambio de precio ayer, la jornada de ayer tiene que costearse con
       el precio nuevo; si se refrescara despues, quedaria con el anterior. */
    DECLARE @b2 sysname;
    DECLARE dim_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT BASE_ORIGEN FROM dbo.CFG_BASES_ORIGEN WHERE ACTIVA = 1;
    OPEN dim_cur;
    FETCH NEXT FROM dim_cur INTO @b2;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC dbo.usp_RefrescarDimInsumoCosto @BaseOrigen = @b2;
        FETCH NEXT FROM dim_cur INTO @b2;
    END
    CLOSE dim_cur;
    DEALLOCATE dim_cur;

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT BASE_ORIGEN FROM dbo.CFG_BASES_ORIGEN WHERE ACTIVA = 1 ORDER BY BASE_ORIGEN;
    OPEN cur;
    FETCH NEXT FROM cur INTO @base;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SELECT @primera = MIN(FECHA_OPERATIVA), @ultima = MAX(FECHA_OPERATIVA)
        FROM dbo.TRX_HUELLA_VENTA WHERE BASE_ORIGEN = @base;

        SET @d = CASE WHEN @ultima IS NULL THEN @DesdeSiVacia ELSE DATEADD(day, 1, @ultima) END;
        /* La ventana de recarga corre el arranque hacia atras, pero nunca antes
           de la primera jornada que tiene la base: una base recien dada de alta
           no tiene que hacer un backfill que nadie pidio. */
        IF @ultima IS NOT NULL AND @inicioRecarga < @d
            SET @d = CASE WHEN @inicioRecarga < @primera THEN @primera ELSE @inicioRecarga END;
        SET @n = 0;
        SET @trunc = 0;

        IF @d > @ayer
        BEGIN
            INSERT @res VALUES (@base, NULL, NULL, 0, 0,
                'Al dia. Ultima jornada cargada: ' + CONVERT(varchar(10), @ultima, 23));
        END
        ELSE
        BEGIN
            SET @hasta = @ayer;
            IF DATEDIFF(day, @d, @hasta) + 1 > @MaxDias
            BEGIN
                SET @hasta = DATEADD(day, @MaxDias - 1, @d);
                SET @trunc = 1;
            END

            WHILE @d <= @hasta
            BEGIN
                IF @Debug = 1
                    PRINT 'Cargaria ' + @base + ' ' + CONVERT(varchar(10), @d, 23);
                ELSE
                    EXEC dbo.usp_CargarHuellaVenta
                         @FechaOperativa = @d,
                         @HoraCorte      = @HoraCorte,
                         @BasesLectura   = @base;

                SET @n += 1;
                SET @d = DATEADD(day, 1, @d);
            END

            INSERT @res VALUES (@base, DATEADD(day, -@n, @d), DATEADD(day, -1, @d), @n, @trunc,
                CASE WHEN @trunc = 1
                     THEN 'Tope de ' + CAST(@MaxDias AS varchar(5))
                          + ' jornadas alcanzado. Queda pendiente hasta '
                          + CONVERT(varchar(10), @ayer, 23) + '; se completa en las proximas corridas.'
                     ELSE 'Puesta al dia completa.' END);
        END

        FETCH NEXT FROM cur INTO @base;
    END
    CLOSE cur;
    DEALLOCATE cur;

    SELECT BASE_ORIGEN, DESDE, HASTA, JORNADAS, TRUNCADO, MENSAJE FROM @res ORDER BY BASE_ORIGEN;

    -- Que la tarea programada pueda fallar de verdad si algo salio mal.
    IF EXISTS (SELECT 1 FROM dbo.LOG_CARGA_HUELLA
               WHERE ESTADO = 'ERROR' AND LOG_ID > @logIdInicio)
    BEGIN
        RAISERROR('usp_CargarHuellaPendiente: hubo jornadas con ERROR en esta corrida. Revisar dbo.LOG_CARGA_HUELLA.', 16, 1);
        RETURN;
    END
END
GO
