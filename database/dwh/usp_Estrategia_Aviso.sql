/* ===========================================================================
   Aviso a los responsables de cada local.

   Es el paso 4 del circuito: una vez que Damian decidio que sugerencias van,
   cada responsable tiene que enterarse de lo suyo. No de todo: de SU sucursal.

   POR QUE SE MARCA POR SUCURSAL Y NO SOLO EN LA CABECERA
   -----------------------------------------------------
   Si un mail rebota o una sucursal todavia no tiene responsable cargado, el
   aviso queda a medias. Con una sola marca en el objetivo no habria forma de
   reintentar sin volver a molestar a los que ya recibieron el mail.
   =========================================================================== */

IF COL_LENGTH('dbo.ESTRATEGIA_OBJETIVO_SUCURSAL', 'AVISADO_EL') IS NULL
BEGIN
    ALTER TABLE dbo.ESTRATEGIA_OBJETIVO_SUCURSAL
        ADD AVISADO_EL datetime2(0) NULL;
    PRINT 'ESTRATEGIA_OBJETIVO_SUCURSAL: columna AVISADO_EL agregada.';
END
ELSE
    PRINT 'ESTRATEGIA_OBJETIVO_SUCURSAL: AVISADO_EL ya existia.';
GO


/* ---------------------------------------------------------------------------
   Deja constancia de que a esta sucursal ya se le aviso.

   La cabecera se marca sola cuando no queda ninguna sucursal sin avisar: asi
   "avisado" en el listado significa avisado de verdad y no "se empezo a
   avisar". Una sucursal sin mail cargado nunca se marca, y por lo tanto el
   objetivo tampoco: es la senal de que falta cargar ese dato.
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_MarcarAvisado
    @ObjetivoId int,
    @Sucursal   int
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.ESTRATEGIA_OBJETIVO_SUCURSAL
    SET AVISADO_EL = SYSDATETIME()
    WHERE OBJETIVO_ID = @ObjetivoId AND SUCURSAL = @Sucursal;

    IF NOT EXISTS (SELECT 1 FROM dbo.ESTRATEGIA_OBJETIVO_SUCURSAL
                   WHERE OBJETIVO_ID = @ObjetivoId AND AVISADO_EL IS NULL)
        UPDATE dbo.ESTRATEGIA_OBJETIVO
        SET AVISADO_EL = SYSDATETIME()
        WHERE OBJETIVO_ID = @ObjetivoId AND AVISADO_EL IS NULL;

    SELECT Sucursal = SUCURSAL, AvisadoEl = AVISADO_EL
    FROM dbo.ESTRATEGIA_OBJETIVO_SUCURSAL
    WHERE OBJETIVO_ID = @ObjetivoId AND SUCURSAL = @Sucursal;
END
GO


/* ---------------------------------------------------------------------------
   usp_ObtenerObjetivo, ahora con AVISADO_EL por sucursal.

   Se redefine entero y no con un ALTER parcial porque un procedimiento no se
   parchea: esta es la version completa y vigente.
   --------------------------------------------------------------------------- */
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
           Responsable = s.RESPONSABLE, Mail = s.MAIL, Notas = s.NOTAS,
           AvisadoEl = s.AVISADO_EL
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


/* ---------------------------------------------------------------------------
   Vuelve a poner en cero el aviso de un objetivo.

   Sirve cuando se aceptan sugerencias NUEVAS despues de haber avisado: lo que
   se mando ya no es lo vigente y hay que volver a mandarlo. Sin esto, el
   objetivo figuraria como avisado con la mitad de las acciones.
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_ReabrirAviso
    @ObjetivoId int
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.ESTRATEGIA_OBJETIVO_SUCURSAL SET AVISADO_EL = NULL
    WHERE OBJETIVO_ID = @ObjetivoId;
    UPDATE dbo.ESTRATEGIA_OBJETIVO SET AVISADO_EL = NULL
    WHERE OBJETIVO_ID = @ObjetivoId;
END
GO

PRINT '';
PRINT 'Aviso de estrategia listo.';
GO
