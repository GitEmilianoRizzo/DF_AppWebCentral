/* ===========================================================================
   BAJA DE OBJETOS SIN USO DE LA WEBAPP EN DF_DTW
   ---------------------------------------------------------------------------
   Generado el 19/09/2026 a partir del relevamiento
   C:\PILL-DF\SQL\DF_DTW\relevamiento_objetos_webapp.sql

   QUE DA DE BAJA
   --------------
   Los objetos que trajo la app migrada y que este modelo no usa: el dashboard
   de restaurante, la ingesta de tickets por API, las conexiones a POS y la
   vista de estado de integracion. Son 17 vistas,
   13 procedimientos, 3 funciones y
   26 tablas.

   QUE NO TOCA
   -----------
   - Todo el esquema dbo: ahi vive la huella de venta (1,28 M de filas) y sus
     procedimientos. El script ABORTA si detecta que algo de dbo entro en la
     lista.
   - El esquema auth: login y usuarios, en uso.
   - El stack de tipo de cambio: cfg.TipoCambioProveedor, dim.Moneda,
     dim.TipoCambio y stg.TipoCambioIngestaLog. La pantalla Tipos de Cambio los
     consulta y ExchangeRateRefreshJob les escribe aunque nadie entre a la app.

   COMO SE DETERMINO QUE NO SE USAN
   --------------------------------
   Recorriendo el grafo de imports del frontend desde main.tsx: 18 de 46
   archivos quedaron huerfanos al dar de baja las secciones, y con ellos sus
   endpoints. De los 8 grupos de api.ts solo authApi e informeGridoApi siguen
   vivos. El backend conserva los controllers, pero ya no los llama nadie.

   COMO USARLO
   -----------
   1. Correrlo tal cual: con @EJECUTAR = 0 solo INFORMA, no borra nada.
   2. Revisar la salida.
   3. Poner @EJECUTAR = 1 y volver a correrlo.

   El borrado va dentro de una transaccion: si algo falla, no queda a medias.

   ORDEN
   -----
   Vistas, despues procedimientos y funciones, despues tablas con las hijas
   antes que las padres. Calculado contra sys.foreign_keys y
   sys.sql_expression_dependencies, no a ojo.

   OJO SI SE EDITA: de la seccion 0 a la 3 es UN SOLO LOTE, sin GO. Un GO
   reinicia el alcance de las variables y los dos interruptores de abajo
   dejarian de verse en la fase de baja.
   =========================================================================== */

USE DF_DTW;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

-- ###########################################################################
-- ###  0 = solo informa   |   1 = ejecuta la baja
-- ###########################################################################
DECLARE @EJECUTAR bit = 0;

/* Las cuatro tablas que TIENEN DATOS van aparte. Ponerlo en 1 solo si ya se
   decidio que esos datos no se conservan. Antes de borrarlas el script las
   respalda en el esquema [bak]. */
DECLARE @INCLUIR_TABLAS_CON_DATOS bit = 0;


