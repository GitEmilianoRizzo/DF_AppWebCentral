/* ===========================================================================
   Relevamiento de objetos de la WebApp en DF_DTW
   ---------------------------------------------------------------------------
   Que objetos trajo la app migrada y cuales sigue usando este modelo.

   Cruza cuatro evidencias:
     1. Inventario de objetos, por esquema (excluye dbo, que es la huella).
     2. Filas: una tabla vacia desde que se instalo es candidata a sobrar.
     3. Dependencias dentro de la base: quien referencia a quien.
     4. Alcance desde la app, resuelto por analisis del codigo (ver la tabla
        #ALCANCE de abajo): la app expone 9 controllers, pero recorriendo el
        grafo de imports del frontend desde main.tsx solo quedan alcanzables
        auth, fx e informe-grido. El resto de las pantallas se dieron de baja.

   NO BORRA NADA. Es solo un informe.

   Como se determino el alcance (16-19/09/2026):
     - 18 de 46 archivos del frontend son huerfanos: nadie los importa.
     - De los 8 grupos de api.ts, solo authApi e informeGridoApi siguen vivos.
     - TiposCambio.tsx no usa api.ts sino fetch() directo a /api/v1/fx, por eso
       el stack de tipo de cambio sigue en pie.
     - ExchangeRateRefreshJob es un HostedService: corre aunque nadie entre a
       la app, asi que sus tablas se escriben igual.

   Creado: 2026-09-19
   =========================================================================== */

USE DF_DTW;
GO

SET NOCOUNT ON;

/* Modulos de la app y si este modelo los usa. Editar aca si alguna pantalla
   vuelve a activarse. */
DECLARE @ALCANCE TABLE (MODULO varchar(30), VIVO bit, MOTIVO varchar(90));
INSERT @ALCANCE VALUES
    ('auth',        1, 'Login y ABM de usuarios: en uso'),
    ('fx',          1, 'Pantalla Tipos de Cambio + job ExchangeRateRefreshJob'),
    ('huella',      1, 'Informe Diario GRIDO (vive en dbo)'),
    ('dashboard',   0, 'Las pantallas Dashboard, Por Franquicia y Por Producto se dieron de baja'),
    ('conexiones',  0, 'Seccion Conexiones eliminada'),
    ('integracion', 0, 'Seccion Integracion eliminada'),
    ('ingesta',     0, 'Ingesta de tickets por API: no se usa, la venta entra por la huella'),
    ('franquicias', 0, 'franquiciasApi ya no lo importa ninguna pantalla');

/* Mapa objeto -> modulo. Lo que no matchee queda como 'dashboard/ingesta'. */
WITH OBJ AS (
    SELECT
        ESQUEMA = s.name,
        OBJETO  = o.name,
        FULL_N  = s.name + '.' + o.name,
        TIPO    = CASE o.type WHEN 'U' THEN 'TABLA' WHEN 'V' THEN 'VISTA'
                              WHEN 'P' THEN 'PROC'  ELSE 'FUNC' END,
        FILAS   = ISNULL(p.rows, -1)
    FROM sys.objects o
    JOIN sys.schemas s ON s.schema_id = o.schema_id
    LEFT JOIN sys.partitions p ON p.object_id = o.object_id AND p.index_id IN (0,1)
    WHERE o.is_ms_shipped = 0
      AND o.type IN ('U','V','P','IF','FN','TF')
      AND s.name <> 'dbo'
),
CLASIF AS (
    SELECT *,
        MODULO = CASE
            WHEN ESQUEMA = 'auth' THEN 'auth'
            WHEN OBJETO LIKE '%TipoCambio%' OR OBJETO = 'Moneda' THEN 'fx'
            WHEN ESQUEMA = 'stg'  THEN 'ingesta'
            WHEN ESQUEMA = 'api'  THEN 'ingesta'
            WHEN ESQUEMA = 'log'  THEN 'conexiones'
            WHEN OBJETO LIKE '%NodoConexion%' OR OBJETO LIKE '%Mapeo%'
              OR OBJETO = 'ValorNoMapeado' OR OBJETO = 'Parser' THEN 'conexiones'
            WHEN OBJETO LIKE '%EstadoIntegracion%' THEN 'integracion'
            WHEN OBJETO IN ('Franquicia','GrupoEconomico') THEN 'franquicias'
            ELSE 'dashboard'
        END
    FROM OBJ
)
SELECT
    c.MODULO,
    ESTADO = CASE WHEN a.VIVO = 1 THEN 'EN USO' ELSE 'SIN USO' END,
    c.TIPO,
    OBJETO = c.FULL_N,
    FILAS  = CASE WHEN c.FILAS < 0 THEN NULL ELSE c.FILAS END,
    -- Cuantos objetos de la base lo referencian: si es 0 y el modulo esta
    -- muerto, no lo sostiene nada.
    REFERENTES = (SELECT COUNT(DISTINCT d.referencing_id)
                  FROM sys.sql_expression_dependencies d
                  WHERE d.referenced_id = OBJECT_ID(c.FULL_N)),
    MOTIVO = a.MOTIVO
