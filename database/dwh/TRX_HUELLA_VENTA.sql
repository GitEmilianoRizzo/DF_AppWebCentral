/* ===========================================================================
   DF_DTW.dbo.TRX_HUELLA_VENTA
   ---------------------------------------------------------------------------
   HUELLA DIGITAL DE LA VENTA.

   Una fila por LINEA DE TICKET, con la marca que la transaccion dejo en el
   momento en que se ejecuto. Se carga una vez por dia operativo y por base de
   origen, y no se vuelve a tocar: es historia, no una vista.

   PRINCIPIO RECTOR
   ----------------
   El catalogo del articulo sale de ARTICULOSHISTORICO, o sea la version
   vigente CUANDO SE VENDIO (DETVENTAS.ARTVERSION -> IDHISTORICO). Cobertura
   medida: 100% de las lineas. Si manana renombran un articulo, la huella de
   ayer NO cambia; para eso existe.
   Del maestro ARTICULOS se toma SOLO lo imprescindible, y cada columna dice
   por que esta (sufijo _HOY).

   MULTIBASE
   ---------
   La clave natural incluye BASE_ORIGEN porque VENTA se renumera por caja Y se
   repite entre bases. Las zonas (SUR, NORTE, OESTE...) se dan de alta en
   CFG_BASES_ORIGEN, no se tocan estos scripts.

   CLIMA
   -----
   CLIMA_KEY_DIA y CLIMA_KEY_HORA quedan listas para pegar la API del clima,
   por dia o por dia+hora. El join va SIEMPRE junto con SUCURSAL: el clima es
   distinto en Lanus que en Fiorito.

   Creado: 2026-09-15
   =========================================================================== */

USE DF_DTW;
GO

