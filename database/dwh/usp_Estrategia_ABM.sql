/* ===========================================================================
   Operaciones del modulo de Estrategia que usa la pantalla.
   ===========================================================================*/

-- ---------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_ListarObjetivos
    @Estado     varchar(15) = NULL,
    @Top        int         = 50,
    @BaseOrigen varchar(30) = 'SRV_GRIDO_ZSUR'
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (@Top)
        ObjetivoId  = o.OBJETIVO_ID,
        Nombre      = o.NOMBRE,
        Metrica     = o.METRICA,
        FechaDesde  = o.FECHA_DESDE,
        FechaHasta  = o.FECHA_HASTA,
        Estado      = o.ESTADO,
        Notas       = o.NOTAS,
        CreadoPor   = o.CREADO_POR,
        CreadoEl    = o.CREADO_EL,
        AvisadoEl   = o.AVISADO_EL,
        Sucursales  = (SELECT COUNT(*) FROM dbo.ESTRATEGIA_OBJETIVO_SUCURSAL s
                       WHERE s.OBJETIVO_ID = o.OBJETIVO_ID),
        Sugerencias = (SELECT COUNT(*) FROM dbo.ESTRATEGIA_SUGERENCIA g
                       WHERE g.OBJETIVO_ID = o.OBJETIVO_ID),
        Pendientes  = (SELECT COUNT(*) FROM dbo.ESTRATEGIA_SUGERENCIA g
                       WHERE g.OBJETIVO_ID = o.OBJETIVO_ID AND g.ESTADO = 'SUGERIDA'),
        /* Dias que faltan para que cierre. Negativo = la ventana ya paso y
           el objetivo quedo abierto: es el caso que hay que ver primero. */
        DiasRestantes = DATEDIFF(day, CAST(GETDATE() AS date), o.FECHA_HASTA)
    FROM dbo.ESTRATEGIA_OBJETIVO o
    WHERE o.BASE_ORIGEN = @BaseOrigen
      AND (@Estado IS NULL OR o.ESTADO = @Estado)
    ORDER BY o.FECHA_DESDE DESC, o.OBJETIVO_ID DESC;
END
GO

-- ---------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_CrearObjetivo
    @Nombre      varchar(120),
    @Metrica     varchar(20),
    @FechaDesde  date,
    @FechaHasta  date,
    /* JSON con una entrada por sucursal:
       [{"sucursal":1,"meta":3.0,"responsable":"...","mail":"..."}]
       Va como JSON y no como tabla porque la meta puede ser distinta en cada
       sucursal, que es justamente lo que pidio el circuito. */
    @Sucursales  nvarchar(max),
    @Notas       varchar(1000) = NULL,
    @Usuario     varchar(60)   = NULL,
    @BaseOrigen  varchar(30)   = 'SRV_GRIDO_ZSUR'
AS
BEGIN
    SET NOCOUNT ON;

    IF @Metrica NOT IN ('FACTURACION','MARGEN','KILOS')
    BEGIN
        RAISERROR('La metrica tiene que ser FACTURACION, MARGEN o KILOS.', 16, 1);
        RETURN;
    END
    IF @FechaHasta < @FechaDesde
    BEGIN
        RAISERROR('La fecha de fin no puede ser anterior a la de inicio.', 16, 1);
        RETURN;
    END
    IF ISJSON(@Sucursales) <> 1
    BEGIN
        RAISERROR('La lista de sucursales no es un JSON valido.', 16, 1);
        RETURN;
    END

    BEGIN TRAN;

    INSERT dbo.ESTRATEGIA_OBJETIVO
        (BASE_ORIGEN, NOMBRE, METRICA, FECHA_DESDE, FECHA_HASTA, ESTADO, NOTAS, CREADO_POR)
    VALUES (@BaseOrigen, @Nombre, @Metrica, @FechaDesde, @FechaHasta,
            'VIGENTE', @Notas, @Usuario);

    DECLARE @id int = SCOPE_IDENTITY();

    INSERT dbo.ESTRATEGIA_OBJETIVO_SUCURSAL
        (OBJETIVO_ID, SUCURSAL, META_PCT, RESPONSABLE, MAIL)
    SELECT @id, j.sucursal, ISNULL(j.meta, 0), j.responsable, j.mail
    FROM OPENJSON(@Sucursales) WITH (
        sucursal    int          '$.sucursal',
        meta        numeric(8,2) '$.meta',
        responsable varchar(120) '$.responsable',
        mail        varchar(200) '$.mail'
    ) j;

    IF @@ROWCOUNT = 0
    BEGIN
        ROLLBACK;
        RAISERROR('Hay que indicar al menos una sucursal.', 16, 1);
        RETURN;
    END

    COMMIT;

    SELECT ObjetivoId = @id;
