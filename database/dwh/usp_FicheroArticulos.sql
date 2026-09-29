/* ===========================================================================
   Fichero de Articulos: consulta de solo lectura del maestro.

   Replica la pantalla homonima de SmartFran para poder mirar la ficha de un
   articulo sin entrar al sistema de gestion. NO edita: son datos de consulta.

   Lee de la base de origen por nombre de tres partes armado en tiempo de
   ejecucion, para no atar el SP a una sucursal concreta.

   LA RECETA VIVE EN COLUMNAS, NO EN UNA TABLA
   -------------------------------------------
   El maestro guarda hasta diez componentes en pares de columnas: del 1 al 3
   son GENERICOS (categorias como HELADO, que despues se resuelven contra el
   sabor concreto) y del 4 al 10 son ARTICULOS puntuales (el termico, la
   servilleta, la cuchara). Por eso el desarmado es un UNPIVOT a mano con
   CROSS APPLY y no un simple join.
   =========================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_FicheroArticulos
    @Buscar      varchar(60)  = NULL,   -- por descripcion o por codigo
    @Tipo        varchar(20)  = NULL,
    @Grupo       int          = NULL,
    @SoloActivos bit          = 1,
    @Top         int          = 300,
    @BaseOrigen  varchar(30)  = 'SRV_GRIDO_ZSUR'
AS
BEGIN
    SET NOCOUNT ON;
    SET @Top = CASE WHEN @Top BETWEEN 1 AND 5000 THEN @Top ELSE 300 END;

    DECLARE @sql nvarchar(max) = N'
    SELECT TOP (@top)
        Articulo    = a.ARTICULO,
        Codigo      = RTRIM(a.ARTCODIGO),
        Descripcion = RTRIM(a.ARTDESCRIP),
        Tipo        = RTRIM(a.ARTTIPO),
        Grupo       = a.GRUPO,
        GrupoDescrip= RTRIM(g.GRUDESCRIP),
        Estado      = RTRIM(a.ARTESTADO),
        Precio      = a.ARTPRECIONORMAL1,
        Costo       = a.ARTCOSTO,
        UnidXBulto  = a.ARTUNIDXBULTO,
        Peso        = a.ARTPESO,
        -- El mapeo a SAP viaja en el listado para poder ver de un vistazo que
        -- falta cargar, sin abrir ficha por ficha.
        CodigoSap   = s.CODIGO_SAP
    FROM {DB}.dbo.ARTICULOS a
    LEFT JOIN {DB}.dbo.GRUPOS g ON g.GRUPO = a.GRUPO
    LEFT JOIN dbo.MAP_ARTICULO_SAP s
           ON s.BASE_ORIGEN = @base AND s.ARTICULO = a.ARTICULO AND s.ACTIVO = 1
    WHERE (@activos = 0 OR RTRIM(a.ARTESTADO) = ''ACTIVO'')
      AND (@tipo  IS NULL OR RTRIM(a.ARTTIPO) = @tipo)
      AND (@grupo IS NULL OR a.GRUPO = @grupo)
      AND (@buscar IS NULL
           OR a.ARTDESCRIP LIKE ''%'' + @buscar + ''%''
           OR a.ARTCODIGO  LIKE ''%'' + @buscar + ''%''
           OR CAST(a.ARTICULO AS varchar(20)) = @buscar)
    ORDER BY RTRIM(a.ARTDESCRIP);';

    SET @sql = REPLACE(@sql, N'{DB}', QUOTENAME(@BaseOrigen));
    EXEC sp_executesql @sql,
         N'@top int, @buscar varchar(60), @tipo varchar(20), @grupo int, @activos bit, @base varchar(30)',
         @top = @Top, @buscar = @Buscar, @tipo = @Tipo, @grupo = @Grupo,
         @activos = @SoloActivos, @base = @BaseOrigen;
END
GO


CREATE OR ALTER PROCEDURE dbo.usp_FicheroArticuloDetalle
    @Articulo   int,
    @BaseOrigen varchar(30) = 'SRV_GRIDO_ZSUR'
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @sql nvarchar(max) = N'
    -- 1) Cabecera de la ficha
    SELECT
        Articulo     = a.ARTICULO,
        Codigo       = RTRIM(a.ARTCODIGO),
        Descripcion  = RTRIM(a.ARTDESCRIP),
        DescripTicket= RTRIM(a.ARTDESCRIPTICKET),
        Tipo         = RTRIM(a.ARTTIPO),
        Estado       = RTRIM(a.ARTESTADO),
        FechaEstado  = a.ARTFECESTADO,
        Grupo        = a.GRUPO,
        GrupoDescrip = RTRIM(g.GRUDESCRIP),
        VentaPublico = RTRIM(a.ARTVENTA),
        IvaTasa      = a.IVATASA,
        Orden        = a.ARTORDEN,
        Proveedor    = a.PROVEEDOR,
        UnidXBulto   = a.ARTUNIDXBULTO,
        StockMinimo  = a.ARTSTOCKMINIMO,
        Peso         = a.ARTPESO,
        Costo        = a.ARTCOSTO,
        PrecioLista1 = a.ARTPRECIONORMAL1,
        PrecioLista2 = a.ARTPRECIONORMAL2,
        PrecioLista3 = a.ARTPRECIONORMAL3,
        PrecioGastro1= a.ARTPRECIOGASTRO1,
        PrecioGastro2= a.ARTPRECIOGASTRO2,
        PrecioGastro3= a.ARTPRECIOGASTRO3
    FROM {DB}.dbo.ARTICULOS a
    LEFT JOIN {DB}.dbo.GRUPOS g ON g.GRUPO = a.GRUPO
    WHERE a.ARTICULO = @art;

    -- 2) Receta. Los tres primeros componentes son genericos y los otros
    --    siete son articulos concretos; se los presenta en una sola lista
    --    porque en la ficha se leen igual.
    SELECT
        Orden      = c.orden,
        Clase      = c.clase,
        Componente = c.id,
        Descripcion= ISNULL(RTRIM(ga.GENDESCRIP), RTRIM(ar.ARTDESCRIP)),
        Cantidad   = c.cant,
        /* ARTCOSTO viene POR BULTO y hay que dividirlo por las unidades que
           trae. Sin eso una servilleta figura a 17.532 en vez de 8,77, que es
           el mismo error que en su momento hizo dar 41 millones de insumos
           contra 10 de venta. */
        CostoUnit  = CASE WHEN c.clase = ''ARTICULO''
                          THEN ar.ARTCOSTO / NULLIF(ar.ARTUNIDXBULTO, 0) END,
        CostoTotal = CASE WHEN c.clase = ''ARTICULO''
                          THEN ar.ARTCOSTO / NULLIF(ar.ARTUNIDXBULTO, 0) * c.cant END
    FROM {DB}.dbo.ARTICULOS a
    CROSS APPLY (VALUES
        (1,  ''GENERICO'', a.ARTCOMP1GENERICO,  a.ARTCOMP1CANT),
        (2,  ''GENERICO'', a.ARTCOMP2GENERICO,  a.ARTCOMP2CANT),
        (3,  ''GENERICO'', a.ARTCOMP3GENERICO,  a.ARTCOMP3CANT),
        (4,  ''ARTICULO'', a.ARTCOMP4ARTICULO,  a.ARTCOMP4CANT),
        (5,  ''ARTICULO'', a.ARTCOMP5ARTICULO,  a.ARTCOMP5CANT),
        (6,  ''ARTICULO'', a.ARTCOMP6ARTICULO,  a.ARTCOMP6CANT),
        (7,  ''ARTICULO'', a.ARTCOMP7ARTICULO,  a.ARTCOMP7CANT),
        (8,  ''ARTICULO'', a.ARTCOMP8ARTICULO,  a.ARTCOMP8CANT),
        (9,  ''ARTICULO'', a.ARTCOMP9ARTICULO,  a.ARTCOMP9CANT),
        (10, ''ARTICULO'', a.ARTCOMP10ARTICULO, a.ARTCOMP10CANT)
    ) c(orden, clase, id, cant)
    LEFT JOIN {DB}.dbo.GENERICOS ga ON c.clase = ''GENERICO'' AND ga.GENERICO = c.id
    LEFT JOIN {DB}.dbo.ARTICULOS ar ON c.clase = ''ARTICULO'' AND ar.ARTICULO = c.id
    WHERE a.ARTICULO = @art
      AND ISNULL(c.id, 0) <> 0          -- las ranuras vacias no son receta
    ORDER BY c.orden;';

    SET @sql = REPLACE(@sql, N'{DB}', QUOTENAME(@BaseOrigen));
    EXEC sp_executesql @sql, N'@art int', @art = @Articulo;

    /* 3) Mapeo a SAP. Va como conjunto aparte y no pegado a la cabecera
          porque puede no existir: devolver cero filas es mas claro que una
          cabecera con media docena de columnas en NULL. */
    SELECT CodigoSap      = s.CODIGO_SAP,
           DescripcionSap = s.DESCRIPCION_SAP,
           UnidadSap      = s.UNIDAD_SAP,
           FactorSap      = s.FACTOR_SAP,
           Observaciones  = s.OBSERVACIONES,
           Activo         = s.ACTIVO,
           UsuarioAlta    = s.USUARIO_ALTA,
           FechaAlta      = s.FECHA_ALTA,
           UsuarioMod     = s.USUARIO_MOD,
           FechaMod       = s.FECHA_MOD
    FROM dbo.MAP_ARTICULO_SAP s
    WHERE s.BASE_ORIGEN = @BaseOrigen AND s.ARTICULO = @Articulo;
END
GO