FROM CLASIF c
JOIN @ALCANCE a ON a.MODULO = c.MODULO
ORDER BY a.VIVO, c.MODULO, c.TIPO, c.FULL_N;

PRINT '';
PRINT '=== RESUMEN POR MODULO ===';

WITH OBJ AS (
    SELECT s.name AS ESQUEMA, o.name AS OBJETO, o.type AS T, ISNULL(p.rows,-1) AS FILAS
    FROM sys.objects o
    JOIN sys.schemas s ON s.schema_id = o.schema_id
    LEFT JOIN sys.partitions p ON p.object_id = o.object_id AND p.index_id IN (0,1)
    WHERE o.is_ms_shipped = 0 AND o.type IN ('U','V','P','IF','FN','TF') AND s.name <> 'dbo'
),
CLASIF AS (
    SELECT *, MODULO = CASE
            WHEN ESQUEMA = 'auth' THEN 'auth'
            WHEN OBJETO LIKE '%TipoCambio%' OR OBJETO = 'Moneda' THEN 'fx'
            WHEN ESQUEMA IN ('stg','api') THEN 'ingesta'
            WHEN ESQUEMA = 'log' THEN 'conexiones'
            WHEN OBJETO LIKE '%NodoConexion%' OR OBJETO LIKE '%Mapeo%'
              OR OBJETO = 'ValorNoMapeado' OR OBJETO = 'Parser' THEN 'conexiones'
            WHEN OBJETO LIKE '%EstadoIntegracion%' THEN 'integracion'
            WHEN OBJETO IN ('Franquicia','GrupoEconomico') THEN 'franquicias'
            ELSE 'dashboard' END
    FROM OBJ
)
SELECT
    c.MODULO,
    ESTADO = CASE WHEN a.VIVO = 1 THEN 'EN USO' ELSE 'SIN USO' END,
    TABLAS = SUM(CASE WHEN c.T = 'U' THEN 1 ELSE 0 END),
    VISTAS = SUM(CASE WHEN c.T = 'V' THEN 1 ELSE 0 END),
    PROCS  = SUM(CASE WHEN c.T NOT IN ('U','V') THEN 1 ELSE 0 END),
    TABLAS_VACIAS = SUM(CASE WHEN c.T = 'U' AND c.FILAS = 0 THEN 1 ELSE 0 END),
    FILAS_TOTALES = SUM(CASE WHEN c.FILAS > 0 THEN c.FILAS ELSE 0 END)
FROM CLASIF c
JOIN @ALCANCE a ON a.MODULO = c.MODULO
GROUP BY c.MODULO, a.VIVO
ORDER BY a.VIVO, c.MODULO;
GO
