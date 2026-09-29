/* ===========================================================================
   DF_DTW.dbo.usp_VentasSmartFran
   ---------------------------------------------------------------------------
   DISPARADOR de la explosion de ventas por item contra UNA O VARIAS bases
   GRIDO, replicando la semantica de la "Estadistica de Ventas por Sucursal"
   de SmartFran.

   POR QUE EXISTE
   --------------
   La verdad de negocio la define SmartFran. El trace de Profiler
   C:\PILL-DF\SQL\DF_DTW\estadventasucursales.trc muestra que esa pantalla
   ejecuta <base>.dbo.estadventas. Este SP NO inventa una interpretacion
   propia: traduce esa logica a una consulta parametrizada por base, para
   poder correrla desde el DTW contra cada base productiva y apilar los
   resultados con una columna de origen.

   POR QUE NO LLAMA DIRECTO A estadventas
   --------------------------------------
   1. estadventas no recibe las sucursales por parametro: las lee de
      MULTI_SELECT_SUCURSAL filtrando por @pc, o sea de la seleccion que el
      usuario dejo en la pantalla. Llamarlo obligaria a ESCRIBIR en la base
      productiva antes de cada lectura.
   2. Devuelve 15 result sets; INSERT ... EXEC solo captura el primero.
   3. Devuelve totales ya agregados. El DTW necesita el grano de item para
      poder cortar por otras dimensiones.
   Se replica la logica y se controla la paridad con estadventas mediante
   C:\PILL-DF\SQL\DF_DTW\control_vs_smartfran.py

   EQUIVALENCIAS CON estadventas (verificadas, ver notas al pie)
   ------------------------------------------------------------
     importe     = SUM(cant*precio)            -> columna IMPORTE
     cantidad    = SUM(cant)                   -> CANTIDAD
     descuentos  = SUM(cant*descuento)         -> DESCUENTOS
     costo       = SUM(cant*costo)             -> COSTO
     utilidad    = SUM(cant*(precio-costo))    -> UTILIDAD
     kilos       = SUM(cant*ISNULL(peso,0))    -> KILOS
     tickets     = filas de #ventas            -> COUNT(DISTINCT TICKET_KEY)

   Creado: 2026-09-04
   =========================================================================== */

USE DF_DTW;
GO

