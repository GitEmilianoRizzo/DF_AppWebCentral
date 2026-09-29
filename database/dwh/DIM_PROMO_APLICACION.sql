/* ===========================================================================
   DIM_PROMO_APLICACION
   ---------------------------------------------------------------------------
   Cuantas unidades consume UNA aplicacion de cada promocion.

   POR QUE EXISTE
   --------------
   SmartFran, en la solapa Promociones, no cuenta unidades vendidas sino
   APLICACIONES de la promo: un 2x1 que se llevo 18 kilos figura como 9. Sin
   este dato la columna Cantidad daba el doble o el cuadruple segun la promo.

   COMO SE CALCULA
   ---------------
   Una promo se arma con COMBOS. DETPROMOS lista, por cada combo, los
   articulos ALTERNATIVOS que lo satisfacen: "2x1 en kilo" tiene dos combos y
   cada uno acepta tres sabores. Una aplicacion consume UN articulo de cada
   combo, asi que las unidades por aplicacion son la suma de PROCANTIDAD
   tomando una sola fila por combo. Sumar todas las filas contaria las
   alternativas y daria 6 en vez de 2.

   OJO CON EL NOMBRE
   -----------------
   Se indexa por ID de promocion y NO por descripcion: "2x1 en Kilo de Lunes
   a Jueves" existe dos veces (3572 y 3586) con distinta capitalizacion.
   Agrupar por nombre junta las dos y duplica el divisor.

   Verificado contra el export de SmartFran de Escalada, jornada del
   23/09/2026: las nueve promociones del periodo dan exacto.

   Se refresca junto con la carga diaria, igual que DIM_INSUMO_COSTO: las
   promos cambian poco pero cambian.
   =========================================================================== */

IF OBJECT_ID('dbo.DIM_PROMO_APLICACION', 'U') IS NOT NULL
    DROP TABLE dbo.DIM_PROMO_APLICACION;
GO

CREATE TABLE dbo.DIM_PROMO_APLICACION (
    BASE_ORIGEN     varchar(30)   NOT NULL,
    PROMOCION       int           NOT NULL,
    PROMO_DESCRIP   varchar(60)   NULL,
    COMBOS          int           NOT NULL,
    UNID_POR_APLIC  numeric(12,4) NOT NULL,
    FECHA_CARGA     datetime2(0)  NOT NULL CONSTRAINT DF_DPA_CARGA DEFAULT SYSDATETIME(),
    CONSTRAINT PK_DIM_PROMO_APLICACION PRIMARY KEY (BASE_ORIGEN, PROMOCION)
);
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefrescarDimPromoAplicacion
    @BaseOrigen varchar(30) = 'SRV_GRIDO_ZSUR'
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @sql nvarchar(max) = N'
    DELETE FROM dbo.DIM_PROMO_APLICACION WHERE BASE_ORIGEN = @base;

    WITH por_combo AS (
        SELECT PROMO, COMBO, MAX(PROCANTIDAD) AS CANT
        FROM {DB}.dbo.DETPROMOS
        GROUP BY PROMO, COMBO
    )
    INSERT dbo.DIM_PROMO_APLICACION
           (BASE_ORIGEN, PROMOCION, PROMO_DESCRIP, COMBOS, UNID_POR_APLIC)
    SELECT @base,
           c.PROMO,
           LEFT(RTRIM(a.ARTDESCRIP), 60),
           COUNT(*),
           SUM(c.CANT)
    FROM por_combo c
    LEFT JOIN {DB}.dbo.ARTICULOS a ON a.ARTICULO = c.PROMO
    GROUP BY c.PROMO, LEFT(RTRIM(a.ARTDESCRIP), 60)
    HAVING SUM(c.CANT) > 0;';

    SET @sql = REPLACE(@sql, N'{DB}', QUOTENAME(@BaseOrigen));
    EXEC sp_executesql @sql, N'@base varchar(30)', @base = @BaseOrigen;

    DECLARE @n int = (SELECT COUNT(*) FROM dbo.DIM_PROMO_APLICACION
                      WHERE BASE_ORIGEN = @BaseOrigen);
    PRINT CONCAT('DIM_PROMO_APLICACION: ', @n, ' promociones para ', @BaseOrigen);
END
GO

EXEC dbo.usp_RefrescarDimPromoAplicacion;
GO