-- ===========================================================================
-- 0. RED DE SEGURIDAD
-- ===========================================================================
-- Si por un error de edicion entrara algo de dbo o de auth en las listas de
-- abajo, esto lo detiene antes de tocar nada.
DECLARE @OBJETIVOS TABLE (NOMBRE nvarchar(300));
INSERT @OBJETIVOS (NOMBRE) VALUES
    (N'fact.vw_VentasResumenDiario'),
    (N'fact.vw_VentasPorTipoPlato'),
    (N'fact.vw_VentasPorProductoConPeso'),
    (N'fact.vw_VentasPorProducto'),
    (N'fact.vw_VentasPorMozo'),
    (N'fact.vw_VentasPorMealPeriod'),
    (N'fact.vw_VentasPorHoraDiaSemana'),
    (N'fact.vw_VentasPorGrupoEconomico'),
    (N'fact.vw_VentasPorFranquicia'),
    (N'fact.vw_VentasPorDiaRanking'),
    (N'fact.vw_VentasDelDia'),
    (N'fact.vw_VentasConsolidadasUsd'),
    (N'fact.vw_OcupacionMesas'),
    (N'fact.vw_IndicadoresPorCubierto'),
    (N'fact.vw_HomeDashboard'),
    (N'fact.vw_EstadoIntegracionFranquicias'),
    (N'dim.vw_EstadoNodosConexion'),
    (N'api.sp_ObtenerFranquiciaPorApiKey'),
    (N'dim.sp_ActualizarUltimaSincronizacion'),
    (N'dim.sp_InsertarActualizarMesa'),
    (N'dim.sp_InsertarActualizarMozo'),
    (N'dim.sp_InsertarActualizarProducto'),
    (N'fact.sp_InsertarTicketDetalle'),
    (N'fact.sp_InsertarTicketIdempotente'),
    (N'stg.sp_ActualizarEstadoBatch'),
    (N'stg.sp_GuardarJsonCrudo'),
    (N'stg.sp_ObtenerEstadoBatch'),
    (N'stg.sp_RegistrarApiLog'),
    (N'stg.sp_RegistrarBatchIngesta'),
    (N'stg.sp_RegistrarErrorIngesta'),
    (N'cfg.fn_GetAlicuotaImpuesto'),
    (N'cfg.fn_GetMealPeriod'),
    (N'fact.fn_ComparativoMensual'),
    (N'fact.VentaTicketMedioPago'),
    (N'fact.VentaTicketDetalle'),
    (N'fact.VentaTicketDescuento'),
    (N'stg.IngestionError'),
    (N'stg.IngestionBatchRawJson'),
    (N'log.EjecucionNodo'),
    (N'fact.VentaTicket'),
    (N'dim.ValorNoMapeado'),
    (N'dim.MapeoMedioPago'),
    (N'dim.MapeoCategoria'),
    (N'stg.IngestionBatch'),
    (N'dim.Producto'),
    (N'dim.NodoConexion'),
    (N'dim.Mozo'),
    (N'dim.Mesa'),
    (N'cfg.FranjaHorariaFranquicia'),
    (N'cfg.AlicuotaImpuestoFranquicia'),
    (N'api.ApiKeyFranquicia'),
    (N'dim.Franquicia'),
    (N'stg.ApiIngestaLog'),
    (N'dim.TipoPlato'),
    (N'dim.PeriodoComida'),
    (N'dim.MedioPago'),
    (N'dim.GrupoEconomico'),
    (N'cfg.Parser'),
    (N'cfg.Parametro');

IF EXISTS (SELECT 1 FROM @OBJETIVOS WHERE NOMBRE LIKE 'dbo.%' OR NOMBRE LIKE 'auth.%')
BEGIN
    RAISERROR('ABORTA: la lista de baja incluye objetos de dbo o auth. Revisar el script.', 16, 1);
    RETURN;
END

IF EXISTS (SELECT 1 FROM @OBJETIVOS
           WHERE NOMBRE IN ('cfg.TipoCambioProveedor','dim.Moneda','dim.TipoCambio','stg.TipoCambioIngestaLog'))
BEGIN
    RAISERROR('ABORTA: la lista incluye tablas del tipo de cambio, que estan en uso.', 16, 1);
    RETURN;
END

-- Control de que la huella sigue entera antes de empezar.
DECLARE @huella bigint = (SELECT COUNT(*) FROM dbo.TRX_HUELLA_VENTA);
PRINT 'Huella de venta antes de la baja: ' + FORMAT(@huella, 'N0') + ' filas';
IF @huella < 1000000
BEGIN
    RAISERROR('ABORTA: la huella tiene menos filas de las esperadas. Revisar antes de seguir.', 16, 1);
    RETURN;
END

-- ===========================================================================
-- 1. INFORME: que se va a dar de baja
-- ===========================================================================
SELECT
    ORDEN = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)),
    OBJETO = t.NOMBRE,
    TIPO = CASE o.type WHEN 'U' THEN 'TABLA' WHEN 'V' THEN 'VISTA'
                       WHEN 'P' THEN 'PROC' ELSE 'FUNC' END,
    FILAS = ISNULL(p.rows, 0),
    EXISTE = CASE WHEN o.object_id IS NULL THEN 'YA NO ESTA' ELSE 'si' END
FROM @OBJETIVOS t
LEFT JOIN sys.objects o ON o.object_id = OBJECT_ID(t.NOMBRE)
LEFT JOIN sys.partitions p ON p.object_id = o.object_id AND p.index_id IN (0,1)
ORDER BY ORDEN;

IF @EJECUTAR = 0
BEGIN
    PRINT '';
    PRINT '>>> MODO INFORME. No se borro nada.';
    PRINT '>>> Para ejecutar la baja, poner @EJECUTAR = 1 arriba y volver a correr.';
    RETURN;
END


