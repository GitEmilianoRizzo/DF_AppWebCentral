/* ===========================================================================
   IX_HUELLA_ESTADISTICA
   ---------------------------------------------------------------------------
   Indice de cobertura para usp_EstadisticaVentas.

   POR QUE HIZO FALTA
   ------------------
   La consulta del 01/09 al 22/09 tardaba 852 segundos. La causa no era el
   plan sino el tamano: TRX_HUELLA_VENTA pesa 2.045 MB con 1.665 bytes por
   fila (205 columnas), y SQL Server Express topea el buffer pool en 1.410 MB.
   La tabla NO entra en cache ni con el servidor vacio, asi que cada recorrido
   se lee de disco entero. Un simple COUNT(*) sobre el periodo tardaba 74
   segundos para devolver 24.016 filas.

   Ademas no habia ningun indice por FECHA_HORA: los existentes son todos por
   FECHA_OPERATIVA, y el SP filtra por hora calendario porque esa es la
   convencion de SmartFran.

   QUE RESUELVE
   ------------
   Con este indice la consulta busca directo el rango de fechas y se lleva
   todas las columnas que necesita sin volver a la tabla. En vez de recorrer
   2 GB lee unos pocos MB, que si entran en cache aunque el servidor este
   ajustado de memoria.

   El orden de la clave importa: BASE_ORIGEN primero porque siempre viene
   fijo, FECHA_HORA despues porque es el rango.

   OJO AL AGREGAR COLUMNAS AL SP
   -----------------------------
   Si el SP pasa a leer una columna que no esta en la lista INCLUDE, el indice
   deja de cubrir la consulta y vuelve a hacer busquedas contra la tabla: el
   tiempo se desploma otra vez. Al tocar el SELECT del bloque #U, revisar esta
   lista.
   =========================================================================== */

IF EXISTS (SELECT 1 FROM sys.indexes
           WHERE object_id = OBJECT_ID('dbo.TRX_HUELLA_VENTA')
             AND name = 'IX_HUELLA_ESTADISTICA')
    DROP INDEX IX_HUELLA_ESTADISTICA ON dbo.TRX_HUELLA_VENTA;
GO

CREATE NONCLUSTERED INDEX IX_HUELLA_ESTADISTICA
ON dbo.TRX_HUELLA_VENTA (BASE_ORIGEN, FECHA_HORA)
INCLUDE (
    -- identificacion y cortes
    TICKET_KEY, SUCURSAL, SUCURSAL_DESCRIP, HORA, ES_ANULADA,
    ARTICULO, ART_DESCRIP, ART_GRUPO, ART_GRUPO_DESCRIP, ART_TIPO,
    PROMOCION_DESCRIP, SOBREVENTA, VTACANAL, CANAL_DESCRIP,
    USULOGIN, CLIENTE,
    -- banderas que definen filtros y clasificaciones
    VTADELIVERY, ES_PLATAFORMA_DELIVERY, LINEA_ES_PROMOCION,
    LINEA_ES_SOBREVENTA, PROMO,
    -- medidas
    IMPORTE, CANTIDAD, DESCUENTOS, KILOS, COSTO, UTILIDAD, CONTRIB_MARGINAL
)
WITH (DATA_COMPRESSION = PAGE, FILLFACTOR = 95);
GO
