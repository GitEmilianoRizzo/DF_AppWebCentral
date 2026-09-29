/* ===========================================================================
   usp_EstadisticaVentas
   ---------------------------------------------------------------------------
   Replica la consulta "Estadisticas de Venta" de SmartFran sobre la huella.

   POR QUE EXISTE
   --------------
   Damian valida los numeros con esa pantalla, y se comprobo que la huella la
   reproduce: para el periodo 01/09 al 08/09 de 2026, Escalada, Fiorito y
   Mayorista dan identicas al centavo en venta, cantidad, descuentos, kilos,
   costo y utilidad. Lanus difiere solo por datos que llegaron al servidor
   central despues del momento en que se tomo la captura.

   DOS UTILIDADES, A PROPOSITO
   ---------------------------
   SmartFran llama "Utilidad" a Venta - Costo de mercaderia. Nosotros ademas
   calculamos la contribucion marginal, que resta tambien los insumos
   (cucuruchos, vasos, servilletas). Las dos viajan juntas en cada fila: la
   primera permite cruzar contra SmartFran, la segunda es el indicador propio.
   Si mostraramos solo la segunda, cada comparacion pareceria un error.

   EL PERIODO ES HORA CALENDARIO, NO JORNADA
   -----------------------------------------
   SmartFran filtra por FECHA_HORA de 00:00 a 24:00. El Informe Diario usa la
   jornada comercial de 02:00 a 02:00. Son convenciones distintas y no dan
   igual entre si: este SP usa la de SmartFran porque su razon de ser es
   cruzar contra esa pantalla.

   @FechaHasta es EXCLUSIVO. La captura de Damian decia "hasta 09-09 14:25",
   pero los datos llegaban hasta el 8 inclusive: esas 14:25 eran la hora en
   que corrio la consulta, no el fin del periodo.
   =========================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_EstadisticaVentas
    @FechaDesde    datetime,
    @FechaHasta    datetime,
    @Sucursales    varchar(200) = NULL,   -- CSV de ids; NULL = todas
    @HoraDesde     tinyint      = 0,
    @HoraHasta     tinyint      = 24,
    @DiasSemana    varchar(30)  = NULL,   -- CSV 1..7 (1=lunes); NULL = todos
    @Canal         int          = NULL,
    @TipoProducto  varchar(10)  = NULL,
    @GrupoProducto int          = NULL,
    @Articulo      int          = NULL,
    @Delivery      tinyint      = NULL,   -- NULL todos / 1 solo delivery / 0 sin delivery
    @Cajero        varchar(20)  = NULL,
    @Cliente       int          = NULL,
    @TopArticulos  int          = 200,
    @BaseOrigen    varchar(30)  = 'SRV_GRIDO_ZSUR'
AS
BEGIN
    SET NOCOUNT ON;

    IF @FechaDesde IS NULL OR @FechaHasta IS NULL
    BEGIN
        RAISERROR('Hay que indicar @FechaDesde y @FechaHasta.', 16, 1);
        RETURN;
    END

    IF @FechaDesde >= @FechaHasta
    BEGIN
        RAISERROR('@FechaDesde tiene que ser anterior a @FechaHasta.', 16, 1);
        RETURN;
    END

    /* Las sucursales llegan como texto para que el front mande una sola
       cadena. NULL o vacio = todas. */
    DECLARE @sucFiltro TABLE (SUCURSAL int PRIMARY KEY);
    IF NULLIF(LTRIM(RTRIM(@Sucursales)), '') IS NOT NULL
        INSERT @sucFiltro (SUCURSAL)
        SELECT DISTINCT TRY_CAST(LTRIM(RTRIM(value)) AS int)
        FROM STRING_SPLIT(@Sucursales, ',')
        WHERE TRY_CAST(LTRIM(RTRIM(value)) AS int) IS NOT NULL;

    DECLARE @diaFiltro TABLE (DIA int PRIMARY KEY);
    IF NULLIF(LTRIM(RTRIM(@DiasSemana)), '') IS NOT NULL
        INSERT @diaFiltro (DIA)
        SELECT DISTINCT TRY_CAST(LTRIM(RTRIM(value)) AS int)
        FROM STRING_SPLIT(@DiasSemana, ',')
        WHERE TRY_CAST(LTRIM(RTRIM(value)) AS int) BETWEEN 1 AND 7;

    DECLARE @hayFiltroSuc bit = CASE WHEN EXISTS (SELECT 1 FROM @sucFiltro) THEN 1 ELSE 0 END;
    DECLARE @hayFiltroDia bit = CASE WHEN EXISTS (SELECT 1 FROM @diaFiltro) THEN 1 ELSE 0 END;

    /* =======================================================================
       Universo filtrado, una sola vez.

       El dia de la semana se calcula con DATEDIFF contra un lunes conocido y
       NO con DATEPART(dw): esa funcion depende de SET DATEFIRST, que varia
       segun el idioma del login y haria que el mismo filtro devuelva cosas
       distintas segun quien ejecute.
       ======================================================================= */
    CREATE TABLE #U (
        TICKET_KEY    varchar(90),
        SUCURSAL      int,
        SUC_DESCRIP   varchar(30),
        FECHA_HORA    datetime,
        DIA           date,
        HORA          tinyint,
        DIA_SEMANA    int,
        MES           int,
        ES_ANULADA    bit,
        GRUPO_DESCRIP varchar(20),
        ART_DESCRIP   varchar(50),
        ARTICULO      int,
        PROMOCION     int,
        PROMO_DESCRIP varchar(60),
        SOBREVENTA    varchar(10),
        CANAL_DESCRIP varchar(20),
        ENTREGA       varchar(12),
        ES_PROMO      bit,
        PROMO         tinyint,
        ES_SOBREVENTA bit,
        IMPORTE       numeric(18,4),
        CANTIDAD      numeric(18,4),
        DESCUENTOS    numeric(18,4),
        KILOS         numeric(18,6),
        COSTO         numeric(18,4),
        UTILIDAD      numeric(18,4),
        CONTRIB       numeric(18,4),
        TEMPERATURA   numeric(6,2)
    );

    INSERT #U
    SELECT
        h.TICKET_KEY,
        h.SUCURSAL,
        h.SUCURSAL_DESCRIP,
        h.FECHA_HORA,
        CAST(h.FECHA_HORA AS date),
        h.HORA,
        (DATEDIFF(day, '1900-01-01', h.FECHA_HORA) % 7) + 1,   -- 1 = lunes
        MONTH(h.FECHA_HORA),
        h.ES_ANULADA,
        ISNULL(NULLIF(RTRIM(h.ART_GRUPO_DESCRIP), ''), '(Sin grupo)'),
        ISNULL(NULLIF(RTRIM(h.ART_DESCRIP), ''), '(Sin descripcion)'),
        h.ARTICULO,
        h.PROMOCION,
        ISNULL(NULLIF(RTRIM(h.PROMOCION_DESCRIP), ''), '(Sin promocion)'),
        ISNULL(NULLIF(RTRIM(h.SOBREVENTA), ''), 'SIN OFRECER'),
        /* El canal sale de VTAOPERACION y NO de VTACANAL.

           VTACANAL viene casi siempre en NULL (1.186 lineas de 25.620 en
           septiembre): agrupar por ahi da una sola porcion y el grafico no
           dice nada. VTAOPERACION en cambio esta siempre cargada y es lo que
           usa SmartFran: para el periodo de la captura del 09/09, VG da
           7.036.750 (12,67%), identico al "Gastro 7036750 13%" de esa
           pantalla, y VL corresponde a la porcion "C.G".

           VL es ademas el mismo criterio con el que el Informe Diario mide
           Ventas Club Grido. */
        CASE RTRIM(h.VTAOPERACION)
             WHEN 'VF' THEN 'Mostrador'
             WHEN 'VL' THEN 'Club Grido'
             WHEN 'VG' THEN 'Gastronomico'
             WHEN 'CL' THEN 'Canje Club Grido'
             WHEN 'VC' THEN 'Cuenta Corriente'
             ELSE ISNULL(NULLIF(RTRIM(h.VTAOPERACION), ''), '(Sin canal)')
        END,
        CASE WHEN h.ES_PLATAFORMA_DELIVERY = 1 THEN 'Delivery'
             WHEN h.VTADELIVERY = 1           THEN 'Delivery'
             WHEN h.SUCURSAL = 4              THEN 'Store'
             ELSE 'Salon' END,
        h.LINEA_ES_PROMOCION,
        h.PROMO,
        h.LINEA_ES_SOBREVENTA,
        h.IMPORTE, h.CANTIDAD, h.DESCUENTOS, h.KILOS,
        h.COSTO, h.UTILIDAD, h.CONTRIB_MARGINAL,
        cl.TEMPERATURA
    FROM dbo.TRX_HUELLA_VENTA h
    /* El clima se trae aca y no en cada corte: es una tabla chica (87 mil
       filas, las 4 sucursales hora por hora desde 2024) y asi se busca una
       sola vez. La cobertura es total: el 100% de las lineas de venta tienen
       su hora de clima. El LEFT igual se mantiene por si un dia falta. */
    LEFT JOIN dbo.CLIMA_ZONA_HORA cl
           ON cl.BASE_ORIGEN    = h.BASE_ORIGEN
          AND cl.SUCURSAL       = h.SUCURSAL
          AND cl.CLIMA_KEY_HORA = h.CLIMA_KEY_HORA
    WHERE h.BASE_ORIGEN = @BaseOrigen
      AND h.FECHA_HORA >= @FechaDesde
      AND h.FECHA_HORA <  @FechaHasta
      AND h.HORA >= @HoraDesde
      AND h.HORA <  @HoraHasta
      AND (@hayFiltroSuc = 0 OR h.SUCURSAL IN (SELECT SUCURSAL FROM @sucFiltro))
      AND (@hayFiltroDia = 0
           OR ((DATEDIFF(day, '1900-01-01', h.FECHA_HORA) % 7) + 1) IN (SELECT DIA FROM @diaFiltro))
      AND (@Canal         IS NULL OR h.VTACANAL  = @Canal)
      AND (@TipoProducto  IS NULL OR RTRIM(h.ART_TIPO) = @TipoProducto)
      AND (@GrupoProducto IS NULL OR h.ART_GRUPO = @GrupoProducto)
      AND (@Articulo      IS NULL OR h.ARTICULO  = @Articulo)
      AND (@Cajero        IS NULL OR RTRIM(h.USULOGIN) = @Cajero)
      AND (@Cliente       IS NULL OR h.CLIENTE   = @Cliente)
      AND (@Delivery      IS NULL
           OR (@Delivery = 1 AND (h.VTADELIVERY = 1 OR h.ES_PLATAFORMA_DELIVERY = 1))
           OR (@Delivery = 0 AND  h.VTADELIVERY = 0 AND h.ES_PLATAFORMA_DELIVERY = 0));

    CREATE CLUSTERED INDEX IX_U ON #U (SUCURSAL, TICKET_KEY);

    /* La venta total sirve de denominador en casi todos los cortes. Se calcula
       una vez y no por fila, que multiplicaria el barrido de la tabla. */
    DECLARE @ventaTotal numeric(18,4) =
        (SELECT ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN IMPORTE ELSE 0 END), 0) FROM #U);

    /* =======================================================================
       1) Totales: el panel azul de la derecha en la pantalla de SmartFran.

       Los tickets EXCLUYEN los anulados, que es como los cuenta SmartFran.
       Las sobreventas se cuentan por ticket, no por linea: "Activadas / Total"
       es la proporcion de tickets en los que se ofrecio una.
       ======================================================================= */
    SELECT
        VentaTotal     = @ventaTotal,
        Tickets        = COUNT(DISTINCT CASE WHEN ES_ANULADA = 0 THEN TICKET_KEY END),
        TicketPromedio = CAST(@ventaTotal
                              / NULLIF(COUNT(DISTINCT CASE WHEN ES_ANULADA = 0 THEN TICKET_KEY END), 0)
                              AS numeric(18,2)),
        Cantidad       = ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN CANTIDAD ELSE 0 END), 0),
        Descuentos     = ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN DESCUENTOS ELSE 0 END), 0),
        Promos         = ISNULL(SUM(CASE WHEN ES_ANULADA = 0 AND PROMO = 1 THEN CANTIDAD ELSE 0 END), 0),
        Kilos          = ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN KILOS ELSE 0 END), 0),
        Costo          = ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN COSTO ELSE 0 END), 0),
        Utilidad       = ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN UTILIDAD ELSE 0 END), 0),
        ContribMarginal= ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN CONTRIB ELSE 0 END), 0),
        TicketsAnulados= COUNT(DISTINCT CASE WHEN ES_ANULADA = 1 THEN TICKET_KEY END),
        SvActivadas    = COUNT(DISTINCT CASE WHEN ES_ANULADA = 0 AND SOBREVENTA IN ('ACEPTADA','RECHAZADA') THEN TICKET_KEY END),
        SvAceptadas    = COUNT(DISTINCT CASE WHEN ES_ANULADA = 0 AND SOBREVENTA = 'ACEPTADA' THEN TICKET_KEY END),
        /* OJO con estas dos: el monto sale de LINEA_ES_SOBREVENTA, que marca
           la linea que ES la sobreventa. SOBREVENTA en cambio es un atributo
           del ticket y viene repetido en todas sus lineas, asi que usarlo
           aca sumaria el ticket entero: da 4.866.500 en vez de 1.376.800. */
        SvImporte      = ISNULL(SUM(CASE WHEN ES_ANULADA = 0 AND ES_SOBREVENTA = 1 THEN IMPORTE ELSE 0 END), 0),
        SvKilos        = ISNULL(SUM(CASE WHEN ES_ANULADA = 0 AND ES_SOBREVENTA = 1 THEN KILOS ELSE 0 END), 0)
    FROM #U;

    /* =======================================================================
       2) Por sucursal: la grilla principal, la que se cruza contra SmartFran.
       ======================================================================= */
    SELECT
        Detalle    = SUC_DESCRIP,
        Sucursal   = SUCURSAL,
        Venta      = ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN IMPORTE ELSE 0 END), 0),
        Porcentaje = CAST(100.0 * ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN IMPORTE ELSE 0 END), 0)
                          / NULLIF(@ventaTotal, 0) AS numeric(18,4)),
        Pedidos    = COUNT(DISTINCT CASE WHEN ES_ANULADA = 0 THEN TICKET_KEY END),
        Cantidad   = ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN CANTIDAD ELSE 0 END), 0),
        Descuentos = ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN DESCUENTOS ELSE 0 END), 0),
        Promos     = ISNULL(SUM(CASE WHEN ES_ANULADA = 0 AND PROMO = 1 THEN CANTIDAD ELSE 0 END), 0),
        Kilos      = ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN KILOS ELSE 0 END), 0),
        Costo      = ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN COSTO ELSE 0 END), 0),
        Utilidad   = ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN UTILIDAD ELSE 0 END), 0),
        PctUtilidad= CAST(100.0 * ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN UTILIDAD ELSE 0 END), 0)
                          / NULLIF(SUM(CASE WHEN ES_ANULADA = 0 THEN IMPORTE ELSE 0 END), 0) AS numeric(18,4)),
        ContribMarginal = ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN CONTRIB ELSE 0 END), 0),
        PctContrib = CAST(100.0 * ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN CONTRIB ELSE 0 END), 0)
                          / NULLIF(SUM(CASE WHEN ES_ANULADA = 0 THEN IMPORTE ELSE 0 END), 0) AS numeric(18,4))
    FROM #U
    GROUP BY SUCURSAL, SUC_DESCRIP
    ORDER BY SUC_DESCRIP;

    /* 3) Por grupo de producto */
    SELECT
        Detalle    = GRUPO_DESCRIP,
        Venta      = ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN IMPORTE ELSE 0 END), 0),
        Porcentaje = CAST(100.0 * ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN IMPORTE ELSE 0 END), 0)
                          / NULLIF(@ventaTotal, 0) AS numeric(18,4)),
        Cantidad   = ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN CANTIDAD ELSE 0 END), 0),
        Descuentos = ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN DESCUENTOS ELSE 0 END), 0),
        Promos     = ISNULL(SUM(CASE WHEN ES_ANULADA = 0 AND PROMO = 1 THEN CANTIDAD ELSE 0 END), 0),
        Kilos      = ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN KILOS ELSE 0 END), 0),
        Costo      = ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN COSTO ELSE 0 END), 0),
        Utilidad   = ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN UTILIDAD ELSE 0 END), 0),
        PctUtilidad= CAST(100.0 * ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN UTILIDAD ELSE 0 END), 0)
                          / NULLIF(SUM(CASE WHEN ES_ANULADA = 0 THEN IMPORTE ELSE 0 END), 0) AS numeric(18,4)),
        ContribMarginal = ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN CONTRIB ELSE 0 END), 0),
        PctContrib = CAST(100.0 * ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN CONTRIB ELSE 0 END), 0)
                          / NULLIF(SUM(CASE WHEN ES_ANULADA = 0 THEN IMPORTE ELSE 0 END), 0) AS numeric(18,4))
    FROM #U
    GROUP BY GRUPO_DESCRIP
    -- Los grupos sin venta en el periodo no se listan: SmartFran tampoco los
    -- muestra, y ensucian la grilla con filas en cero (CANJES, SOBREVENTA,
    -- PROMOCIONES aparecen siempre porque son grupos tecnicos).
    HAVING SUM(CASE WHEN ES_ANULADA = 0 THEN IMPORTE ELSE 0 END) <> 0
        OR SUM(CASE WHEN ES_ANULADA = 0 THEN CANTIDAD ELSE 0 END) <> 0
    ORDER BY 2 DESC;

    /* 4) Por articulo. Se acota con @TopArticulos: el catalogo tiene miles y
          el navegador no puede pintarlos todos de una. */
    SELECT TOP (@TopArticulos)
        Detalle    = ART_DESCRIP,
        Articulo   = ARTICULO,
        Venta      = ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN IMPORTE ELSE 0 END), 0),
        Porcentaje = CAST(100.0 * ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN IMPORTE ELSE 0 END), 0)
                          / NULLIF(@ventaTotal, 0) AS numeric(18,4)),
        Cantidad   = ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN CANTIDAD ELSE 0 END), 0),
        Descuentos = ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN DESCUENTOS ELSE 0 END), 0),
        Promos     = ISNULL(SUM(CASE WHEN ES_ANULADA = 0 AND PROMO = 1 THEN CANTIDAD ELSE 0 END), 0),
        Kilos      = ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN KILOS ELSE 0 END), 0),
        Costo      = ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN COSTO ELSE 0 END), 0),
        Utilidad   = ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN UTILIDAD ELSE 0 END), 0),
        PctUtilidad= CAST(100.0 * ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN UTILIDAD ELSE 0 END), 0)
                          / NULLIF(SUM(CASE WHEN ES_ANULADA = 0 THEN IMPORTE ELSE 0 END), 0) AS numeric(18,4)),
        ContribMarginal = ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN CONTRIB ELSE 0 END), 0),
        PctContrib = CAST(100.0 * ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN CONTRIB ELSE 0 END), 0)
                          / NULLIF(SUM(CASE WHEN ES_ANULADA = 0 THEN IMPORTE ELSE 0 END), 0) AS numeric(18,4))
    FROM #U
    GROUP BY ARTICULO, ART_DESCRIP
    ORDER BY 3 DESC;

    /* 5) Por promocion.

          "Cantidad" cuenta APLICACIONES de la promo, no unidades vendidas,
          que es como lo presenta SmartFran: un 2x1 que se llevo 18 kilos
          figura como 9. El divisor sale de DIM_PROMO_APLICACION.

          Se divide POR ID de promocion y recien despues se agrupa por
          nombre: hay promos distintas con el mismo texto (3572 y 3586 son
          las dos "2x1 en Kilo de Lunes a Jueves") y cada una puede tener su
          propia composicion.

          Si no hay divisor, o es absurdo, se cae a contar unidades. Pasa:
          la promo 611 tiene cargado 6500 en PROCANTIDAD, que es un precio
          mal puesto en el maestro de origen. Sin el tope, esa fila daria
          cero aplicaciones. */
    ;WITH por_promo AS (
        SELECT u.PROMOCION,
               u.PROMO_DESCRIP,
               IMPORTE    = SUM(CASE WHEN u.ES_ANULADA = 0 THEN u.IMPORTE ELSE 0 END),
               UNIDADES   = SUM(CASE WHEN u.ES_ANULADA = 0 THEN u.CANTIDAD ELSE 0 END),
               DESCUENTOS = SUM(CASE WHEN u.ES_ANULADA = 0 THEN u.DESCUENTOS ELSE 0 END),
               DIVISOR    = MAX(CASE WHEN d.UNID_POR_APLIC BETWEEN 1 AND 100
                                     THEN d.UNID_POR_APLIC ELSE 1 END)
        FROM #U u
        LEFT JOIN dbo.DIM_PROMO_APLICACION d
               ON d.BASE_ORIGEN = @BaseOrigen AND d.PROMOCION = u.PROMOCION
        WHERE u.ES_PROMO = 1
        GROUP BY u.PROMOCION, u.PROMO_DESCRIP
    )
    SELECT
        Detalle    = PROMO_DESCRIP,
        Venta      = SUM(IMPORTE),
        Porcentaje = CAST(100.0 * SUM(IMPORTE) / NULLIF(@ventaTotal, 0) AS numeric(18,4)),
        Cantidad   = SUM(CAST(ROUND(UNIDADES / DIVISOR, 0) AS numeric(18,4))),
        Descuentos = SUM(DESCUENTOS)
    FROM por_promo
    GROUP BY PROMO_DESCRIP
    ORDER BY 2 DESC;

    /* 6) Por sobreventa.

          Una sobreventa deja DOS lineas en el mismo ticket: la de la campana
          (grupo SOBREVENTA, importe 0, que es el nombre que muestra
          SmartFran: "2026 Sv 1/4 Kilo") y la del articulo que efectivamente
          se llevo (importe real, "1/4 KILO"). Se agrupa por la campana y se
          suma la plata del articulo, que es como lo presenta SmartFran.
          Agrupar por el articulo daria los mismos importes con otro rotulo. */
    ;WITH campana AS (
        SELECT TICKET_KEY, MAX(ART_DESCRIP) AS NOMBRE
        FROM #U
        WHERE ES_SOBREVENTA = 1 AND GRUPO_DESCRIP = 'SOBREVENTA'
        GROUP BY TICKET_KEY
    )
    SELECT
        Detalle    = ISNULL(c.NOMBRE, u.ART_DESCRIP),
        Venta      = ISNULL(SUM(CASE WHEN u.ES_ANULADA = 0 THEN u.IMPORTE ELSE 0 END), 0),
        Porcentaje = CAST(100.0 * ISNULL(SUM(CASE WHEN u.ES_ANULADA = 0 THEN u.IMPORTE ELSE 0 END), 0)
                          / NULLIF(@ventaTotal, 0) AS numeric(18,4)),
        Cantidad   = ISNULL(SUM(CASE WHEN u.ES_ANULADA = 0 THEN u.CANTIDAD ELSE 0 END), 0),
        Kilos      = ISNULL(SUM(CASE WHEN u.ES_ANULADA = 0 THEN u.KILOS ELSE 0 END), 0)
    FROM #U u
    LEFT JOIN campana c ON c.TICKET_KEY = u.TICKET_KEY
    WHERE u.ES_SOBREVENTA = 1
      AND u.GRUPO_DESCRIP <> 'SOBREVENTA'   -- se excluye la linea marcadora
    GROUP BY ISNULL(c.NOMBRE, u.ART_DESCRIP)
    ORDER BY 2 DESC;

    /* 7) Historia por dia */
    SELECT
        Dia      = DIA,
        Venta    = ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN IMPORTE ELSE 0 END), 0),
        Tickets  = COUNT(DISTINCT CASE WHEN ES_ANULADA = 0 THEN TICKET_KEY END),
        Kilos    = ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN KILOS ELSE 0 END), 0),
        Utilidad = ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN UTILIDAD ELSE 0 END), 0),
        ContribMarginal = ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN CONTRIB ELSE 0 END), 0)
    FROM #U
    GROUP BY DIA
    ORDER BY DIA;

    /* 8) Distribuciones. Van en un solo conjunto con un discriminador para no
          devolver cuatro result sets casi identicos. */
    SELECT Tipo = 'HORA',
           Orden = CAST(HORA AS int),
           Clave = RIGHT('0' + CAST(HORA AS varchar(2)), 2) + ':00',
           Venta = ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN IMPORTE ELSE 0 END), 0),
           Tickets = COUNT(DISTINCT CASE WHEN ES_ANULADA = 0 THEN TICKET_KEY END)
    FROM #U GROUP BY HORA
    UNION ALL
    SELECT 'DIASEMANA', DIA_SEMANA,
           CHOOSE(DIA_SEMANA, 'Lun', 'Mar', 'Mie', 'Jue', 'Vie', 'Sab', 'Dom'),
           ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN IMPORTE ELSE 0 END), 0),
           COUNT(DISTINCT CASE WHEN ES_ANULADA = 0 THEN TICKET_KEY END)
    FROM #U GROUP BY DIA_SEMANA
    UNION ALL
    SELECT 'MES', MES,
           CHOOSE(MES, 'Ene','Feb','Mar','Abr','May','Jun','Jul','Ago','Sep','Oct','Nov','Dic'),
           ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN IMPORTE ELSE 0 END), 0),
           COUNT(DISTINCT CASE WHEN ES_ANULADA = 0 THEN TICKET_KEY END)
    FROM #U GROUP BY MES
    UNION ALL
    SELECT 'CANAL', 0, CANAL_DESCRIP,
           ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN IMPORTE ELSE 0 END), 0),
           COUNT(DISTINCT CASE WHEN ES_ANULADA = 0 THEN TICKET_KEY END)
    FROM #U GROUP BY CANAL_DESCRIP
    UNION ALL
    SELECT 'ENTREGA', 0, ENTREGA,
           ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN IMPORTE ELSE 0 END), 0),
           COUNT(DISTINCT CASE WHEN ES_ANULADA = 0 THEN TICKET_KEY END)
    FROM #U GROUP BY ENTREGA
    ORDER BY Tipo, Orden, Clave;

    /* =======================================================================
       9) Mapa de calor: hora contra dia de la semana.

          Se devuelve la grilla COMPLETA (7 x 24) aunque una celda no tenga
          venta. Si se devolvieran solo las celdas con movimiento, el frente
          tendria que inventar las faltantes y las horas sin actividad se
          leerian como huecos en vez de como ceros.
       ======================================================================= */
    ;WITH dias AS (SELECT n FROM (VALUES (1),(2),(3),(4),(5),(6),(7)) d(n)),
          horas AS (SELECT n FROM (VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9),
                                          (10),(11),(12),(13),(14),(15),(16),(17),
                                          (18),(19),(20),(21),(22),(23)) h(n))
    SELECT
        DiaSemana = d.n,
        Hora      = h.n,
        Venta     = ISNULL(SUM(CASE WHEN u.ES_ANULADA = 0 THEN u.IMPORTE ELSE 0 END), 0),
        Kilos     = ISNULL(SUM(CASE WHEN u.ES_ANULADA = 0 THEN u.KILOS ELSE 0 END), 0),
        Tickets   = COUNT(DISTINCT CASE WHEN u.ES_ANULADA = 0 THEN u.TICKET_KEY END)
    FROM dias d
    CROSS JOIN horas h
    LEFT JOIN #U u ON u.DIA_SEMANA = d.n AND u.HORA = h.n
    GROUP BY d.n, h.n
    ORDER BY d.n, h.n;

    /* =======================================================================
       10 y 11) Clima: la venta contra la temperatura.

       La temperatura se agrupa en franjas de 2 grados. Grado por grado da
       treinta y pico de filas con muy poco en cada una y el mapa se vuelve
       ruido; de a 2 quedan unas 18 franjas, que es lo que se puede leer de un
       vistazo. El rotulo lo arma el frente con el numero de la franja.

       Se devuelven DOS cortes en vez de uno de temperatura x dia x hora: ese
       serian 3.360 combinaciones para mostrar dos vistas de 140 y 480. Se
       manda lo que se dibuja.

       Solo entran las lineas que tienen clima: mezclar las que no lo tienen
       en una franja "sin dato" invitaria a leerla como si fuera una
       temperatura mas.
       ======================================================================= */
    DECLARE @FRANJA int = 2;

    -- 10) Temperatura contra dia de la semana
    SELECT
        Franja    = CAST(FLOOR(TEMPERATURA / @FRANJA) * @FRANJA AS int),
        DiaSemana = DIA_SEMANA,
        Venta     = ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN IMPORTE ELSE 0 END), 0),
        Kilos     = ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN KILOS ELSE 0 END), 0),
        Tickets   = COUNT(DISTINCT CASE WHEN ES_ANULADA = 0 THEN TICKET_KEY END)
    FROM #U
    WHERE TEMPERATURA IS NOT NULL
    GROUP BY CAST(FLOOR(TEMPERATURA / @FRANJA) * @FRANJA AS int), DIA_SEMANA
    ORDER BY 1, 2;

    -- 11) Temperatura contra hora
    SELECT
        Franja  = CAST(FLOOR(TEMPERATURA / @FRANJA) * @FRANJA AS int),
        Hora    = HORA,
        Venta   = ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN IMPORTE ELSE 0 END), 0),
        Kilos   = ISNULL(SUM(CASE WHEN ES_ANULADA = 0 THEN KILOS ELSE 0 END), 0),
        Tickets = COUNT(DISTINCT CASE WHEN ES_ANULADA = 0 THEN TICKET_KEY END)
    FROM #U
    WHERE TEMPERATURA IS NOT NULL
    GROUP BY CAST(FLOOR(TEMPERATURA / @FRANJA) * @FRANJA AS int), HORA
    ORDER BY 1, 2;

    /* =======================================================================
       12) Promocion contra temperatura.

       Para entender que promo rinde con calor y cual con frio. Van las
       promociones en filas porque los nombres son largos y no entran como
       encabezado de columna.

       Se acotan a las 25 de mayor venta: en un periodo largo hay cientos y
       la mayoria aporta una o dos aplicaciones, que como fila de mapa es
       ruido. Las que quedan afuera igual estan en la grilla de Promociones.
       ======================================================================= */
    ;WITH top_promos AS (
        SELECT TOP 25 PROMOCION, PROMO_DESCRIP
        FROM #U
        WHERE ES_PROMO = 1 AND ES_ANULADA = 0
        GROUP BY PROMOCION, PROMO_DESCRIP
        ORDER BY SUM(IMPORTE) DESC
    )
    SELECT
        Promocion = t.PROMOCION,
        Detalle   = t.PROMO_DESCRIP,
        Franja    = CAST(FLOOR(u.TEMPERATURA / @FRANJA) * @FRANJA AS int),
        Venta     = ISNULL(SUM(CASE WHEN u.ES_ANULADA = 0 THEN u.IMPORTE ELSE 0 END), 0),
        Kilos     = ISNULL(SUM(CASE WHEN u.ES_ANULADA = 0 THEN u.KILOS ELSE 0 END), 0),
        Tickets   = COUNT(DISTINCT CASE WHEN u.ES_ANULADA = 0 THEN u.TICKET_KEY END)
    FROM #U u
    JOIN top_promos t ON t.PROMOCION = u.PROMOCION
    WHERE u.ES_PROMO = 1 AND u.TEMPERATURA IS NOT NULL
    GROUP BY t.PROMOCION, t.PROMO_DESCRIP,
             CAST(FLOOR(u.TEMPERATURA / @FRANJA) * @FRANJA AS int)
    ORDER BY t.PROMO_DESCRIP, 3;

    DROP TABLE #U;
END
GO
