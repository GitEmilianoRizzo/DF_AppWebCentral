/* ===========================================================================
   Cambia la ventana de un objetivo ya creado.

   POR QUE EXISTE
   --------------
   La ventana no es un detalle administrativo: define que se puede medir. El
   error tipico del modelo cae con la raiz de los dias, asi que una meta del 3%
   necesita alrededor de cuatro semanas para despegarse del ruido, y en una
   semana queda adentro. Cuando eso se descubre despues de crear el objetivo,
   la alternativa a poder estirarlo seria rehacerlo entero y perder las
   decisiones ya tomadas.

   QUE PASA CON LAS SUGERENCIAS
   ----------------------------
   No se tocan. Las que apuntan a un dia que quedo fuera de la ventana nueva se
   marcan VENCIDA; las decididas se respetan. Los dias nuevos no tienen
   sugerencias hasta que se regenere, que es una decision aparte.
   =========================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_AjustarVentana
    @ObjetivoId int,
    @FechaDesde date,
    @FechaHasta date,
    @Usuario    varchar(60) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.ESTRATEGIA_OBJETIVO WHERE OBJETIVO_ID = @ObjetivoId)
    BEGIN
        RAISERROR('No existe el objetivo indicado.', 16, 1);
        RETURN;
    END
    IF @FechaHasta < @FechaDesde
    BEGIN
        RAISERROR('La fecha de fin no puede ser anterior a la de inicio.', 16, 1);
        RETURN;
    END

    BEGIN TRAN;

    UPDATE dbo.ESTRATEGIA_OBJETIVO
    SET FECHA_DESDE = @FechaDesde, FECHA_HASTA = @FechaHasta
    WHERE OBJETIVO_ID = @ObjetivoId;

    /* Una sugerencia para un dia que ya no esta en la ventana no es una tarea
       pendiente: es historia. Las decididas quedan como estan, porque son
       decisiones que se tomaron y sirven para aprender. */
    UPDATE dbo.ESTRATEGIA_SUGERENCIA
    SET ESTADO = 'VENCIDA'
    WHERE OBJETIVO_ID = @ObjetivoId
      AND ESTADO = 'SUGERIDA'
      AND FECHA IS NOT NULL
      AND FECHA NOT BETWEEN @FechaDesde AND @FechaHasta;

    /* La medicion de dias que quedaron afuera se borra: dejarla mostraria un
       acumulado que incluye dias que ya no pertenecen al objetivo. */
    DELETE FROM dbo.ESTRATEGIA_MEDICION
    WHERE OBJETIVO_ID = @ObjetivoId
      AND FECHA NOT BETWEEN @FechaDesde AND @FechaHasta;

    /* El ruido depende del LARGO de la ventana, asi que el guardado quedo
       viejo. Se limpia para que no se muestre un piso que ya no corresponde;
       la proxima medicion lo recalcula. */
    UPDATE dbo.ESTRATEGIA_OBJETIVO_SUCURSAL
    SET RUIDO_VENTANA_PCT = NULL
    WHERE OBJETIVO_ID = @ObjetivoId;

    COMMIT;

    SELECT ObjetivoId = @ObjetivoId, FechaDesde = @FechaDesde, FechaHasta = @FechaHasta,
           Dias = DATEDIFF(day, @FechaDesde, @FechaHasta) + 1;
END
GO

PRINT 'usp_AjustarVentana lista.';
GO
