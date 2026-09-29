/* ===========================================================================
   usp_RecalibrarModelos
   ---------------------------------------------------------------------------
   Vuelve a calcular todas las tablas de calibracion con la historia
   disponible hoy.

   POR QUE CORRE TODOS LOS DIAS
   ----------------------------
   Ninguna de esas tablas guarda un dato: guardan la FOTO DE UN CALCULO. Si
   se congelan, en unos meses el modelo estaria recomendando con el mundo de
   hace un ano, porque los productos, los precios y los habitos cambian. Se
   recalculan con la carga diaria para que la foto siga siendo de hoy.

   ORDEN
   -----
   Va despues de que la huella cargo la jornada nueva: las tres leen de ahi y
   antes de eso estarian calibrando con datos viejos.

   TOLERANTE A FALLOS PARCIALES
   ----------------------------
   Si una calibracion falla, las otras siguen. Son independientes entre si y
   frenar todo porque una tuvo un problema dejaria al modelo mas desactualizado
   de lo necesario. Se informa cuales fallaron y el llamador decide.
   =========================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_RecalibrarModelos
    @BaseOrigen varchar(30) = 'SRV_GRIDO_ZSUR'
AS
BEGIN
    SET NOCOUNT ON;

    CREATE TABLE #R (
        PASO      varchar(40),
        RESULTADO varchar(10),
        DETALLE   varchar(400),
        SEGUNDOS  numeric(8,1)
    );

    DECLARE @t0 datetime2, @err nvarchar(400);

    ---------------------------------------------------------------- 0
    /* El peso de venta por hora va PRIMERO: de el sale la exposicion a la
       lluvia, que despues usan el agregado diario, el modelo de esperado y el
       pronostico. Si se calibrara al final, los demas trabajarian un dia
       entero con los pesos viejos. */
    SET @t0 = SYSDATETIME();
    BEGIN TRY
        EXEC dbo.usp_CalibrarPesoHora @BaseOrigen = @BaseOrigen;
        INSERT #R VALUES ('Peso de venta por hora', 'OK',
            (SELECT CONCAT(COUNT(DISTINCT SUCURSAL), ' sucursales, ', COUNT(*), ' horas')
             FROM dbo.DIM_PESO_HORA WHERE BASE_ORIGEN = @BaseOrigen),
            DATEDIFF(ms, @t0, SYSDATETIME()) / 1000.0);
    END TRY
    BEGIN CATCH
        SET @err = ERROR_MESSAGE();
        INSERT #R VALUES ('Peso de venta por hora', 'FALLO', @err,
                          DATEDIFF(ms, @t0, SYSDATETIME()) / 1000.0);
    END CATCH

    ---------------------------------------------------------------- 0b
    SET @t0 = SYSDATETIME();
    BEGIN TRY
        EXEC dbo.usp_CalibrarImpactoLluvia @BaseOrigen = @BaseOrigen;
        INSERT #R VALUES ('Impacto de la lluvia', 'OK',
            (SELECT CONCAT(COUNT(*), ' tramos, peor caso ',
                    CAST(MIN(IMPACTO_VS_SECO_PCT) AS varchar(10)), '%')
             FROM dbo.DIM_IMPACTO_LLUVIA WHERE BASE_ORIGEN = @BaseOrigen AND CONFIABLE = 1),
            DATEDIFF(ms, @t0, SYSDATETIME()) / 1000.0);
    END TRY
    BEGIN CATCH
        SET @err = ERROR_MESSAGE();
        INSERT #R VALUES ('Impacto de la lluvia', 'FALLO', @err,
                          DATEDIFF(ms, @t0, SYSDATETIME()) / 1000.0);
    END CATCH

    ---------------------------------------------------------------- 1
    SET @t0 = SYSDATETIME();
    BEGIN TRY
        EXEC dbo.usp_CalibrarAjusteSalto @BaseOrigen = @BaseOrigen;
        INSERT #R VALUES ('Ajuste por salto termico', 'OK',
            (SELECT CONCAT(COUNT(*), ' franjas, factor maximo ',
                    CAST(MAX(FACTOR) AS varchar(10)))
             FROM dbo.DIM_AJUSTE_SALTO_TEMP WHERE BASE_ORIGEN = @BaseOrigen),
            DATEDIFF(ms, @t0, SYSDATETIME()) / 1000.0);
    END TRY
    BEGIN CATCH
        SET @err = ERROR_MESSAGE();
        INSERT #R VALUES ('Ajuste por salto termico', 'FALLO', @err,
                          DATEDIFF(ms, @t0, SYSDATETIME()) / 1000.0);
    END CATCH

    ---------------------------------------------------------------- 2
    SET @t0 = SYSDATETIME();
    BEGIN TRY
        EXEC dbo.usp_CalibrarElasticidad @BaseOrigen = @BaseOrigen;
        INSERT #R VALUES ('Elasticidad al clima', 'OK',
            (SELECT CONCAT(COUNT(DISTINCT GRUPO), ' grupos, ventana ',
                    CAST(MIN(VENTANA_DESDE) AS varchar(10)), ' a ',
                    CAST(MAX(VENTANA_HASTA) AS varchar(10)))
             FROM dbo.DIM_ELASTICIDAD_CLIMA WHERE BASE_ORIGEN = @BaseOrigen),
            DATEDIFF(ms, @t0, SYSDATETIME()) / 1000.0);
    END TRY
    BEGIN CATCH
        SET @err = ERROR_MESSAGE();
        INSERT #R VALUES ('Elasticidad al clima', 'FALLO', @err,
                          DATEDIFF(ms, @t0, SYSDATETIME()) / 1000.0);
    END CATCH

    ---------------------------------------------------------------- 3
    SET @t0 = SYSDATETIME();
    BEGIN TRY
        EXEC dbo.usp_RefrescarDimPromoAplicacion @BaseOrigen = @BaseOrigen;
        INSERT #R VALUES ('Aplicaciones por promocion', 'OK',
            (SELECT CONCAT(COUNT(*), ' promociones')
             FROM dbo.DIM_PROMO_APLICACION WHERE BASE_ORIGEN = @BaseOrigen),
            DATEDIFF(ms, @t0, SYSDATETIME()) / 1000.0);
    END TRY
    BEGIN CATCH
        SET @err = ERROR_MESSAGE();
        INSERT #R VALUES ('Aplicaciones por promocion', 'FALLO', @err,
                          DATEDIFF(ms, @t0, SYSDATETIME()) / 1000.0);
    END CATCH

    SELECT PASO, RESULTADO, DETALLE, SEGUNDOS FROM #R;

    DECLARE @fallos int = (SELECT COUNT(*) FROM #R WHERE RESULTADO = 'FALLO');
    DROP TABLE #R;

    /* Se levanta error solo si fallo TODO: que una calibracion falle deja al
       modelo parcialmente viejo, pero no roto, y no amerita marcar la tarea
       diaria entera como fallida. */
    IF @fallos = 3
        RAISERROR('Fallaron las tres calibraciones.', 16, 1);
    ELSE IF @fallos > 0
        PRINT CONCAT('ATENCION: ', @fallos, ' calibracion(es) fallaron. El resto se actualizo.');
END
GO