IF OBJECT_ID('dbo.usp_VentasSmartFran', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_VentasSmartFran;
GO

CREATE PROCEDURE dbo.usp_VentasSmartFran
    /* Lista CSV de bases GRIDO a leer. Es el corazon del disparador: una sola
       llamada recorre todas y apila el resultado con la columna BASE_LECTURA.
       Cada nombre se valida contra sys.databases y se encierra con QUOTENAME. */
    @BasesLectura   varchar(4000) = 'SRV_GRIDO_ZSUR',

    /* estadventas usa "vtafecha BETWEEN @desde AND @hasta", o sea INCLUSIVO en
       los dos extremos. Se replica tal cual para no desviarse de SmartFran.
       OJO al encadenar periodos: una venta que caiga justo en el limite entra
       en los dos. Ver nota 3 al pie. */
    @FechaDesde     datetime,
    @FechaHasta     datetime,

    /* CSV de ids de sucursal. NULL = todas las de cada base.
       Reemplaza a MULTI_SELECT_SUCURSAL, que en SmartFran es la seleccion de
       pantalla guardada por PC y no sirve para un proceso desatendido. */
    @Sucursales     varchar(200)  = NULL,

    -- ---- filtros de estadventas, con los mismos codigos y defaults ----
    @Lugar          int           = 99,        -- 99 todos / 0 salon / 1 delivery
    @Canal          int           = 0,         -- 0 todos /1 Minorista+CG /2 Mayorista /3 Club Grido /4 Canjes /5 solo Minorista
    @TipoProducto   int           = 0,         -- 0 todos / 1 ELABORADO / 2 resto
    @Grupo          int           = 0,         -- 0 todos, o id de GRUPOS
    @Articulo       int           = 0,         -- 0 todos, o id de ARTICULOS
    @TipoVenta      int           = 0,         -- 0 todos / 1 normal / 2 promocion / 3 sobreventa
    @Cliente        int           = 0,         -- 0 todos, o id de CLIENTES
    @Cajero         varchar(20)   = 'TODOS',
    @HoraDesde      char(4)       = '0000',
    @HoraHasta      char(4)       = '2400',
    @DiasSemana     char(7)       = '1111111', -- lunes..domingo, 1 = incluir
    @Feriados       tinyint       = 1,         -- 1 = los feriados entran siempre
    @CanalComercial int           = 0,
    @Plataforma     int           = 0,         -- 0 = sin filtro de entidad generadora

    /* ITEM     = una fila por linea de ticket (default, es el grano del DTW)
       SUCURSAL = el mismo corte que muestra la pantalla de SmartFran */
    @Nivel          varchar(12)   = 'ITEM',

    /* estadventas mide siempre con promo<>2. Dejarlo en 0 garantiza que
       cualquier agregacion del resultado reproduzca a SmartFran. Ponerlo en 1
       trae tambien esas lineas, solo para inspeccion. */
    @IncluirPromo2  bit           = 0,

    @Debug          bit           = 0
AS
BEGIN
    SET NOCOUNT ON;
    -- estadventas hace "set datefirst 1" para que el lunes sea el dia 1.
    -- Sin esto, @DiasSemana quedaria corrido y filtraria los dias equivocados.
    SET DATEFIRST 1;

    -- =======================================================================
    -- VALIDACION
    -- =======================================================================
    IF @FechaDesde IS NULL OR @FechaHasta IS NULL
    BEGIN
        RAISERROR('usp_VentasSmartFran: @FechaDesde y @FechaHasta son obligatorios.', 16, 1);
        RETURN;
    END

    IF @FechaDesde > @FechaHasta
    BEGIN
        DECLARE @d1 varchar(30) = CONVERT(varchar(30), @FechaDesde, 120),
                @d2 varchar(30) = CONVERT(varchar(30), @FechaHasta, 120);
        RAISERROR('usp_VentasSmartFran: @FechaDesde (%s) no puede ser posterior a @FechaHasta (%s).',
                  16, 1, @d1, @d2);
        RETURN;
    END

    IF @Nivel IS NULL OR UPPER(@Nivel) NOT IN ('ITEM', 'SUCURSAL')
    BEGIN
        RAISERROR('usp_VentasSmartFran: @Nivel debe ser ITEM o SUCURSAL.', 16, 1);
        RETURN;
    END
    SET @Nivel = UPPER(@Nivel);

    IF @Sucursales LIKE '%[^0-9, ]%'
    BEGIN
        RAISERROR('usp_VentasSmartFran: @Sucursales solo acepta enteros separados por coma.', 16, 1);
        RETURN;
    END
    IF LTRIM(RTRIM(ISNULL(@Sucursales, ''))) IN ('', ',') SET @Sucursales = NULL;

    IF @DiasSemana IS NULL OR LEN(@DiasSemana) <> 7 OR @DiasSemana LIKE '%[^01]%'
    BEGIN
        RAISERROR('usp_VentasSmartFran: @DiasSemana debe ser 7 caracteres 0/1 (lunes a domingo).', 16, 1);
        RETURN;
    END

    IF @HoraDesde LIKE '%[^0-9]%' OR @HoraHasta LIKE '%[^0-9]%'
        OR LEN(@HoraDesde) <> 4 OR LEN(@HoraHasta) <> 4
    BEGIN
        RAISERROR('usp_VentasSmartFran: @HoraDesde/@HoraHasta deben ser 4 digitos, formato HHMM.', 16, 1);
        RETURN;
    END

    -- =======================================================================
    -- BASES A RECORRER
    -- =======================================================================
    DECLARE @bases TABLE (orden int IDENTITY(1,1), base sysname);

    INSERT @bases (base)
    SELECT LTRIM(RTRIM(value))
    FROM STRING_SPLIT(@BasesLectura, ',')
    WHERE LTRIM(RTRIM(value)) <> '';

    IF NOT EXISTS (SELECT 1 FROM @bases)
    BEGIN
        RAISERROR('usp_VentasSmartFran: @BasesLectura no trae ninguna base.', 16, 1);
        RETURN;
    END

    -- Se validan TODAS antes de leer ninguna: es preferible fallar de entrada a
    -- devolver un resultado a medias que despues alguien suma como si estuviera
    -- completo.
    DECLARE @mala sysname;
    SELECT TOP 1 @mala = b.base
    FROM @bases b
    WHERE NOT EXISTS (SELECT 1 FROM sys.databases d WHERE d.name = b.base AND d.state = 0);

    IF @mala IS NOT NULL
    BEGIN
        RAISERROR('usp_VentasSmartFran: la base "%s" no existe en este servidor o no esta ONLINE.',
                  16, 1, @mala);
        RETURN;
    END

    -- Que la base exista no alcanza: tiene que ser una base GRIDO. Sin este
    -- chequeo, apuntar a una base cualquiera revienta recien a mitad del
    -- recorrido con "Invalid object name 'x.dbo.VENTAS'", que no le dice nada
    -- a quien se equivoco tipeando el nombre.
    DECLARE @chkBase sysname, @chkSql nvarchar(max), @chkCant int;
    DECLARE chk_cur CURSOR LOCAL FAST_FORWARD FOR SELECT base FROM @bases ORDER BY orden;
    OPEN chk_cur;
    FETCH NEXT FROM chk_cur INTO @chkBase;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @chkSql = N'SELECT @cant = COUNT(*) FROM ' + QUOTENAME(@chkBase) + N'.sys.tables
                        WHERE name IN (''VENTAS'', ''DETVENTAS'', ''ARTICULOS'',
                                       ''ARTICULOSHISTORICO'', ''SUCURSALES'', ''GRUPOS'', ''CANALES'')';
        EXEC sp_executesql @chkSql, N'@cant int OUTPUT', @cant = @chkCant OUTPUT;

        IF ISNULL(@chkCant, 0) < 7
        BEGIN
            CLOSE chk_cur; DEALLOCATE chk_cur;
            RAISERROR('usp_VentasSmartFran: la base "%s" no parece una base GRIDO/SmartFran: le faltan tablas de las 7 requeridas (VENTAS, DETVENTAS, ARTICULOS, ARTICULOSHISTORICO, SUCURSALES, GRUPOS, CANALES). Encontradas: %d.',
                      16, 1, @chkBase, @chkCant);
            RETURN;
        END

        FETCH NEXT FROM chk_cur INTO @chkBase;
    END
    CLOSE chk_cur;
    DEALLOCATE chk_cur;

    -- =======================================================================
    -- DESTINO
    -- =======================================================================
    CREATE TABLE #ITEMS (
        BASE_LECTURA        sysname,
        SUCURSAL            int,
        SUCURSAL_CODIGO     varchar(10),
        SUCURSAL_DESCRIP    varchar(30),
        VENTA               int,
        CAJA                int,
        TURNO               int,
        DETVENTA            int,
        TICKET_KEY          varchar(60),
        USULOGIN            varchar(20),
        VTAFECHA            datetime,
        FECHA               date,
        HORA                int,
        DIASEMANA           int,
        MES                 int,
        PERIODO             varchar(10),
        VTAESTADO           varchar(10),
        VTAOPERACION        varchar(2),
        VTADELIVERY         bit,
        SOBREVENTA          varchar(10),
        CANALVTA            char(1),
        CANALCOMERCIAL      int,
        CLIENTE             int,
        VTAIMPORTE          numeric(16,4),
        ARTICULO            int,
        DESCRIP             varchar(30),
        ARTTIPO             varchar(10),
        GRUPO               int,
        GRUDESCRIP          varchar(20),
        PROMOCION           int,
        PROMO               tinyint,
        CANT                numeric(16,4),
        PRECIO              numeric(16,4),
        DESCUENTO           numeric(16,4),
        COSTO_UNIT          numeric(16,4),
        PESO                numeric(16,4),
        -- medidas ya resueltas con la formula de estadventas
        CANTIDAD            numeric(28,8),
        IMPORTE             numeric(28,8),
        DESCUENTOS          numeric(28,8),
        COSTO               numeric(28,8),
        UTILIDAD            numeric(28,8),
        KILOS               numeric(28,8)
    );

    -- =======================================================================
    -- FILTROS COMPARTIDOS
    -- Se arman una sola vez y se reusan en las dos mitades de la consulta:
    -- los de cabecera van al filtro de ventas que califican, los de linea a
    -- las dos (asi una venta califica por la misma linea que despues se mide).
    -- =======================================================================
    DECLARE @fCab nvarchar(max) = N'', @fLin nvarchar(max) = N'';

    IF @Lugar <> 99
        SET @fCab += N'
       AND ISNULL(v.VTADELIVERY, 0) = @pLugar';

    IF @Cliente <> 0
        SET @fCab += N'
       AND v.CLIENTE = @pCliente';

    IF @Cajero <> 'TODOS'
        SET @fCab += N'
       AND v.USULOGIN = @pCajero';

    -- Filtro horario tal cual lo escribe estadventas: compara hora y minuto por
    -- separado, no el datetime completo.
    IF @HoraDesde <> '0000'
        SET @fCab += N'
       AND (DATEPART(hour, v.VTAFECHA) > CONVERT(int, LEFT(@pHoraDesde, 2))
        OR (DATEPART(hour, v.VTAFECHA) = CONVERT(int, LEFT(@pHoraDesde, 2))
            AND DATEPART(minute, v.VTAFECHA) >= CONVERT(int, RIGHT(@pHoraDesde, 2))))';

    IF @HoraHasta <> '2400'
        SET @fCab += N'
       AND (DATEPART(hour, v.VTAFECHA) < CONVERT(int, LEFT(@pHoraHasta, 2))
        OR (DATEPART(hour, v.VTAFECHA) = CONVERT(int, LEFT(@pHoraHasta, 2))
            AND DATEPART(minute, v.VTAFECHA) <= CONVERT(int, RIGHT(@pHoraHasta, 2))))';

    IF @Sucursales IS NOT NULL
        SET @fCab += N'
       AND v.SUCURSAL IN (' + @Sucursales + N')';

    -- Dias de la semana / feriados.
    -- estadventas lo resuelve con dos tandas de DELETE sobre #ventas; el neto
    -- es: con @feriados=0 se conservan solo los dias marcados, y con
    -- @feriados=1 los feriados entran aunque su dia este desmarcado.
    IF @DiasSemana <> '1111111'
    BEGIN
        DECLARE @dias varchar(30) = '';
        DECLARE @n int = 1;
        WHILE @n <= 7
        BEGIN
            IF SUBSTRING(@DiasSemana, @n, 1) = '1'
                SET @dias += CASE WHEN @dias = '' THEN '' ELSE ',' END + CAST(@n AS varchar(2));
            SET @n += 1;
        END
        IF @dias = '' SET @dias = '-1';   -- ningun dia marcado: no devuelve nada

        SET @fCab += N'
       AND (DATEPART(weekday, v.VTAFECHA) IN (' + @dias + N')';
        IF @Feriados = 1
            SET @fCab += N'
            OR EXISTS (SELECT 1 FROM {DB}.dbo.FERIADOS f
                       WHERE CONVERT(char(8), f.FERIADO, 112) = CONVERT(char(8), v.VTAFECHA, 112))';
        SET @fCab += N')';
    END

    -- Canal de venta: estadventas lo deriva de VTAOPERACION y despues borra lo
    -- que no coincide. Aca va como predicado sobre la misma expresion.
    IF @Canal <> 0
    BEGIN
        DECLARE @canales varchar(20) =
            CASE @Canal WHEN 1 THEN '''M'',''L'''
                        WHEN 2 THEN '''G'''
                        WHEN 3 THEN '''L'''
                        WHEN 4 THEN '''C'''
                        WHEN 5 THEN '''M'''
                        ELSE NULL END;
        IF @canales IS NULL
        BEGIN
            RAISERROR('usp_VentasSmartFran: @Canal debe ser 0, 1, 2, 3, 4 o 5.', 16, 1);
            RETURN;
        END
        SET @fCab += N'
       AND (CASE WHEN v.VTAOPERACION = ''VF'' THEN ''M''
                 WHEN v.VTAOPERACION = ''VC'' THEN ''M''
                 WHEN v.VTAOPERACION = ''VG'' THEN ''G''
                 WHEN v.VTAOPERACION = ''VL'' THEN ''L''
                 WHEN v.VTAOPERACION = ''CL'' THEN ''C''
                 ELSE CASE WHEN v.CLIENTE = 1 THEN ''M'' ELSE ''G'' END END) IN (' + @canales + N')';
    END

    -- Canal comercial: en estadventas es un OR gigante, pero todas las ramas
    -- salvo la 1 y la 2 piden lo mismo (canal dentro del canal comercial y
    -- VTAOPERACION='VG').
    IF @CanalComercial <> 0
    BEGIN
        IF @CanalComercial = 1
            SET @fCab += N'
       AND v.VTAOPERACION IN (''VC'', ''VF'', ''VL'') AND ISNULL(v.VTADELIVERY, 0) = 0';
        ELSE IF @CanalComercial = 2
            SET @fCab += N'
       AND v.VTAOPERACION IN (''VC'', ''VF'', ''VL'') AND ISNULL(v.VTADELIVERY, 0) > 0';
        ELSE
            SET @fCab += N'
       AND v.VTACANAL IS NOT NULL
       AND v.VTAOPERACION = ''VG''
       AND v.VTACANAL IN (SELECT CANAL FROM {DB}.dbo.CANALES WHERE CANALCOMERCIAL = @pCanalComercial)';
    END

    IF @Plataforma <> 0
        SET @fCab += N'
       AND EXISTS (SELECT 1 FROM {DB}.dbo.pedidos pe
                   WHERE pe.venta = v.VENTA AND pe.sucursal = v.SUCURSAL AND pe.caja = v.CAJA
                     AND pe.idEntidadGeneradora = @pPlataforma)';

    -- ---- filtros que dependen del articulo de la linea ----
    IF @TipoProducto = 1
        SET @fLin += N'
       AND a.ARTTIPO = ''ELABORADO''';
    ELSE IF @TipoProducto = 2
        SET @fLin += N'
       AND a.ARTTIPO <> ''ELABORADO''';

    IF @TipoVenta = 1
        SET @fLin += N'
       AND ISNULL(d.PROMO, 0) = 0';
    ELSE IF @TipoVenta = 2
        SET @fLin += N'
       AND p.ARTTIPO = ''PROMOCION''';
    ELSE IF @TipoVenta = 3
        SET @fLin += N'
       AND p.ARTTIPO = ''SOBREVENTA''';

    IF @Grupo <> 0
        SET @fLin += N'
       AND a.GRUPO = @pGrupo';

    IF @Articulo <> 0
        SET @fLin += N'
       AND (d.ARTICULO = @pArticulo OR d.PROMOCION = @pArticulo)';

    -- =======================================================================
    -- LECTURA BASE POR BASE
    -- =======================================================================
    DECLARE @base sysname, @db nvarchar(300), @sql nvarchar(max),
            @params nvarchar(1000) =
                N'@pDesde datetime, @pHasta datetime, @pLugar int, @pCliente int,
                  @pCajero varchar(20), @pHoraDesde char(4), @pHoraHasta char(4),
                  @pGrupo int, @pArticulo int, @pCanalComercial int, @pPlataforma int';

    DECLARE bases_cur CURSOR LOCAL FAST_FORWARD FOR SELECT base FROM @bases ORDER BY orden;
    OPEN bases_cur;
    FETCH NEXT FROM bases_cur INTO @base;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @db = QUOTENAME(@base);

        SET @sql = N'
;WITH VQ AS (
    -- Ventas que califican. Equivale al "select distinct ... into #ventas" de
    -- estadventas: una venta entra si tiene AL MENOS UNA linea con promo<>2 que
    -- pase los filtros de articulo. Los filtros de cabecera van aca tambien.
    SELECT DISTINCT v.VENTA, v.SUCURSAL, v.CAJA
    FROM ' + @db + N'.dbo.VENTAS v
    INNER JOIN ' + @db + N'.dbo.DETVENTAS d
            ON d.VENTA = v.VENTA AND d.SUCURSAL = v.SUCURSAL AND d.CAJA = v.CAJA
    LEFT JOIN ' + @db + N'.dbo.ARTICULOS a ON a.ARTICULO = d.ARTICULO
    LEFT JOIN ' + @db + N'.dbo.ARTICULOS p ON p.ARTICULO = d.PROMOCION
    WHERE v.VTAESTADO = ''NORMAL''
      AND v.VTAFECHA BETWEEN @pDesde AND @pHasta
      AND d.PROMO <> 2' + @fCab + @fLin + N'
)
SELECT
    CAST(' + QUOTENAME(@base, '''') + N' AS sysname),
    v.SUCURSAL,
    RTRIM(s.SUCCODIGO),
    RTRIM(s.SUCDESCRIP),
    v.VENTA,
    v.CAJA,
    v.TURNO,
    d.DETVENTA,
    -- La numeracion de VENTA se reinicia por caja: el ticket es la terna, y
    -- con varias bases hay que sumarle la base.
    CAST(' + QUOTENAME(@base, '''') + N' AS varchar(30)) + ''|'' +
        CAST(v.SUCURSAL AS varchar(6)) + ''|'' + CAST(v.CAJA AS varchar(6)) + ''|'' +
        CAST(v.VENTA AS varchar(12)),
    RTRIM(v.USULOGIN),
    v.VTAFECHA,
    CAST(v.VTAFECHA AS date),
    DATEPART(hour, v.VTAFECHA),
    DATEPART(weekday, v.VTAFECHA),
    DATEPART(month, v.VTAFECHA),
    ''01/'' + SUBSTRING(CONVERT(char(8), v.VTAFECHA, 3), 4, 5),
    RTRIM(v.VTAESTADO),
    RTRIM(v.VTAOPERACION),
    v.VTADELIVERY,
    RTRIM(v.SOBREVENTA),
    CASE WHEN v.VTAOPERACION = ''VF'' THEN ''M''
         WHEN v.VTAOPERACION = ''VC'' THEN ''M''
         WHEN v.VTAOPERACION = ''VG'' THEN ''G''
         WHEN v.VTAOPERACION = ''VL'' THEN ''L''
         WHEN v.VTAOPERACION = ''CL'' THEN ''C''
         ELSE CASE WHEN v.CLIENTE = 1 THEN ''M'' ELSE ''G'' END END,
    CASE WHEN NULLIF(c.CANALCOMERCIAL, 0) IS NULL
         THEN CASE WHEN ISNULL(v.VTADELIVERY, 0) > 0 THEN 2 ELSE 1 END
         ELSE c.CANALCOMERCIAL END,
    v.CLIENTE,
    v.VTAIMPORTE,
    d.ARTICULO,
    -- Mismo texto y misma prioridad que usa estadventas: descripcion del ticket,
    -- y el literal cuando la linea no tiene articulo.
    CASE WHEN d.ARTICULO IS NULL THEN ''(Articulo indefinido)'' ELSE RTRIM(d.DESCRIP) END,
    RTRIM(a.ARTTIPO),
    a.GRUPO,
    RTRIM(g.GRUDESCRIP),
    d.PROMOCION,
    d.PROMO,
    d.CANT,
    d.PRECIO,
    d.DESCUENTO,
    d.COSTO,
    -- peso: un ELABORADO pesa lo que pesan sus componentes de helado. El tipo
    -- se toma del maestro ACTUAL (a.ARTTIPO) y los pesos de la version
    -- historica, exactamente como lo hace estadventas.
    CASE WHEN a.ARTTIPO = ''ELABORADO''
         THEN ISNULL(h.ARTCOMP1CANT, 0) + ISNULL(h.ARTCOMP2CANT, 0) + ISNULL(h.ARTCOMP3CANT, 0)
         ELSE h.ARTPESO END,
    -- ---- medidas, con las formulas de estadventas ----
    d.CANT,
    d.CANT * d.PRECIO,
    d.CANT * d.DESCUENTO,
    d.CANT * d.COSTO,
    d.CANT * (d.PRECIO - d.COSTO),
    d.CANT * ISNULL(CASE WHEN a.ARTTIPO = ''ELABORADO''
                         THEN ISNULL(h.ARTCOMP1CANT, 0) + ISNULL(h.ARTCOMP2CANT, 0) + ISNULL(h.ARTCOMP3CANT, 0)
                         ELSE h.ARTPESO END, 0)
FROM VQ
INNER JOIN ' + @db + N'.dbo.VENTAS v
        ON v.VENTA = VQ.VENTA AND v.SUCURSAL = VQ.SUCURSAL AND v.CAJA = VQ.CAJA
INNER JOIN ' + @db + N'.dbo.DETVENTAS d
        ON d.VENTA = v.VENTA AND d.SUCURSAL = v.SUCURSAL AND d.CAJA = v.CAJA
LEFT JOIN ' + @db + N'.dbo.ARTICULOS          a ON a.ARTICULO    = d.ARTICULO
LEFT JOIN ' + @db + N'.dbo.ARTICULOS          p ON p.ARTICULO    = d.PROMOCION
LEFT JOIN ' + @db + N'.dbo.ARTICULOSHISTORICO h ON h.IDHISTORICO = d.ARTVERSION
LEFT JOIN ' + @db + N'.dbo.GRUPOS             g ON g.GRUPO       = a.GRUPO
LEFT JOIN ' + @db + N'.dbo.CANALES            c ON c.CANAL       = v.VTACANAL
LEFT JOIN ' + @db + N'.dbo.SUCURSALES         s ON s.SUCURSAL    = v.SUCURSAL
WHERE 1 = 1' + @fLin + CASE WHEN @IncluirPromo2 = 1 THEN N'' ELSE N'
  AND d.PROMO <> 2' END + N';';

        SET @sql = REPLACE(@sql, N'{DB}', @db);

        IF @Debug = 1
        BEGIN
            PRINT '--- ' + @base + ' ---';
            PRINT @sql;
        END
        ELSE
        BEGIN
            INSERT #ITEMS
            EXEC sp_executesql @sql, @params,
                 @pDesde = @FechaDesde, @pHasta = @FechaHasta, @pLugar = @Lugar,
                 @pCliente = @Cliente, @pCajero = @Cajero,
                 @pHoraDesde = @HoraDesde, @pHoraHasta = @HoraHasta,
                 @pGrupo = @Grupo, @pArticulo = @Articulo,
                 @pCanalComercial = @CanalComercial, @pPlataforma = @Plataforma;
        END

        FETCH NEXT FROM bases_cur INTO @base;
    END
    CLOSE bases_cur;
    DEALLOCATE bases_cur;

    IF @Debug = 1
    BEGIN
        SELECT @fCab AS FILTRO_CABECERA, @fLin AS FILTRO_LINEA;
        RETURN;
    END

    -- =======================================================================
    -- SALIDA
    -- =======================================================================
    IF @Nivel = 'SUCURSAL'
        SELECT
            BASE_LECTURA,
            DETALLE   = SUCURSAL_DESCRIP,
            REF       = SUCURSAL_CODIGO,
            SUCURSAL,
            TICKETS   = COUNT(DISTINCT TICKET_KEY),
            CANTIDAD  = SUM(CANTIDAD),
            IMPORTE   = SUM(IMPORTE),
            DESCUENTOS= SUM(DESCUENTOS),
            KILOS     = SUM(KILOS),
            COSTO     = SUM(COSTO),
            UTILIDAD  = SUM(UTILIDAD),
            UTILIDAD_PORCENTAJE = ISNULL(SUM(UTILIDAD) / NULLIF(SUM(IMPORTE), 0), 0) * 100
        FROM #ITEMS
        GROUP BY BASE_LECTURA, SUCURSAL_DESCRIP, SUCURSAL_CODIGO, SUCURSAL
        ORDER BY BASE_LECTURA, SUCURSAL_DESCRIP;
    ELSE
        SELECT * FROM #ITEMS;
END
GO

/* ===========================================================================
   NOTAS
   ---------------------------------------------------------------------------

   1) PARIDAD VERIFICADA
      Contra estadventas de SRV_GRIDO_ZSUR, con todos los filtros en su valor
      neutro (los del trace), sobre las 7 metricas del corte por sucursal:
        - dia operativo 03/09/2026 : 3 sucursales, 0 diferencias
        - agosto 2026 completo     : 4 sucursales, 0 diferencias
      El control se reejecuta con control_vs_smartfran.py.

      Los filtros no neutros (@Canal, @TipoProducto, @TipoVenta, @Grupo,
      @Articulo, @Cliente, @Cajero, horarios, @DiasSemana, @CanalComercial,
      @Plataforma) estan traducidos de estadventas pero NO tienen control
      automatico. Antes de apoyarse en uno, conviene contrastarlo con la
      pantalla.

   2) COMO CONTAR TICKETS
      COUNT(DISTINCT TICKET_KEY). La columna ya trae base+sucursal+caja+venta
      concatenadas porque VENTA solo no es unico: la numeracion se reinicia por
      caja, y al apilar bases se repite entre bases.

   3) EL RANGO ES INCLUSIVO EN LOS DOS EXTREMOS
      Es lo que hace estadventas (BETWEEN) y por eso se replica. Consecuencia:
      si se piden dos periodos consecutivos, una venta que caiga exactamente en
      el limite se cuenta en los dos. Para dias operativos con corte 02:00 no
      hay ventas en ese instante (verificado: 0 en todo 2026), asi que hoy no
      afecta. Al encadenar periodos, restarle un minuto al @FechaHasta.

   4) EL CATALOGO SALE DEL MAESTRO ACTUAL
      GRUPO, GRUDESCRIP y el ARTTIPO que decide el peso salen de ARTICULOS, no
      de ARTICULOSHISTORICO; de la version historica solo se toman los pesos.
      Es lo que hace estadventas. Implica que una venta vieja se reexpresa con
      la estructura comercial de hoy: si un articulo cambio de nombre o de
      grupo, aparece con el actual. Es la definicion de SmartFran, no un error.

   5) MEDIDAS: USAR LAS COLUMNAS YA RESUELTAS
      CANTIDAD, IMPORTE, DESCUENTOS, COSTO, UTILIDAD y KILOS ya vienen con la
      formula de estadventas aplicada a la linea. Sumarlas reproduce la
      pantalla. Las columnas crudas (CANT, PRECIO, DESCUENTO, COSTO_UNIT, PESO)
      quedan para analisis: OJO que DESCUENTO es UNITARIO, por eso
      DESCUENTOS = CANT * DESCUENTO.

   6) EJEMPLOS
      -- una base, el corte que muestra SmartFran
      EXEC dbo.usp_VentasSmartFran
           @FechaDesde = '2026-09-03 02:00', @FechaHasta = '2026-09-04 02:00',
           @Nivel = 'SUCURSAL';

      -- varias bases de una, apiladas por BASE_LECTURA
      EXEC dbo.usp_VentasSmartFran
           @BasesLectura = 'SRV_GRIDO_ZSUR,SRV_GRIDO_NORTE',
           @FechaDesde = '2026-09-03 02:00', @FechaHasta = '2026-09-04 02:00',
           @Nivel = 'SUCURSAL';

      -- grano de item, para cortar por lo que haga falta
      EXEC dbo.usp_VentasSmartFran
           @FechaDesde = '2026-08-01', @FechaHasta = '2026-08-31 23:59',
           @Sucursales = '1,2,3';

   =========================================================================== */