-- ===========================================================================
-- 2. RESPALDO de las tablas con datos
-- ===========================================================================
-- Se copian al esquema [bak] antes de borrarlas. Ocupan poco (146
-- filas en total) y es la unica forma de volver atras sin restaurar la base.
-- Solo se respalda si esas tablas se van a borrar de verdad: si no, el script
-- dejaria copias que nadie pidio.
-- Va FUERA de la transaccion a proposito, para que el respaldo sobreviva aunque
-- la baja falle y se revierta.
IF @INCLUIR_TABLAS_CON_DATOS = 1
BEGIN
    -- CREATE SCHEMA tiene que ser la primera sentencia de su lote, y aca no
    -- puede haber lotes: por eso va por EXEC.
    IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'bak')
        EXEC('CREATE SCHEMA [bak] AUTHORIZATION [dbo]');

    IF OBJECT_ID('bak.cfg_FranjaHorariaFranquicia', 'U') IS NULL AND OBJECT_ID('cfg.FranjaHorariaFranquicia', 'U') IS NOT NULL
        SELECT * INTO bak.cfg_FranjaHorariaFranquicia FROM cfg.FranjaHorariaFranquicia;   -- 66 filas
    IF OBJECT_ID('bak.cfg_AlicuotaImpuestoFranquicia', 'U') IS NULL AND OBJECT_ID('cfg.AlicuotaImpuestoFranquicia', 'U') IS NOT NULL
        SELECT * INTO bak.cfg_AlicuotaImpuestoFranquicia FROM cfg.AlicuotaImpuestoFranquicia;   -- 22 filas
    IF OBJECT_ID('bak.dim_Franquicia', 'U') IS NULL AND OBJECT_ID('dim.Franquicia', 'U') IS NOT NULL
        SELECT * INTO bak.dim_Franquicia FROM dim.Franquicia;   -- 33 filas
    IF OBJECT_ID('bak.dim_GrupoEconomico', 'U') IS NULL AND OBJECT_ID('dim.GrupoEconomico', 'U') IS NOT NULL
        SELECT * INTO bak.dim_GrupoEconomico FROM dim.GrupoEconomico;   -- 25 filas
    PRINT 'Tablas con datos respaldadas en el esquema [bak].';
END

-- ===========================================================================
-- 3. BAJA
-- ===========================================================================
BEGIN TRANSACTION;
BEGIN TRY

-- --- 3.1 Vistas (17) --------------------------------------
DROP VIEW IF EXISTS fact.vw_VentasResumenDiario;
DROP VIEW IF EXISTS fact.vw_VentasPorTipoPlato;
DROP VIEW IF EXISTS fact.vw_VentasPorProductoConPeso;
DROP VIEW IF EXISTS fact.vw_VentasPorProducto;
DROP VIEW IF EXISTS fact.vw_VentasPorMozo;
DROP VIEW IF EXISTS fact.vw_VentasPorMealPeriod;
DROP VIEW IF EXISTS fact.vw_VentasPorHoraDiaSemana;
DROP VIEW IF EXISTS fact.vw_VentasPorGrupoEconomico;
DROP VIEW IF EXISTS fact.vw_VentasPorFranquicia;
DROP VIEW IF EXISTS fact.vw_VentasPorDiaRanking;
DROP VIEW IF EXISTS fact.vw_VentasDelDia;
DROP VIEW IF EXISTS fact.vw_VentasConsolidadasUsd;
DROP VIEW IF EXISTS fact.vw_OcupacionMesas;
DROP VIEW IF EXISTS fact.vw_IndicadoresPorCubierto;
DROP VIEW IF EXISTS fact.vw_HomeDashboard;
DROP VIEW IF EXISTS fact.vw_EstadoIntegracionFranquicias;
DROP VIEW IF EXISTS dim.vw_EstadoNodosConexion;

-- --- 3.2 Procedimientos (13) ------------------------------
DROP PROCEDURE IF EXISTS api.sp_ObtenerFranquiciaPorApiKey;
DROP PROCEDURE IF EXISTS dim.sp_ActualizarUltimaSincronizacion;
DROP PROCEDURE IF EXISTS dim.sp_InsertarActualizarMesa;
DROP PROCEDURE IF EXISTS dim.sp_InsertarActualizarMozo;
DROP PROCEDURE IF EXISTS dim.sp_InsertarActualizarProducto;
DROP PROCEDURE IF EXISTS fact.sp_InsertarTicketDetalle;
DROP PROCEDURE IF EXISTS fact.sp_InsertarTicketIdempotente;
DROP PROCEDURE IF EXISTS stg.sp_ActualizarEstadoBatch;
DROP PROCEDURE IF EXISTS stg.sp_GuardarJsonCrudo;
DROP PROCEDURE IF EXISTS stg.sp_ObtenerEstadoBatch;
DROP PROCEDURE IF EXISTS stg.sp_RegistrarApiLog;
DROP PROCEDURE IF EXISTS stg.sp_RegistrarBatchIngesta;
DROP PROCEDURE IF EXISTS stg.sp_RegistrarErrorIngesta;

