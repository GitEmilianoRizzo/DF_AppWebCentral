/* ===========================================================================
   MAP_ARTICULO_SAP
   ---------------------------------------------------------------------------
   Relacion entre el articulo del sistema de gestion y el codigo SAP que usa
   Grido Central. Sirve para planificar compras por ese codigo.

   POR QUE VIVE EN EL DWH Y NO EN EL ORIGEN
   ----------------------------------------
   SRV_GRIDO_ZSUR se RESTAURA COMPLETA todos los dias a las 12:00 desde el
   backup de la casa central. Cualquier cosa que se escriba ahi se pierde a la
   mañana siguiente. Esta tabla es informacion nuestra, no de ellos, asi que
   va en DF_DTW: es lo unico que sobrevive al restore.

   MUCHOS A UNO, A PROPOSITO
   -------------------------
   La clave primaria es el articulo: cada articulo tiene UN codigo SAP. Pero
   varios articulos pueden compartirlo, que es el caso normal (los sabores de
   un mismo helado son un solo material para la compra). Por eso hay indice
   por CODIGO_SAP: la planificacion agrupa por ahi.

   FACTOR DE CONVERSION
   --------------------
   Central puede comprar en una unidad distinta de la que se consume aca (una
   caja de 6 contra la unidad suelta). FACTOR_SAP dice cuantas unidades SAP
   equivalen a una unidad local. Arranca en 1 y solo se toca cuando difieren:
   dejarlo implicito seria garantizar que en algun momento alguien pida seis
   veces de mas.
   =========================================================================== */

IF OBJECT_ID('dbo.MAP_ARTICULO_SAP', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.MAP_ARTICULO_SAP (
        BASE_ORIGEN     varchar(30)   NOT NULL,
        ARTICULO        int           NOT NULL,
        CODIGO_SAP      varchar(40)   NOT NULL,
        DESCRIPCION_SAP varchar(120)  NULL,
        UNIDAD_SAP      varchar(20)   NULL,
        FACTOR_SAP      numeric(18,6) NOT NULL CONSTRAINT DF_MAS_FACTOR DEFAULT (1),
        OBSERVACIONES   varchar(400)  NULL,
        ACTIVO          bit           NOT NULL CONSTRAINT DF_MAS_ACTIVO DEFAULT (1),
        USUARIO_ALTA    varchar(60)   NULL,
        FECHA_ALTA      datetime2(0)  NOT NULL CONSTRAINT DF_MAS_FALTA DEFAULT SYSDATETIME(),
        USUARIO_MOD     varchar(60)   NULL,
        FECHA_MOD       datetime2(0)  NULL,
        CONSTRAINT PK_MAP_ARTICULO_SAP PRIMARY KEY (BASE_ORIGEN, ARTICULO),
        CONSTRAINT CK_MAS_FACTOR CHECK (FACTOR_SAP > 0),
        CONSTRAINT CK_MAS_CODIGO CHECK (LEN(LTRIM(RTRIM(CODIGO_SAP))) > 0)
    );

    -- La planificacion agrupa por codigo SAP, no por articulo.
    CREATE NONCLUSTERED INDEX IX_MAP_SAP_CODIGO
        ON dbo.MAP_ARTICULO_SAP (BASE_ORIGEN, CODIGO_SAP) INCLUDE (ARTICULO, FACTOR_SAP);

    PRINT 'MAP_ARTICULO_SAP creada.';
END
ELSE
    PRINT 'MAP_ARTICULO_SAP ya existia: no se toca.';
GO


/* ---------------------------------------------------------------------------
   Alta y modificacion en una sola operacion.

   Es un MERGE y no un INSERT/UPDATE separados porque quien edita no sabe ni
   tiene por que saber si el articulo ya tenia mapeo: aprieta guardar y listo.
   Se conserva quien lo dio de alta la primera vez.
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GuardarArticuloSap
    @Articulo        int,
    @CodigoSap       varchar(40),
    @DescripcionSap  varchar(120) = NULL,
    @UnidadSap       varchar(20)  = NULL,
    @FactorSap       numeric(18,6) = 1,
    @Observaciones   varchar(400) = NULL,
    @Activo          bit          = 1,
    @Usuario         varchar(60)  = NULL,
    @BaseOrigen      varchar(30)  = 'SRV_GRIDO_ZSUR'
AS
BEGIN
    SET NOCOUNT ON;

    SET @CodigoSap = LTRIM(RTRIM(@CodigoSap));
    IF @CodigoSap = '' OR @CodigoSap IS NULL
    BEGIN
        RAISERROR('El codigo SAP no puede quedar vacio.', 16, 1);
        RETURN;
    END
    IF @FactorSap IS NULL OR @FactorSap <= 0
    BEGIN
        RAISERROR('El factor de conversion tiene que ser mayor que cero.', 16, 1);
        RETURN;
    END

    MERGE dbo.MAP_ARTICULO_SAP AS destino
    USING (SELECT @BaseOrigen AS BASE_ORIGEN, @Articulo AS ARTICULO) AS origen
        ON destino.BASE_ORIGEN = origen.BASE_ORIGEN
       AND destino.ARTICULO    = origen.ARTICULO
    WHEN MATCHED THEN UPDATE SET
        CODIGO_SAP      = @CodigoSap,
        DESCRIPCION_SAP = @DescripcionSap,
        UNIDAD_SAP      = @UnidadSap,
        FACTOR_SAP      = @FactorSap,
        OBSERVACIONES   = @Observaciones,
        ACTIVO          = @Activo,
        USUARIO_MOD     = @Usuario,
        FECHA_MOD       = SYSDATETIME()
    WHEN NOT MATCHED THEN INSERT
        (BASE_ORIGEN, ARTICULO, CODIGO_SAP, DESCRIPCION_SAP, UNIDAD_SAP,
         FACTOR_SAP, OBSERVACIONES, ACTIVO, USUARIO_ALTA)
        VALUES
        (@BaseOrigen, @Articulo, @CodigoSap, @DescripcionSap, @UnidadSap,
         @FactorSap, @Observaciones, @Activo, @Usuario);

    /* Los alias van en PascalCase porque Dapper NO ignora los guiones bajos:
       devolver CODIGO_SAP deja la propiedad CodigoSap en null y el guardado
       parece no haber hecho nada. Ya paso con el Informe Diario. */
    SELECT CodigoSap      = CODIGO_SAP,
           DescripcionSap = DESCRIPCION_SAP,
           UnidadSap      = UNIDAD_SAP,
           FactorSap      = FACTOR_SAP,
           Observaciones  = OBSERVACIONES,
           Activo         = ACTIVO,
           UsuarioAlta    = USUARIO_ALTA,
           FechaAlta      = FECHA_ALTA,
           UsuarioMod     = USUARIO_MOD,
           FechaMod       = FECHA_MOD
    FROM dbo.MAP_ARTICULO_SAP
    WHERE BASE_ORIGEN = @BaseOrigen AND ARTICULO = @Articulo;
END
GO


CREATE OR ALTER PROCEDURE dbo.usp_BorrarArticuloSap
    @Articulo   int,
    @BaseOrigen varchar(30) = 'SRV_GRIDO_ZSUR'
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM dbo.MAP_ARTICULO_SAP
    WHERE BASE_ORIGEN = @BaseOrigen AND ARTICULO = @Articulo;
    SELECT Borradas = @@ROWCOUNT;
END
GO