-- ---------------------------------------------------------------------------
-- Alta de bases de origen. Agregar una zona nueva = insertar una fila aca.
-- ---------------------------------------------------------------------------
IF OBJECT_ID('dbo.CFG_BASES_ORIGEN', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.CFG_BASES_ORIGEN (
        BASE_ORIGEN   sysname       NOT NULL PRIMARY KEY,
        ZONA          varchar(20)   NOT NULL,
        DESCRIPCION   varchar(100)  NULL,
        ACTIVA        bit           NOT NULL CONSTRAINT DF_CFG_BASES_ACTIVA DEFAULT (1),
        FECHA_ALTA    datetime2(0)  NOT NULL CONSTRAINT DF_CFG_BASES_FECHA  DEFAULT (SYSDATETIME())
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM dbo.CFG_BASES_ORIGEN WHERE BASE_ORIGEN = 'SRV_GRIDO_ZSUR')
    INSERT dbo.CFG_BASES_ORIGEN (BASE_ORIGEN, ZONA, DESCRIPCION)
    VALUES ('SRV_GRIDO_ZSUR', 'SUR', 'Grido Zona Sur - Lanus, Escalada, Fiorito, Mayorista');
GO

-- ---------------------------------------------------------------------------
-- La huella
-- ---------------------------------------------------------------------------
IF OBJECT_ID('dbo.TRX_HUELLA_VENTA', 'U') IS NOT NULL
    DROP TABLE dbo.TRX_HUELLA_VENTA;
GO

CREATE TABLE dbo.TRX_HUELLA_VENTA (
    -- === A. Origen y carga =================================================
    BASE_ORIGEN             sysname        NOT NULL,
    ZONA                    varchar(20)    NULL,
    FECHA_OPERATIVA         date           NOT NULL,
    FECHA_CARGA             datetime2(0)   NOT NULL,

    -- === B. Identidad de la transaccion ====================================
    SUCURSAL                int            NOT NULL,
    SUCURSAL_CODIGO         varchar(10)    NULL,
    SUCURSAL_DESCRIP        varchar(30)    NULL,
    CAJA                    int            NOT NULL,
    VENTA                   int            NOT NULL,
    DETVENTA                int            NOT NULL,
    -- Listas para COUNT(DISTINCT) sin tener que concatenar a mano.
    TICKET_KEY              varchar(90)    NOT NULL,
    LINEA_KEY               varchar(110)   NOT NULL,

    -- === C. Tiempo =========================================================
    FECHA_HORA              datetime       NOT NULL,
    FECHA                   date           NOT NULL,
    HORA                    tinyint        NOT NULL,
    MINUTO                  tinyint        NOT NULL,
    -- Claves de join para el clima. Siempre combinar con SUCURSAL.
    CLIMA_KEY_DIA           date           NOT NULL,
    CLIMA_KEY_HORA          datetime       NOT NULL,
    ANIO                    smallint       NOT NULL,
    MES                     tinyint        NOT NULL,
    DIA                     tinyint        NOT NULL,
    DIA_SEMANA              tinyint        NOT NULL,   -- 1 = lunes (DATEFIRST 1)
    NOMBRE_DIA              varchar(10)    NULL,
    SEMANA_ANIO             tinyint        NULL,
    ES_FIN_SEMANA           bit            NULL,
    PERIODO                 varchar(10)    NULL,       -- 01/MM/AA

    -- === D. Cabecera de la venta (VENTAS completa) =========================
    TURNO                   int            NULL,
    USULOGIN                varchar(20)    NULL,
    USUARIO_NOMBRE          varchar(30)    NULL,
    VTAESTADO               varchar(10)    NULL,
    VTAIMPORTE              numeric(16,4)  NULL,       -- total del TICKET: no sumar a este grano
    VTADELIVERY             bit            NULL,
    VTAOPERACION            varchar(2)     NULL,
    CONDVTAPOS              varchar(2)     NULL,
    CONDVTAPOS_DESCRIP      varchar(12)    NULL,
    CLIENTE                 int            NULL,
    CLIENTE_NOMBRE          varchar(50)    NULL,
    VTACANAL                int            NULL,
    CANAL_DESCRIP           varchar(20)    NULL,
    CANALVTA                char(1)        NULL,       -- M/G/L/C, derivado como SmartFran
    CANALCOMERCIAL          int            NULL,
    VTAPVTA                 int            NULL,
    VTANUMERO               int            NULL,
    COMPROBANTE             int            NULL,
    CTACTE                  int            NULL,
    LOYALTYSALEID           int            NULL,
    ES_CLUB_GRIDO           bit            NULL,
    VTAPTOVTA               int            NULL,
    FREEZER                 int            NULL,
    TURNOCIERRE             int            NULL,
    VTARENDICION            int            NULL,
    VTAFECRENDICION         datetime       NULL,
    VTAREIMPRESIONES        int            NULL,
    VTAFECREIMPRESION       datetime       NULL,
    VTAFECANULACION         datetime       NULL,
    SALEHUBSENDERID         varchar(100)   NULL,
    SALEHUBSALEID           varchar(100)   NULL,
    RG5334_PERCEP21         numeric(16,4)  NULL,
    RG5334_PERCEP105        numeric(16,4)  NULL,
    PERCEP_IIBB             decimal(10,2)  NULL,
    MP_PAYID                varchar(20)    NULL,
    -- Vacias en SRV_GRIDO_ZSUR, pero pueden venir cargadas en otra zona.
    TIPOCOMPROBANTE         nvarchar(10)   NULL,
    SERIE                   nvarchar(2)    NULL,
    ROLLO                   int            NULL,
    LISTAPRECIOS            int            NULL,
    NUMERO                  int            NULL,
    ESTABLECIMIENTO         int            NULL,
    IVAVENTA                int            NULL,

    -- === E. Promociones y sobreventa =======================================
    -- SOBREVENTA es EL registro de si el cliente acepto la promo que le
    -- ofrecieron en el mostrador. Verificado: ACEPTADA <=> la venta tiene una
    -- linea cuyo PROMOCION apunta a un articulo de tipo SOBREVENTA (930 = 930
    -- en agosto 2026); RECHAZADA y "sin oferta" nunca la tienen.
    SOBREVENTA              varchar(10)    NULL,
    SV_HUBO_OFERTA          bit            NULL,       -- SOBREVENTA no es NULL
    SV_ACEPTADA             bit            NULL,
    SV_RECHAZADA            bit            NULL,
    -- A nivel linea: que se acepto exactamente.
    LINEA_ES_SOBREVENTA     bit            NULL,
    LINEA_ES_PROMOCION      bit            NULL,
    LINEA_ES_CANJE          bit            NULL,
    PROMOCION               int            NULL,
    PROMOCION_DESCRIP       varchar(50)    NULL,
    PROMOCION_TIPO          varchar(10)    NULL,

    -- === F. Linea del ticket (DETVENTAS completa) ==========================
    LINEA_DESCRIP           varchar(30)    NULL,       -- lo que se imprimio en el ticket
    ARTICULO                int            NULL,
    ARTVERSION              int            NULL,       -- puntero a la huella del articulo
    CANT                    numeric(16,4)  NULL,
    PRECIO                  numeric(16,4)  NULL,       -- unitario
    DESCUENTO               numeric(16,4)  NULL,       -- unitario, no total de linea
    COSTO_UNIT              numeric(16,4)  NULL,
    PROMO                   tinyint        NULL,       -- 0 normal, 1 promocionado, 2 no facturable
    ES_FACTURABLE           bit            NULL,
    IVAPORCENTAJE           numeric(8,3)   NULL,
    IMPINTERNO              numeric(16,4)  NULL,

    -- === G. Medidas (formulas de SmartFran, ya resueltas) ==================
    -- Estas columnas valen CERO en las lineas anuladas y en las PROMO=2, asi
    -- que sumarlas siempre da el numero de SmartFran. No hace falta acordarse
    -- de ningun WHERE.
    CANTIDAD                numeric(28,8)  NULL,
    IMPORTE                 numeric(28,8)  NULL,       -- CANT*PRECIO
    DESCUENTOS              numeric(28,8)  NULL,       -- CANT*DESCUENTO
    COSTO                   numeric(28,8)  NULL,
    UTILIDAD                numeric(28,8)  NULL,
    KILOS                   numeric(28,8)  NULL,

    -- === G2. Lo anulado, valorizado aparte =================================
    -- La anulacion se carga para poder analizarla, pero su plata NO puede
    -- colarse en un SUM(IMPORTE) por descuido. Entonces va en columnas
    -- propias: ES_ANULADA avisa, y estas permiten ponerle precio cuando se
    -- quiere medir cuanto se anulo.
    ES_ANULADA              bit            NULL,
    IMPORTE_ANULADO         numeric(28,8)  NULL,
    CANTIDAD_ANULADA        numeric(28,8)  NULL,
    COSTO_ANULADO           numeric(28,8)  NULL,
    KILOS_ANULADOS          numeric(28,8)  NULL,

    -- === G3. Consumo de insumos y contribucion marginal ====================
    /* La receta del articulo vendido, ya resuelta a consumo y a plata, en la
       MISMA fila: no se explota en varias filas para no romper el grano.
       La vista dbo.V_HUELLA_INSUMO hace la explosion cuando hace falta.

       Siete slots porque ese es el techo real: ningun articulo vendido entre
       2024 y 2026 declara mas de 7 insumos (comps 4 a 10 de ARTICULOSHISTORICO).

       CONSUMO esta en UNIDADES (cantidad vendida x cantidad de receta).
       COSTO_UNIT esta por UNIDAD, ya dividido por las unidades del bulto:
       el maestro guarda el costo del paquete, no el de la servilleta suelta.
       Y sale de DIM_INSUMO_COSTO por fecha de venta, no del maestro de hoy:
       la servilleta paso de $580 a $137.405, asi que costear 2024 a valores de
       hoy no significaria nada. */
    INSUMO1_ARTICULO        int            NULL,
    INSUMO1_CONSUMO         numeric(18,6)  NULL,
    INSUMO1_COSTO_UNIT      numeric(18,6)  NULL,
    INSUMO1_COSTO           numeric(18,4)  NULL,
    INSUMO2_ARTICULO        int            NULL,
    INSUMO2_CONSUMO         numeric(18,6)  NULL,
    INSUMO2_COSTO_UNIT      numeric(18,6)  NULL,
    INSUMO2_COSTO           numeric(18,4)  NULL,
    INSUMO3_ARTICULO        int            NULL,
    INSUMO3_CONSUMO         numeric(18,6)  NULL,
    INSUMO3_COSTO_UNIT      numeric(18,6)  NULL,
    INSUMO3_COSTO           numeric(18,4)  NULL,
    INSUMO4_ARTICULO        int            NULL,
    INSUMO4_CONSUMO         numeric(18,6)  NULL,
    INSUMO4_COSTO_UNIT      numeric(18,6)  NULL,
    INSUMO4_COSTO           numeric(18,4)  NULL,
    INSUMO5_ARTICULO        int            NULL,
    INSUMO5_CONSUMO         numeric(18,6)  NULL,
    INSUMO5_COSTO_UNIT      numeric(18,6)  NULL,
    INSUMO5_COSTO           numeric(18,4)  NULL,
    INSUMO6_ARTICULO        int            NULL,
    INSUMO6_CONSUMO         numeric(18,6)  NULL,
    INSUMO6_COSTO_UNIT      numeric(18,6)  NULL,
    INSUMO6_COSTO           numeric(18,4)  NULL,
    INSUMO7_ARTICULO        int            NULL,
    INSUMO7_CONSUMO         numeric(18,6)  NULL,
    INSUMO7_COSTO_UNIT      numeric(18,6)  NULL,
    INSUMO7_COSTO           numeric(18,4)  NULL,

    INSUMOS_CANT            tinyint        NULL,   -- cuantos slots trajo la receta
    /* SOLO los descartables (envase, cuchara, servilleta, salsa...).
       NO incluye los comps de tipo M. PRIMA, que son el producto en si:
       verificado que el comp M. PRIMA apunta al MISMO articulo vendido en 599
       de 627 casos y que su costo es identico a DETVENTAS.COSTO. Sumarlos
       contaria el producto dos veces: en una jornada eran $1,82 M de $2,24 M
       de supuestos insumos, y hundia la contribucion marginal a negativo. */
    INSUMOS_COSTO           numeric(18,4)  NULL,
    /* Los comps M. PRIMA, aparte. Deberia dar parecido a COSTO; si difiere
       mucho, el maestro tiene el costo del producto cargado en dos lados. */
    INSUMOS_COSTO_MPRIMA    numeric(18,4)  NULL,
    -- Cuantos insumos quedaron sin costear (sin unidades por bulto o sin
    -- version vigente). Si es > 0, INSUMOS_COSTO esta subvaluado y la
    -- contribucion marginal queda optimista: hay que poder detectarlo.
    INSUMOS_SIN_COSTO       tinyint        NULL,
    -- Helado consumido, en kilos: los comps 1 a 3 apuntan al generico HELADO.
    -- Su costo ya esta dentro de COSTO (DETVENTAS.COSTO es el del producto),
    -- por eso no se vuelve a sumar.
    HELADO_CONSUMO_KG       numeric(18,6)  NULL,

    /* CONTRIBUCION MARGINAL REAL de la linea:
           IMPORTE  -  COSTO (producto)  -  INSUMOS_COSTO (descartables)
       Se verifico que DETVENTAS.COSTO es el costo del PRODUCTO y no incluye
       los descartables (un pote de 1 kilo: costo 4.688,02 de helado contra
       656,07 de termico, bolsa, servilletas y cucharas), asi que los dos
       terminos se suman y no se solapan.
       No se resta DESCUENTO: la venta que reconoce SmartFran es CANT*PRECIO
       y el descuento es informativo. Ver la nota de PROMO=2 mas arriba. */
    CONTRIB_MARGINAL        numeric(18,4)  NULL,

    -- === H. Articulo: LA HUELLA (ARTICULOSHISTORICO) =======================
    ART_DESCRIP             varchar(50)    NULL,
    ART_DESCRIP_TICKET      varchar(18)    NULL,
    ART_CODIGO              varchar(10)    NULL,
    ART_TIPO                varchar(10)    NULL,
    ART_VENTA               varchar(2)     NULL,
    ART_GRUPO               int            NULL,
    ART_GRUPO_DESCRIP       varchar(20)    NULL,
    ART_GENERICO            int            NULL,
    ART_GENERICO_DESCRIP    varchar(30)    NULL,
    ART_RUBROCOMERCIAL      int            NULL,
    ART_RUBROCOM_DESCRIP    nvarchar(100)  NULL,
    ART_RUBROCOM_UNIDAD     nvarchar(100)  NULL,
    ART_IVATASA             int            NULL,
    ART_IVA_DESCRIP         varchar(20)    NULL,
    ART_PESO                numeric(10,3)  NULL,
    ART_COMP1CANT           numeric(10,3)  NULL,
    ART_COMP2CANT           numeric(10,3)  NULL,
    ART_COMP3CANT           numeric(10,3)  NULL,
    ART_COSTO_VIGENTE       numeric(16,4)  NULL,       -- costo del maestro al momento de la venta
    ART_PRECIO_LISTA        numeric(16,4)  NULL,       -- ARTPRECIONORMAL1 historico
    ART_UNID_COMERCIALES    decimal(16,4)  NULL,
    ART_PROVEEDOR           int            NULL,
    ART_LOYALTYID           int            NULL,
    ART_LOYALTYPOINTS       int            NULL,

    -- === I. Del maestro de HOY: solo lo imprescindible =====================
    -- ART_TIPO_HOY es el unico campo del maestro que entra en un calculo: la
    -- formula de kilos de SmartFran clasifica ELABORADO por el tipo ACTUAL.
    -- Sacarlo romperia la paridad ya validada, por eso esta.
    ART_TIPO_HOY            varchar(10)    NULL,
    -- ART_ESTADO_HOY es, por definicion, un dato de hoy: dice si el articulo
    -- se sigue vendiendo. No participa de ningun calculo.
    ART_ESTADO_HOY          varchar(10)    NULL,

    -- === J. Medio de pago real =============================================
    -- VENTAS.CONDVTAPOS dice 'OT' para todas las plataformas. El medio real
    -- esta en detventasfpago -> condvtaposdet, y ahi aparecen PedidosYa,
    -- Rappi, UberEats, Glovo, PediGrido, Croni.
    PAGO_CANT_MEDIOS        int            NULL,
    PAGO_COD                varchar(10)    NULL,
    PAGO_DESCRIP            varchar(50)    NULL,
    PAGO_CONDVTAPOS         varchar(2)     NULL,
    PAGO_IMPORTE            numeric(16,4)  NULL,       -- del TICKET: no sumar a este grano
    PAGO_DETALLE            varchar(400)   NULL,       -- 'EF:1000,00|TD:500,00' si hubo pago partido
    ES_PLATAFORMA_DELIVERY  bit            NULL,
    PLATAFORMA              varchar(50)    NULL,       -- nombre de la plataforma, si la hubo

    -- === K. Comprobante fiscal (COMPROBANTES) ==============================
    -- Una venta ANULADA tiene mas de un comprobante (el original y su nota de
    -- credito). Se guarda el que apunta VENTAS.COMPROBANTE y se deja el conteo,
    -- para que la anulacion no pase inadvertida.
    FISCAL_CANT_COMPROB     int            NULL,
    FISCAL_TIPO             varchar(2)     NULL,
    FISCAL_PVTA             int            NULL,
    FISCAL_NUMERO           int            NULL,
    FISCAL_NETO             numeric(16,4)  NULL,
    FISCAL_EXENTO           numeric(16,4)  NULL,
    FISCAL_IVA              numeric(16,4)  NULL,
    FISCAL_TOTAL            numeric(16,4)  NULL,
    FISCAL_CAE              varchar(25)    NULL,
    FISCAL_CAEVTO           varchar(10)    NULL,
    FISCAL_IVATIPO          varchar(2)     NULL,
    FISCAL_CUIT             varchar(20)    NULL,

    -- === L. Turno (TURNOS) =================================================
    TURNO_USULOGIN          varchar(20)    NULL,
    TURNO_INICIA            datetime       NULL,
    TURNO_APERTURA          datetime       NULL,
    TURNO_CIERRE            datetime       NULL,
    TURNO_TOTALCAJA         numeric(16,4)  NULL,
    TURNO_CAJATEORICA       numeric(16,4)  NULL,
    TURNO_DIFERENCIA        numeric(16,4)  NULL,

    -- === M. Pedido / plataforma (pedidos) ==================================
    -- OJO: estas tres columnas son DATOS PERSONALES del cliente que pidio a
    -- domicilio. Se incluyen a pedido expreso. Tenerlo presente antes de
    -- exportar la tabla, compartirla o darle acceso a terceros.
    PEDIDO_DIRECCION        varchar(200)   NULL,
    PEDIDO_TELEFONO         varchar(25)    NULL,
    PEDIDO_MAIL             varchar(100)   NULL,
    PEDIDO_ID               int            NULL,
    PEDIDO_PLATAFORMA_ID    int            NULL,
    PEDIDO_IDENTIFICADOR    varchar(50)    NULL,
    PEDIDO_ESTADO           varchar(25)    NULL,
    PEDIDO_FECHAHORA        datetime       NULL,
    PEDIDO_A_ENTREGAR       datetime       NULL,
    PEDIDO_COSTO_ENVIO      numeric(16,4)  NULL,
    PEDIDO_DESCUENTO        numeric(16,4)  NULL,
    PEDIDO_SUBTOTAL         numeric(16,4)  NULL,
    PEDIDO_TOTAL_PLATAFORMA numeric(16,4)  NULL,
    PEDIDO_VOUCHER          varchar(200)   NULL,
    PEDIDO_PAGADO_ONLINE    bit            NULL,
    PEDIDO_RETIRA_EN_LOCAL  bit            NULL,
    PEDIDO_DELIVERY_PROPIO  bit            NULL,
    PEDIDO_PREORDEN         bit            NULL,

    CONSTRAINT PK_TRX_HUELLA_VENTA
        PRIMARY KEY CLUSTERED (BASE_ORIGEN, SUCURSAL, CAJA, VENTA, DETVENTA)
);
GO

-- Recarga de un dia: el loader borra por (BASE_ORIGEN, FECHA_OPERATIVA).
CREATE INDEX IX_HUELLA_CARGA   ON dbo.TRX_HUELLA_VENTA (BASE_ORIGEN, FECHA_OPERATIVA);
-- Join del clima y cortes por tiempo.
CREATE INDEX IX_HUELLA_CLIMA   ON dbo.TRX_HUELLA_VENTA (CLIMA_KEY_HORA, SUCURSAL);
CREATE INDEX IX_HUELLA_FECHA   ON dbo.TRX_HUELLA_VENTA (FECHA_OPERATIVA, SUCURSAL)
       INCLUDE (IMPORTE, KILOS, CANTIDAD, TICKET_KEY);
-- Analisis por articulo.
CREATE INDEX IX_HUELLA_ART     ON dbo.TRX_HUELLA_VENTA (ARTICULO, FECHA_OPERATIVA);
-- Impacto de promociones.
CREATE INDEX IX_HUELLA_SV      ON dbo.TRX_HUELLA_VENTA (SOBREVENTA, FECHA_OPERATIVA);
GO

-- ---------------------------------------------------------------------------
-- Bitacora: sin esto, una tarea diaria desatendida falla en silencio.
-- ---------------------------------------------------------------------------
IF OBJECT_ID('dbo.LOG_CARGA_HUELLA', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.LOG_CARGA_HUELLA (
        LOG_ID          int IDENTITY(1,1) PRIMARY KEY,
        BASE_ORIGEN     sysname        NOT NULL,
        FECHA_OPERATIVA date           NOT NULL,
        DESDE           datetime       NOT NULL,
        HASTA           datetime       NOT NULL,
        FILAS_BORRADAS  int            NULL,
        FILAS_INSERTADAS int           NULL,
        TICKETS         int            NULL,
        IMPORTE         numeric(28,8)  NULL,
        SEGUNDOS        int            NULL,
        ESTADO          varchar(10)    NOT NULL,
        MENSAJE         varchar(1000)  NULL,
        FECHA_CARGA     datetime2(0)   NOT NULL CONSTRAINT DF_LOG_HUELLA_FECHA DEFAULT (SYSDATETIME())
    );
    CREATE INDEX IX_LOG_HUELLA ON dbo.LOG_CARGA_HUELLA (FECHA_OPERATIVA, BASE_ORIGEN);
END
GO