-- --- 3.3 Funciones (3) -----------------------------------
DROP FUNCTION IF EXISTS cfg.fn_GetAlicuotaImpuesto;
DROP FUNCTION IF EXISTS cfg.fn_GetMealPeriod;
DROP FUNCTION IF EXISTS fact.fn_ComparativoMensual;

-- --- 3.4 Tablas vacias (22), hijas antes que padres --------
DROP TABLE IF EXISTS fact.VentaTicketMedioPago;
DROP TABLE IF EXISTS fact.VentaTicketDetalle;
DROP TABLE IF EXISTS fact.VentaTicketDescuento;
DROP TABLE IF EXISTS stg.IngestionError;
DROP TABLE IF EXISTS stg.IngestionBatchRawJson;
DROP TABLE IF EXISTS log.EjecucionNodo;
DROP TABLE IF EXISTS fact.VentaTicket;
DROP TABLE IF EXISTS dim.ValorNoMapeado;
DROP TABLE IF EXISTS dim.MapeoMedioPago;
DROP TABLE IF EXISTS dim.MapeoCategoria;
DROP TABLE IF EXISTS stg.IngestionBatch;
DROP TABLE IF EXISTS dim.Producto;
DROP TABLE IF EXISTS dim.NodoConexion;
DROP TABLE IF EXISTS dim.Mozo;
DROP TABLE IF EXISTS dim.Mesa;
DROP TABLE IF EXISTS api.ApiKeyFranquicia;
DROP TABLE IF EXISTS stg.ApiIngestaLog;
DROP TABLE IF EXISTS dim.TipoPlato;
DROP TABLE IF EXISTS dim.PeriodoComida;
DROP TABLE IF EXISTS dim.MedioPago;
DROP TABLE IF EXISTS cfg.Parser;
DROP TABLE IF EXISTS cfg.Parametro;

    -- --- 3.5 Tablas CON DATOS (4) ---------------------------------
    -- Solo si se activo @INCLUIR_TABLAS_CON_DATOS. Quedaron respaldadas en [bak].
    IF @INCLUIR_TABLAS_CON_DATOS = 1
    BEGIN
        DROP TABLE IF EXISTS cfg.FranjaHorariaFranquicia;   -- 66 filas
        DROP TABLE IF EXISTS cfg.AlicuotaImpuestoFranquicia;   -- 22 filas
        DROP TABLE IF EXISTS dim.Franquicia;   -- 33 filas
        DROP TABLE IF EXISTS dim.GrupoEconomico;   -- 25 filas
    END
    ELSE
        PRINT 'Tablas con datos NO tocadas (@INCLUIR_TABLAS_CON_DATOS = 0).';

    COMMIT TRANSACTION;
    PRINT 'Baja completada.';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT 'ERROR: ' + ERROR_MESSAGE();
    PRINT 'No se borro nada: la transaccion se revirtio entera.';
    THROW;
END CATCH
GO

-- ===========================================================================
-- 4. VERIFICACION
-- ===========================================================================
SELECT ESQUEMA = s.name,
       TABLAS = SUM(CASE WHEN o.type = 'U' THEN 1 ELSE 0 END),
       VISTAS = SUM(CASE WHEN o.type = 'V' THEN 1 ELSE 0 END),
       PROGRAMABLES = SUM(CASE WHEN o.type IN ('P','IF','FN','TF') THEN 1 ELSE 0 END)
FROM sys.objects o
JOIN sys.schemas s ON s.schema_id = o.schema_id
WHERE o.is_ms_shipped = 0 AND o.type IN ('U','V','P','IF','FN','TF')
GROUP BY s.name ORDER BY s.name;

-- La huella tiene que seguir intacta.
SELECT HUELLA_FILAS = COUNT(*), JORNADAS = COUNT(DISTINCT FECHA_OPERATIVA)
FROM dbo.TRX_HUELLA_VENTA;

-- Nada debe quedar referenciando a un objeto que ya no existe.
SELECT OBJETO_ROTO = OBJECT_SCHEMA_NAME(d.referencing_id) + '.' + OBJECT_NAME(d.referencing_id),
       REFERENCIA_FALTANTE = d.referenced_entity_name
FROM sys.sql_expression_dependencies d
WHERE d.referenced_id IS NULL
  AND d.referenced_entity_name IS NOT NULL
  AND OBJECT_SCHEMA_NAME(d.referencing_id) <> 'dbo';
GO