END
GO

-- ---------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_ObtenerObjetivo
    @ObjetivoId int
AS
BEGIN
    SET NOCOUNT ON;

    -- 1) La cabecera
    SELECT ObjetivoId = OBJETIVO_ID, Nombre = NOMBRE, Metrica = METRICA,
           FechaDesde = FECHA_DESDE, FechaHasta = FECHA_HASTA, Estado = ESTADO,
           Notas = NOTAS, CreadoPor = CREADO_POR, CreadoEl = CREADO_EL,
           AvisadoEl = AVISADO_EL,
           DiasRestantes = DATEDIFF(day, CAST(GETDATE() AS date), FECHA_HASTA)
    FROM dbo.ESTRATEGIA_OBJETIVO WHERE OBJETIVO_ID = @ObjetivoId;

    -- 2) Las metas por sucursal
    SELECT Sucursal = s.SUCURSAL, MetaPct = s.META_PCT,
           Responsable = s.RESPONSABLE, Mail = s.MAIL, Notas = s.NOTAS
    FROM dbo.ESTRATEGIA_OBJETIVO_SUCURSAL s
    WHERE s.OBJETIVO_ID = @ObjetivoId
    ORDER BY s.SUCURSAL;

    -- 3) Las sugerencias
    SELECT SugerenciaId = SUGERENCIA_ID, Sucursal = SUCURSAL, Fecha = FECHA,
           Tipo = TIPO, Titulo = TITULO, Detalle = DETALLE, Evidencia = EVIDENCIA,
           Estado = ESTADO, DecididoPor = DECIDIDO_POR, DecididoEl = DECIDIDO_EL,
           Comentario = COMENTARIO
    FROM dbo.ESTRATEGIA_SUGERENCIA
    WHERE OBJETIVO_ID = @ObjetivoId
    ORDER BY CASE TIPO WHEN 'OPERATIVO' THEN 1 WHEN 'PROMO' THEN 2
                       WHEN 'SOBREVENTA' THEN 3 ELSE 4 END,
             FECHA, SUCURSAL;
END
GO

-- ---------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_DecidirSugerencia
    @SugerenciaId int,
    @Estado       varchar(15),      -- ACEPTADA | DESCARTADA | SUGERIDA
    @Comentario   varchar(500) = NULL,
    @Usuario      varchar(60)  = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @Estado NOT IN ('ACEPTADA','DESCARTADA','SUGERIDA')
    BEGIN
        RAISERROR('Estado invalido.', 16, 1);
        RETURN;
    END

    UPDATE dbo.ESTRATEGIA_SUGERENCIA
    SET ESTADO       = @Estado,
        /* Volver a "sugerida" borra la decision: si no, quedaria una
           sugerencia pendiente que dice que alguien ya la resolvio. */
        DECIDIDO_POR = CASE WHEN @Estado = 'SUGERIDA' THEN NULL ELSE @Usuario END,
        DECIDIDO_EL  = CASE WHEN @Estado = 'SUGERIDA' THEN NULL ELSE SYSDATETIME() END,
        COMENTARIO   = CASE WHEN @Estado = 'SUGERIDA' THEN NULL ELSE @Comentario END
    WHERE SUGERENCIA_ID = @SugerenciaId;

    IF @@ROWCOUNT = 0
        RAISERROR('No existe la sugerencia indicada.', 16, 1);
    ELSE
        SELECT SugerenciaId = SUGERENCIA_ID, Estado = ESTADO,
               DecididoPor = DECIDIDO_POR, DecididoEl = DECIDIDO_EL,
               Comentario = COMENTARIO
        FROM dbo.ESTRATEGIA_SUGERENCIA WHERE SUGERENCIA_ID = @SugerenciaId;
END
GO

-- ---------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_CerrarObjetivo
    @ObjetivoId int,
    @Usuario    varchar(60) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.ESTRATEGIA_OBJETIVO
    SET ESTADO = 'CERRADO', CERRADO_EL = SYSDATETIME()
    WHERE OBJETIVO_ID = @ObjetivoId AND ESTADO <> 'CERRADO';

    /* Las que nadie miro quedan como vencidas y no como pendientes: una
       sugerencia sin decidir de una ventana que ya paso no es una tarea
       abierta, es historia. */
    UPDATE dbo.ESTRATEGIA_SUGERENCIA SET ESTADO = 'VENCIDA'
    WHERE OBJETIVO_ID = @ObjetivoId AND ESTADO = 'SUGERIDA';

    SELECT ObjetivoId = @ObjetivoId, Estado = 'CERRADO';
END
GO
