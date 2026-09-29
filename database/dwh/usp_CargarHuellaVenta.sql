/* ===========================================================================
   DF_DTW.dbo.usp_CargarHuellaVenta
   ---------------------------------------------------------------------------
   Carga diaria de dbo.TRX_HUELLA_VENTA.

   Barre UN DIA OPERATIVO en TODAS las bases activas de CFG_BASES_ORIGEN y
   graba la huella. Al dia siguiente se corre de nuevo y agrega la jornada
   nueva.

   RANGO
   -----
   Jornada D = [D 02:00, D+1 02:00). Es la misma definicion que usa el informe
   diario (rango_dia_operativo en informe_grido.py), corregida el 07/09/2026
   para que la fecha que titula la jornada sea la jornada que contiene.
   OJO: aca el rango es SEMIABIERTO, no BETWEEN como estadventas. Es a
   proposito: con BETWEEN, una venta en el limite exacto se cargaria en dos
   jornadas y quedaria duplicada en la tabla para siempre. La diferencia es de
   un instante y se midio en 0 ventas en todo 2026.

   IDEMPOTENTE
   -----------
   Borra (BASE_ORIGEN, FECHA_OPERATIVA) antes de insertar, asi que se puede
   reprocesar un dia cuantas veces haga falta. La PK ademas impide duplicar.

   QUE SE CARGA
   ------------
   TODAS las lineas de TODAS las ventas del rango, incluidas las ANULADAS y
   las lineas PROMO=2. Es una huella: tiene que estar lo que paso, no solo lo
   que factura. Para que eso no rompa las sumas, las columnas de MEDIDA
   (CANTIDAD, IMPORTE, DESCUENTOS, COSTO, UTILIDAD, KILOS) van en CERO cuando
   la linea no es facturable, y las columnas crudas (CANT, PRECIO, ...) quedan
   intactas. Resultado: SUM(IMPORTE) reproduce a SmartFran sin ningun WHERE.

   Creado: 2026-09-15
   =========================================================================== */

USE DF_DTW;
GO

IF OBJECT_ID('dbo.usp_CargarHuellaVenta', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_CargarHuellaVenta;
GO

CREATE PROCEDURE dbo.usp_CargarHuellaVenta
    /* Jornada a cargar. NULL = ayer, que es lo que corresponde a una tarea que
       corre a la manana siguiente. */
    @FechaOperativa date          = NULL,
    @HoraCorte      time(0)       = '02:00',
    /* NULL = todas las bases ACTIVA=1 de CFG_BASES_ORIGEN. */
    @BasesLectura   varchar(4000) = NULL,
    @Debug          bit           = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET DATEFIRST 1;                       -- lunes = 1, igual que estadventas
    SET XACT_ABORT ON;

    IF @FechaOperativa IS NULL
        SET @FechaOperativa = CAST(DATEADD(day, -1, SYSDATETIME()) AS date);

    DECLARE @desde datetime = DATEADD(minute, DATEDIFF(minute, 0, @HoraCorte),
                                      CAST(@FechaOperativa AS datetime)),
            @hasta datetime = DATEADD(minute, DATEDIFF(minute, 0, @HoraCorte),
                                      CAST(DATEADD(day, 1, @FechaOperativa) AS datetime));

    -- ---------------------------------------------------------------- bases
    DECLARE @bases TABLE (orden int IDENTITY(1,1), base sysname, zona varchar(20));

    IF @BasesLectura IS NULL
        INSERT @bases (base, zona)
        SELECT BASE_ORIGEN, ZONA FROM dbo.CFG_BASES_ORIGEN WHERE ACTIVA = 1;
    ELSE
        INSERT @bases (base, zona)
        SELECT LTRIM(RTRIM(s.value)), ISNULL(c.ZONA, '(sin zona)')
        FROM STRING_SPLIT(@BasesLectura, ',') s
        LEFT JOIN dbo.CFG_BASES_ORIGEN c ON c.BASE_ORIGEN = LTRIM(RTRIM(s.value))
        WHERE LTRIM(RTRIM(s.value)) <> '';

    IF NOT EXISTS (SELECT 1 FROM @bases)
    BEGIN
        RAISERROR('usp_CargarHuellaVenta: no hay ninguna base para procesar. Revisar CFG_BASES_ORIGEN o @BasesLectura.', 16, 1);
        RETURN;
    END

    -- Se validan todas antes de tocar nada: mejor no cargar que cargar a medias.
    DECLARE @mala sysname;
    SELECT TOP 1 @mala = b.base FROM @bases b
    WHERE NOT EXISTS (SELECT 1 FROM sys.databases d WHERE d.name = b.base AND d.state = 0);
    IF @mala IS NOT NULL
    BEGIN
        RAISERROR('usp_CargarHuellaVenta: la base "%s" no existe o no esta ONLINE.', 16, 1, @mala);
        RETURN;
    END

    DECLARE @base sysname, @zona varchar(20), @db nvarchar(300), @sql nvarchar(max),
            @t0 datetime2, @borradas int, @insertadas int, @msg varchar(1000);

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT base, zona FROM @bases ORDER BY orden;
    OPEN cur;
    FETCH NEXT FROM cur INTO @base, @zona;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @db = QUOTENAME(@base);
        SET @t0 = SYSDATETIME();
        SET @borradas = 0; SET @insertadas = 0;

        BEGIN TRY
            DELETE FROM dbo.TRX_HUELLA_VENTA
            WHERE BASE_ORIGEN = @base AND FECHA_OPERATIVA = @FechaOperativa;
            SET @borradas = @@ROWCOUNT;

            /* ---------------------------------------------------------------
               Los satelites se bajan primero a tablas temporales indexadas.
               Motivo medido: en la base de origen, detventasfpago (1,33 M
               filas) es un HEAP SIN NINGUN INDICE y COMPROBANTES (1,57 M) solo
               tiene indice por COMPROBANTE, no por VENTA. Buscarlos con APPLY
               fila por fila obliga a un scan completo por cada linea del dia:
               la carga tardaba 50 segundos. Escalonandolos se hace UN scan de
               cada tabla y despues se busca por indice.
               Se resuelve del lado del DTW a proposito: no se agregan indices
               a la base productiva.
               --------------------------------------------------------------- */
            SET @sql = N'
SELECT cp.VENTA, cp.SUCURSAL, cp.CAJA, cp.COMPROBANTE, cp.TIPO, cp.PVTA, cp.NUMERO,
       cp.NETO, cp.EXENTO, cp.IVA, cp.TOTAL, cp.CAE, cp.CAEVTO, cp.IVATIPO, cp.CLICUIT
INTO #CP
FROM ' + @db + N'.dbo.COMPROBANTES cp
INNER JOIN ' + @db + N'.dbo.VENTAS v
        ON v.VENTA = cp.VENTA AND v.SUCURSAL = cp.SUCURSAL AND v.CAJA = cp.CAJA
WHERE v.VTAFECHA >= @pDesde AND v.VTAFECHA < @pHasta;
CREATE CLUSTERED INDEX IX_CP ON #CP (VENTA, SUCURSAL, CAJA);

SELECT f.iddetventasfpago, f.idventa, f.sucursal, f.caja, f.idcondvtaposdet,
       f.importe, f.condvtapos
INTO #FP
FROM ' + @db + N'.dbo.detventasfpago f
INNER JOIN ' + @db + N'.dbo.VENTAS v
        ON v.VENTA = f.idventa AND v.SUCURSAL = f.sucursal AND v.CAJA = f.caja
WHERE v.VTAFECHA >= @pDesde AND v.VTAFECHA < @pHasta;
CREATE CLUSTERED INDEX IX_FP ON #FP (idventa, sucursal, caja);

SELECT pd.idPedido, pd.Venta, pd.sucursal, pd.caja, pd.idEntidadGeneradora,
       pd.identificadorPedido, pd.idEstadoPedido, pd.FechaHoraPedido,
       pd.FechaHoraAEntregar, pd.costoEnvio, pd.descuento, pd.subtotal,
       pd.totalDesdePlataforma, pd.voucher, pd.PagadoOnline, pd.RetiraEnLocal,
       pd.deliveryPropio, pd.PreOrden,
       pd.Direccion, pd.telefono, pd.mailCliente
INTO #PED
FROM ' + @db + N'.dbo.pedidos pd
INNER JOIN ' + @db + N'.dbo.VENTAS v
        ON v.VENTA = pd.Venta AND v.SUCURSAL = pd.sucursal AND v.CAJA = pd.caja
WHERE v.VTAFECHA >= @pDesde AND v.VTAFECHA < @pHasta;
CREATE CLUSTERED INDEX IX_PED ON #PED (Venta, sucursal, caja, idPedido);

/* ---------------------------------------------------------------------
   Consumo de insumos, ya costeado y pivoteado a siete slots.
   Se arma aparte y no dentro del INSERT grande por dos motivos: el
   CROSS APPLY que desarma la receta multiplica las filas por siete, y hay
   que volver a colapsarlas antes de tocar la huella; y el costo sale de
   DIM_INSUMO_COSTO por RANGO DE FECHA, que conviene resolver una sola vez.
   --------------------------------------------------------------------- */
SELECT
    e.VENTA, e.SUCURSAL, e.CAJA, e.DETVENTA,
    I1_ART = MAX(CASE WHEN e.SLOT = 1 THEN e.ARTICULO END),
    I1_CON = MAX(CASE WHEN e.SLOT = 1 THEN e.CONSUMO  END),
    I1_CU  = MAX(CASE WHEN e.SLOT = 1 THEN e.COSTO_UNIT END),
    I2_ART = MAX(CASE WHEN e.SLOT = 2 THEN e.ARTICULO END),
    I2_CON = MAX(CASE WHEN e.SLOT = 2 THEN e.CONSUMO  END),
    I2_CU  = MAX(CASE WHEN e.SLOT = 2 THEN e.COSTO_UNIT END),
    I3_ART = MAX(CASE WHEN e.SLOT = 3 THEN e.ARTICULO END),
    I3_CON = MAX(CASE WHEN e.SLOT = 3 THEN e.CONSUMO  END),
    I3_CU  = MAX(CASE WHEN e.SLOT = 3 THEN e.COSTO_UNIT END),
    I4_ART = MAX(CASE WHEN e.SLOT = 4 THEN e.ARTICULO END),
    I4_CON = MAX(CASE WHEN e.SLOT = 4 THEN e.CONSUMO  END),
    I4_CU  = MAX(CASE WHEN e.SLOT = 4 THEN e.COSTO_UNIT END),
    I5_ART = MAX(CASE WHEN e.SLOT = 5 THEN e.ARTICULO END),
    I5_CON = MAX(CASE WHEN e.SLOT = 5 THEN e.CONSUMO  END),
    I5_CU  = MAX(CASE WHEN e.SLOT = 5 THEN e.COSTO_UNIT END),
    I6_ART = MAX(CASE WHEN e.SLOT = 6 THEN e.ARTICULO END),
    I6_CON = MAX(CASE WHEN e.SLOT = 6 THEN e.CONSUMO  END),
    I6_CU  = MAX(CASE WHEN e.SLOT = 6 THEN e.COSTO_UNIT END),
    I7_ART = MAX(CASE WHEN e.SLOT = 7 THEN e.ARTICULO END),
    I7_CON = MAX(CASE WHEN e.SLOT = 7 THEN e.CONSUMO  END),
    I7_CU  = MAX(CASE WHEN e.SLOT = 7 THEN e.COSTO_UNIT END),
    CANT_SLOTS = COUNT(*),
    -- Solo se cuenta como "sin costear" lo que de verdad hay que costear:
    -- los descartables.
    SIN_COSTO  = SUM(CASE WHEN e.ES_MPRIMA = 0 AND e.COSTO_UNIT IS NULL THEN 1 ELSE 0 END),
    -- Descartables: esto es lo que se resta para la contribucion marginal.
    COSTO_TOT  = SUM(CASE WHEN e.ES_MPRIMA = 0
                          THEN e.CONSUMO * ISNULL(e.COSTO_UNIT, 0) ELSE 0 END),
    -- El producto en si, aparte: ya viene en DETVENTAS.COSTO.
    COSTO_MP   = SUM(CASE WHEN e.ES_MPRIMA = 1
                          THEN e.CONSUMO * ISNULL(e.COSTO_UNIT, 0) ELSE 0 END)
INTO #INS
FROM (
    SELECT
        v2.VENTA, v2.SUCURSAL, v2.CAJA, d2.DETVENTA,
        s.SLOT, s.ARTICULO,
        CONSUMO = d2.CANT * s.CANT_RECETA,
        dic.COSTO_UNIT,
        /* Un comp de tipo M. PRIMA no es un descartable: es el producto que se
           esta vendiendo, referenciado desde su propia receta. Se marca para
           no sumarlo al costo de insumos. */
        ES_MPRIMA = CASE WHEN dic.TIPO = ''M. PRIMA'' THEN 1 ELSE 0 END
    FROM {DB}.dbo.VENTAS v2
    INNER JOIN {DB}.dbo.DETVENTAS d2
            ON d2.VENTA = v2.VENTA AND d2.SUCURSAL = v2.SUCURSAL AND d2.CAJA = v2.CAJA
    INNER JOIN {DB}.dbo.ARTICULOSHISTORICO hh ON hh.IDHISTORICO = d2.ARTVERSION
    CROSS APPLY (VALUES
        (1, hh.ARTCOMP4ARTICULO,  hh.ARTCOMP4CANT),
        (2, hh.ARTCOMP5ARTICULO,  hh.ARTCOMP5CANT),
        (3, hh.ARTCOMP6ARTICULO,  hh.ARTCOMP6CANT),
        (4, hh.ARTCOMP7ARTICULO,  hh.ARTCOMP7CANT),
        (5, hh.ARTCOMP8ARTICULO,  hh.ARTCOMP8CANT),
        (6, hh.ARTCOMP9ARTICULO,  hh.ARTCOMP9CANT),
        (7, hh.ARTCOMP10ARTICULO, hh.ARTCOMP10CANT)
    ) s(SLOT, ARTICULO, CANT_RECETA)
    -- El costo vigente al momento de la venta, no el de hoy.
    LEFT JOIN dbo.DIM_INSUMO_COSTO dic
           ON dic.BASE_ORIGEN = @pBase
          AND dic.ARTICULO    = s.ARTICULO
          AND v2.VTAFECHA    >= dic.VIGENTE_DESDE
          AND v2.VTAFECHA     < dic.VIGENTE_HASTA
    WHERE v2.VTAFECHA >= @pDesde AND v2.VTAFECHA < @pHasta
      AND ISNULL(s.ARTICULO, 0) > 0
      AND ISNULL(s.CANT_RECETA, 0) <> 0
) e
GROUP BY e.VENTA, e.SUCURSAL, e.CAJA, e.DETVENTA;
CREATE CLUSTERED INDEX IX_INS ON #INS (VENTA, SUCURSAL, CAJA, DETVENTA);

INSERT INTO dbo.TRX_HUELLA_VENTA (
  BASE_ORIGEN, ZONA, FECHA_OPERATIVA, FECHA_CARGA,
  SUCURSAL, SUCURSAL_CODIGO, SUCURSAL_DESCRIP, CAJA, VENTA, DETVENTA, TICKET_KEY, LINEA_KEY,
  FECHA_HORA, FECHA, HORA, MINUTO, CLIMA_KEY_DIA, CLIMA_KEY_HORA,
  ANIO, MES, DIA, DIA_SEMANA, NOMBRE_DIA, SEMANA_ANIO, ES_FIN_SEMANA, PERIODO,
  TURNO, USULOGIN, USUARIO_NOMBRE, VTAESTADO, VTAIMPORTE, VTADELIVERY, VTAOPERACION,
  CONDVTAPOS, CONDVTAPOS_DESCRIP, CLIENTE, CLIENTE_NOMBRE, VTACANAL, CANAL_DESCRIP,
  CANALVTA, CANALCOMERCIAL, VTAPVTA, VTANUMERO, COMPROBANTE, CTACTE, LOYALTYSALEID,
  ES_CLUB_GRIDO, VTAPTOVTA, FREEZER, TURNOCIERRE, VTARENDICION, VTAFECRENDICION,
  VTAREIMPRESIONES, VTAFECREIMPRESION, VTAFECANULACION, SALEHUBSENDERID, SALEHUBSALEID,
  RG5334_PERCEP21, RG5334_PERCEP105, PERCEP_IIBB, MP_PAYID,
  TIPOCOMPROBANTE, SERIE, ROLLO, LISTAPRECIOS, NUMERO, ESTABLECIMIENTO, IVAVENTA,
  SOBREVENTA, SV_HUBO_OFERTA, SV_ACEPTADA, SV_RECHAZADA,
  LINEA_ES_SOBREVENTA, LINEA_ES_PROMOCION, LINEA_ES_CANJE,
  PROMOCION, PROMOCION_DESCRIP, PROMOCION_TIPO,
  LINEA_DESCRIP, ARTICULO, ARTVERSION, CANT, PRECIO, DESCUENTO, COSTO_UNIT, PROMO,
  ES_FACTURABLE, IVAPORCENTAJE, IMPINTERNO,
  CANTIDAD, IMPORTE, DESCUENTOS, COSTO, UTILIDAD, KILOS,
  ES_ANULADA, IMPORTE_ANULADO, CANTIDAD_ANULADA, COSTO_ANULADO, KILOS_ANULADOS,
  INSUMO1_ARTICULO, INSUMO1_CONSUMO, INSUMO1_COSTO_UNIT, INSUMO1_COSTO,
  INSUMO2_ARTICULO, INSUMO2_CONSUMO, INSUMO2_COSTO_UNIT, INSUMO2_COSTO,
  INSUMO3_ARTICULO, INSUMO3_CONSUMO, INSUMO3_COSTO_UNIT, INSUMO3_COSTO,
  INSUMO4_ARTICULO, INSUMO4_CONSUMO, INSUMO4_COSTO_UNIT, INSUMO4_COSTO,
  INSUMO5_ARTICULO, INSUMO5_CONSUMO, INSUMO5_COSTO_UNIT, INSUMO5_COSTO,
  INSUMO6_ARTICULO, INSUMO6_CONSUMO, INSUMO6_COSTO_UNIT, INSUMO6_COSTO,
  INSUMO7_ARTICULO, INSUMO7_CONSUMO, INSUMO7_COSTO_UNIT, INSUMO7_COSTO,
  INSUMOS_CANT, INSUMOS_COSTO, INSUMOS_COSTO_MPRIMA, INSUMOS_SIN_COSTO,
  HELADO_CONSUMO_KG, CONTRIB_MARGINAL,
  ART_DESCRIP, ART_DESCRIP_TICKET, ART_CODIGO, ART_TIPO, ART_VENTA, ART_GRUPO,
  ART_GRUPO_DESCRIP, ART_GENERICO, ART_GENERICO_DESCRIP, ART_RUBROCOMERCIAL,
  ART_RUBROCOM_DESCRIP, ART_RUBROCOM_UNIDAD, ART_IVATASA, ART_IVA_DESCRIP,
  ART_PESO, ART_COMP1CANT, ART_COMP2CANT, ART_COMP3CANT, ART_COSTO_VIGENTE,
  ART_PRECIO_LISTA, ART_UNID_COMERCIALES, ART_PROVEEDOR, ART_LOYALTYID, ART_LOYALTYPOINTS,
  ART_TIPO_HOY, ART_ESTADO_HOY,
  PAGO_CANT_MEDIOS, PAGO_COD, PAGO_DESCRIP, PAGO_CONDVTAPOS, PAGO_IMPORTE, PAGO_DETALLE,
  ES_PLATAFORMA_DELIVERY, PLATAFORMA,
  FISCAL_CANT_COMPROB, FISCAL_TIPO, FISCAL_PVTA, FISCAL_NUMERO, FISCAL_NETO,
  FISCAL_EXENTO, FISCAL_IVA, FISCAL_TOTAL, FISCAL_CAE, FISCAL_CAEVTO,
  FISCAL_IVATIPO, FISCAL_CUIT,
  TURNO_USULOGIN, TURNO_INICIA, TURNO_APERTURA, TURNO_CIERRE, TURNO_TOTALCAJA,
  TURNO_CAJATEORICA, TURNO_DIFERENCIA,
  PEDIDO_DIRECCION, PEDIDO_TELEFONO, PEDIDO_MAIL,
  PEDIDO_ID, PEDIDO_PLATAFORMA_ID, PEDIDO_IDENTIFICADOR, PEDIDO_ESTADO, PEDIDO_FECHAHORA,
  PEDIDO_A_ENTREGAR, PEDIDO_COSTO_ENVIO, PEDIDO_DESCUENTO, PEDIDO_SUBTOTAL,
  PEDIDO_TOTAL_PLATAFORMA, PEDIDO_VOUCHER, PEDIDO_PAGADO_ONLINE, PEDIDO_RETIRA_EN_LOCAL,
  PEDIDO_DELIVERY_PROPIO, PEDIDO_PREORDEN
)
SELECT
  @pBase, @pZona, @pFechaOp, SYSDATETIME(),
  v.SUCURSAL, RTRIM(s.SUCCODIGO), RTRIM(s.SUCDESCRIP), v.CAJA, v.VENTA, d.DETVENTA,
  @pBase + ''|'' + CAST(v.SUCURSAL AS varchar(6)) + ''|'' + CAST(v.CAJA AS varchar(6)) + ''|'' + CAST(v.VENTA AS varchar(12)),
  @pBase + ''|'' + CAST(v.SUCURSAL AS varchar(6)) + ''|'' + CAST(v.CAJA AS varchar(6)) + ''|'' + CAST(v.VENTA AS varchar(12)) + ''|'' + CAST(d.DETVENTA AS varchar(12)),

  v.VTAFECHA, CAST(v.VTAFECHA AS date), DATEPART(hour, v.VTAFECHA), DATEPART(minute, v.VTAFECHA),
  CAST(v.VTAFECHA AS date),
  DATEADD(hour, DATEPART(hour, v.VTAFECHA), CAST(CAST(v.VTAFECHA AS date) AS datetime)),
  DATEPART(year, v.VTAFECHA), DATEPART(month, v.VTAFECHA), DATEPART(day, v.VTAFECHA),
  DATEPART(weekday, v.VTAFECHA),
  CASE DATEPART(weekday, v.VTAFECHA) WHEN 1 THEN ''Lunes'' WHEN 2 THEN ''Martes''
       WHEN 3 THEN ''Miercoles'' WHEN 4 THEN ''Jueves'' WHEN 5 THEN ''Viernes''
       WHEN 6 THEN ''Sabado'' ELSE ''Domingo'' END,
  DATEPART(iso_week, v.VTAFECHA),
  CASE WHEN DATEPART(weekday, v.VTAFECHA) >= 6 THEN 1 ELSE 0 END,
  ''01/'' + SUBSTRING(CONVERT(char(8), v.VTAFECHA, 3), 4, 5),

  v.TURNO, RTRIM(v.USULOGIN), RTRIM(u.USUAPYNOM), RTRIM(v.VTAESTADO), v.VTAIMPORTE,
  v.VTADELIVERY, RTRIM(v.VTAOPERACION), RTRIM(v.CONDVTAPOS), RTRIM(cv.CVDESCRIP),
  v.CLIENTE, RTRIM(cl.CLINOMBRE), v.VTACANAL, RTRIM(ca.CANDESCRIP),
  CASE WHEN v.VTAOPERACION = ''VF'' THEN ''M'' WHEN v.VTAOPERACION = ''VC'' THEN ''M''
       WHEN v.VTAOPERACION = ''VG'' THEN ''G'' WHEN v.VTAOPERACION = ''VL'' THEN ''L''
       WHEN v.VTAOPERACION = ''CL'' THEN ''C''
       ELSE CASE WHEN v.CLIENTE = 1 THEN ''M'' ELSE ''G'' END END,
  CASE WHEN NULLIF(ca.CANALCOMERCIAL, 0) IS NULL
       THEN CASE WHEN ISNULL(v.VTADELIVERY, 0) > 0 THEN 2 ELSE 1 END
       ELSE ca.CANALCOMERCIAL END,
  v.VTAPVTA, v.VTANUMERO, v.COMPROBANTE, v.CTACTE, v.LOYALTYSALEID,
  CASE WHEN v.VTAOPERACION = ''VL'' THEN 1 ELSE 0 END,
  v.VTAPTOVTA, v.FREEZER, v.TURNOCIERRE, v.VTARENDICION, v.VTAFECRENDICION,
  v.VTAREIMPRESIONES, v.VTAFECREIMPRESION, v.VTAFECANULACION,
  v.SALEHUBSENDERID, v.SALEHUBSALEID,
  v.RG5334_PERCEP21, v.RG5334_PERCEP105, v.PERCEP_IIBB, v.MP_PAYID,
  v.TIPOCOMPROBANTE, v.SERIE, v.ROLLO, v.LISTAPRECIOS, v.NUMERO, v.ESTABLECIMIENTO, v.IVAVENTA,

  -- Promociones: SOBREVENTA es el registro de si el cliente acepto la oferta.
  RTRIM(v.SOBREVENTA),
  CASE WHEN v.SOBREVENTA IS NOT NULL THEN 1 ELSE 0 END,
  CASE WHEN v.SOBREVENTA = ''ACEPTADA''  THEN 1 ELSE 0 END,
  CASE WHEN v.SOBREVENTA = ''RECHAZADA'' THEN 1 ELSE 0 END,
  CASE WHEN p.ARTTIPO = ''SOBREVENTA'' THEN 1 ELSE 0 END,
  CASE WHEN p.ARTTIPO = ''PROMOCION''  THEN 1 ELSE 0 END,
  CASE WHEN p.ARTTIPO = ''CANJE''      THEN 1 ELSE 0 END,
  d.PROMOCION, RTRIM(p.ARTDESCRIP), RTRIM(p.ARTTIPO),

  RTRIM(d.DESCRIP), d.ARTICULO, d.ARTVERSION, d.CANT, d.PRECIO, d.DESCUENTO, d.COSTO, d.PROMO,
  fact.es, d.IVAPORCENTAJE, d.IMPINTERNO,

  -- Medidas: cero si la linea no factura, para que sumar sea siempre seguro.
  CASE WHEN fact.es = 1 THEN d.CANT ELSE 0 END,
  CASE WHEN fact.es = 1 THEN d.CANT * d.PRECIO ELSE 0 END,
  CASE WHEN fact.es = 1 THEN d.CANT * d.DESCUENTO ELSE 0 END,
  CASE WHEN fact.es = 1 THEN d.CANT * d.COSTO ELSE 0 END,
  CASE WHEN fact.es = 1 THEN d.CANT * (d.PRECIO - d.COSTO) ELSE 0 END,
  CASE WHEN fact.es = 1 THEN d.CANT * ISNULL(pe.peso, 0) ELSE 0 END,

  -- Lo anulado, valorizado en columnas propias: nunca se mezcla con lo de
  -- arriba, pero se puede sumar cuando se lo quiere medir. Se excluye PROMO=2
  -- por el mismo motivo que en las medidas normales: esa linea duplicaria.
  anul.es,
  CASE WHEN anul.es = 1 AND d.PROMO <> 2 THEN d.CANT * d.PRECIO ELSE 0 END,
  CASE WHEN anul.es = 1 AND d.PROMO <> 2 THEN d.CANT ELSE 0 END,
  CASE WHEN anul.es = 1 AND d.PROMO <> 2 THEN d.CANT * d.COSTO ELSE 0 END,
  CASE WHEN anul.es = 1 AND d.PROMO <> 2 THEN d.CANT * ISNULL(pe.peso, 0) ELSE 0 END,

  -- ---- insumos: consumo en unidades y su costo a valores de la venta ----
  ins.I1_ART, ins.I1_CON, ins.I1_CU, ins.I1_CON * ins.I1_CU,
  ins.I2_ART, ins.I2_CON, ins.I2_CU, ins.I2_CON * ins.I2_CU,
  ins.I3_ART, ins.I3_CON, ins.I3_CU, ins.I3_CON * ins.I3_CU,
  ins.I4_ART, ins.I4_CON, ins.I4_CU, ins.I4_CON * ins.I4_CU,
  ins.I5_ART, ins.I5_CON, ins.I5_CU, ins.I5_CON * ins.I5_CU,
  ins.I6_ART, ins.I6_CON, ins.I6_CU, ins.I6_CON * ins.I6_CU,
  ins.I7_ART, ins.I7_CON, ins.I7_CU, ins.I7_CON * ins.I7_CU,
  ISNULL(ins.CANT_SLOTS, 0),
  -- El costo de insumos de una linea anulada no se consumio: va en cero, por
  -- el mismo criterio que el resto de las medidas.
  CASE WHEN fact.es = 1 THEN ISNULL(ins.COSTO_TOT, 0) ELSE 0 END,
  CASE WHEN fact.es = 1 THEN ISNULL(ins.COSTO_MP, 0) ELSE 0 END,
  ISNULL(ins.SIN_COSTO, 0),
  CASE WHEN fact.es = 1
       THEN d.CANT * (ISNULL(h.ARTCOMP1CANT,0) + ISNULL(h.ARTCOMP2CANT,0) + ISNULL(h.ARTCOMP3CANT,0))
       ELSE 0 END,
  -- Contribucion marginal: venta menos costo del producto menos descartables.
  CASE WHEN fact.es = 1
       THEN d.CANT * d.PRECIO - d.CANT * d.COSTO - ISNULL(ins.COSTO_TOT, 0)
       ELSE 0 END,

  -- LA HUELLA DEL ARTICULO: ARTICULOSHISTORICO, la version vigente al vender.
  RTRIM(ISNULL(h.ARTDESCRIP, a.ARTDESCRIP)), RTRIM(h.ARTDESCRIPTICKET), RTRIM(h.ARTCODIGO),
  RTRIM(h.ARTTIPO), RTRIM(h.ARTVENTA), h.GRUPO, RTRIM(g.GRUDESCRIP),
  g.GENERICO, RTRIM(ge.GENDESCRIP), h.RUBROCOMERCIAL, rc.RUBDESCRIP, rc.RUBUNIDADMEDIDA,
  h.IVATASA, RTRIM(ti.IVADESCRIP),
  h.ARTPESO, h.ARTCOMP1CANT, h.ARTCOMP2CANT, h.ARTCOMP3CANT,
  h.ARTCOSTO, h.ARTPRECIONORMAL1, h.ARTUNIDADESCOMERCIALES, h.PROVEEDOR,
  h.LOYALTYID, h.LOYALTYPOINTS,

  -- Del maestro de hoy: solo el tipo (lo pide la formula de kilos) y el estado.
  RTRIM(a.ARTTIPO), RTRIM(a.ARTESTADO),

  fp.medios, RTRIM(fp.cod), RTRIM(fp.descrip), RTRIM(fp.condvtapos), fp.importe, fp.detalle,
  CASE WHEN eg.descrip IS NOT NULL
         OR (fp.cod IS NOT NULL AND RTRIM(fp.cod) NOT IN (''EF'',''CC'',''TC'',''TD'',''OT'',''MP''))
       THEN 1 ELSE 0 END,
  COALESCE(RTRIM(eg.descrip),
           CASE WHEN fp.cod IS NOT NULL AND RTRIM(fp.cod) NOT IN (''EF'',''CC'',''TC'',''TD'',''OT'',''MP'')
                THEN RTRIM(fp.descrip) END),

  cp.cant, RTRIM(cp.TIPO), cp.PVTA, cp.NUMERO, cp.NETO, cp.EXENTO, cp.IVA, cp.TOTAL,
  RTRIM(cp.CAE), RTRIM(cp.CAEVTO), RTRIM(cp.IVATIPO), RTRIM(cp.CLICUIT),

  RTRIM(t.USULOGIN), t.TURINICIATURNO, t.TURAPERTURA, t.TURCIERRE,
  t.TURTOTALCAJA, t.TURCAJATEORICA, t.TURDIFERENCIA,

  ped.Direccion, ped.telefono, ped.mailCliente,
  ped.idPedido, ped.idEntidadGeneradora, ped.identificadorPedido, ped.idEstadoPedido,
  ped.FechaHoraPedido, ped.FechaHoraAEntregar, ped.costoEnvio, ped.descuento, ped.subtotal,
  ped.totalDesdePlataforma, ped.voucher, ped.PagadoOnline, ped.RetiraEnLocal,
  ped.deliveryPropio, ped.PreOrden

FROM ' + @db + N'.dbo.VENTAS v
INNER JOIN ' + @db + N'.dbo.DETVENTAS d
        ON d.VENTA = v.VENTA AND d.SUCURSAL = v.SUCURSAL AND d.CAJA = v.CAJA
LEFT JOIN ' + @db + N'.dbo.ARTICULOS           a  ON a.ARTICULO    = d.ARTICULO
LEFT JOIN ' + @db + N'.dbo.ARTICULOS           p  ON p.ARTICULO    = d.PROMOCION
LEFT JOIN ' + @db + N'.dbo.ARTICULOSHISTORICO  h  ON h.IDHISTORICO = d.ARTVERSION
-- El grupo sale del articulo HISTORICO; la descripcion del grupo no tiene
-- version, asi que es la de hoy. Lo mismo para rubro comercial e IVA.
LEFT JOIN ' + @db + N'.dbo.GRUPOS              g  ON g.GRUPO       = h.GRUPO
LEFT JOIN ' + @db + N'.dbo.GENERICOS           ge ON ge.GENERICO   = g.GENERICO
LEFT JOIN ' + @db + N'.dbo.RUBROSCOMERCIALES   rc ON rc.RUBROCOMERCIAL = h.RUBROCOMERCIAL
LEFT JOIN ' + @db + N'.dbo.TASASIVA            ti ON ti.IVATASA    = h.IVATASA
LEFT JOIN ' + @db + N'.dbo.SUCURSALES          s  ON s.SUCURSAL    = v.SUCURSAL
LEFT JOIN ' + @db + N'.dbo.USUARIOS            u  ON u.USULOGIN    = v.USULOGIN
LEFT JOIN ' + @db + N'.dbo.CONDVTAPOS          cv ON cv.CONDVTAPOS = v.CONDVTAPOS
LEFT JOIN ' + @db + N'.dbo.CANALES             ca ON ca.CANAL      = v.VTACANAL
LEFT JOIN ' + @db + N'.dbo.CLIENTES            cl ON cl.CLIENTE    = v.CLIENTE
LEFT JOIN ' + @db + N'.dbo.TURNOS              t  ON t.TURNO = v.TURNO AND t.SUCURSAL = v.SUCURSAL AND t.CAJA = v.CAJA
-- COMPROBANTES se pega por la terna, NO por VENTAS.COMPROBANTE solo: ese id no
-- es unico (1,57 M de filas para 516 mil valores). Pero la terna TAMPOCO basta:
-- una venta ANULADA tiene el comprobante original y su nota de credito, y un
-- LEFT JOIN plano duplicaria la linea. Va por APPLY, priorizando el que apunta
-- VENTAS.COMPROBANTE y con el conteo al lado.
OUTER APPLY (
    SELECT TOP 1 c2.TIPO, c2.PVTA, c2.NUMERO, c2.NETO, c2.EXENTO, c2.IVA, c2.TOTAL,
           c2.CAE, c2.CAEVTO, c2.IVATIPO, c2.CLICUIT,
           cant = COUNT(*) OVER ()
    FROM #CP c2
    WHERE c2.VENTA = v.VENTA AND c2.SUCURSAL = v.SUCURSAL AND c2.CAJA = v.CAJA
    ORDER BY CASE WHEN c2.COMPROBANTE = v.COMPROBANTE THEN 0 ELSE 1 END, c2.COMPROBANTE) cp
OUTER APPLY (
    SELECT TOP 1 pd.idPedido, pd.idEntidadGeneradora, pd.identificadorPedido, pd.idEstadoPedido,
           pd.FechaHoraPedido, pd.FechaHoraAEntregar, pd.costoEnvio, pd.descuento, pd.subtotal,
           pd.totalDesdePlataforma, pd.voucher, pd.PagadoOnline, pd.RetiraEnLocal,
           pd.deliveryPropio, pd.PreOrden, pd.Direccion, pd.telefono, pd.mailCliente
    FROM #PED pd
    WHERE pd.Venta = v.VENTA AND pd.sucursal = v.SUCURSAL AND pd.caja = v.CAJA
    ORDER BY pd.idPedido DESC) ped
LEFT JOIN ' + @db + N'.dbo.EntidadesGeneradoras eg ON eg.idEntidadGeneradora = ped.idEntidadGeneradora
-- Medio de pago real. Va por APPLY y no por join para que un pago partido
-- (1:N, raro pero existe: 19 ventas en 1,3 M) no duplique la linea.
OUTER APPLY (
    SELECT medios  = COUNT(*),
           importe = SUM(f.importe),
           detalle = STRING_AGG(RTRIM(ISNULL(cdx.cod, f.condvtapos)) + '':'' + CAST(CAST(f.importe AS numeric(16,2)) AS varchar(20)), ''|''),
           cod        = MAX(CASE WHEN f.rn = 1 THEN ISNULL(cdx.cod, f.condvtapos) END),
           descrip    = MAX(CASE WHEN f.rn = 1 THEN ISNULL(cdx.descrip, f.condvtapos) END),
           condvtapos = MAX(CASE WHEN f.rn = 1 THEN f.condvtapos END)
    FROM (SELECT x.*, rn = ROW_NUMBER() OVER (ORDER BY x.importe DESC, x.iddetventasfpago)
          FROM #FP x
          WHERE x.idventa = v.VENTA AND x.sucursal = v.SUCURSAL AND x.caja = v.CAJA) f
    LEFT JOIN ' + @db + N'.dbo.condvtaposdet cdx ON cdx.idcondvtaposdet = f.idcondvtaposdet) fp
-- peso: un ELABORADO pesa lo que pesan sus componentes de helado. El tipo se
-- toma del maestro ACTUAL porque asi lo calcula estadventas y romper eso
-- desalinearia los totales ya validados.
CROSS APPLY (SELECT peso = CASE WHEN a.ARTTIPO = ''ELABORADO''
                                THEN ISNULL(h.ARTCOMP1CANT,0) + ISNULL(h.ARTCOMP2CANT,0) + ISNULL(h.ARTCOMP3CANT,0)
                                ELSE h.ARTPESO END) pe
LEFT JOIN #INS ins
       ON ins.VENTA = v.VENTA AND ins.SUCURSAL = v.SUCURSAL
      AND ins.CAJA = v.CAJA AND ins.DETVENTA = d.DETVENTA
CROSS APPLY (SELECT es = CASE WHEN v.VTAESTADO = ''NORMAL'' AND d.PROMO <> 2 THEN 1 ELSE 0 END) fact
CROSS APPLY (SELECT es = CASE WHEN v.VTAESTADO = ''ANULADO'' THEN 1 ELSE 0 END) anul
WHERE v.VTAFECHA >= @pDesde
  AND v.VTAFECHA <  @pHasta;

-- El conteo se devuelve por parametro: leer @@ROWCOUNT despues del EXEC
-- dependeria de que el INSERT sea la ultima sentencia del lote, y este lote
-- tiene varias.
SET @pFilas = @@ROWCOUNT;';

            /* El bloque de insumos usa el marcador {DB} en vez de cortar el
               literal con "' + @db + N'". Con tantos cortes seguidos la
               concatenacion se comia texto y el lote generado salia sin el
               SELECT interno, fallando con "Incorrect syntax near 'ON'".
               Un solo REPLACE al final es mas robusto y se lee mejor. */
            SET @sql = REPLACE(@sql, N'{DB}', @db);

            IF @Debug = 1
            BEGIN
                PRINT '--- ' + @base + ' ---';
                SELECT @sql AS SQL_GENERADO, @desde AS DESDE, @hasta AS HASTA;
            END
            ELSE
            BEGIN
                EXEC sp_executesql @sql,
                     N'@pBase sysname, @pZona varchar(20), @pFechaOp date,
                       @pDesde datetime, @pHasta datetime, @pFilas int OUTPUT',
                     @pBase = @base, @pZona = @zona, @pFechaOp = @FechaOperativa,
                     @pDesde = @desde, @pHasta = @hasta, @pFilas = @insertadas OUTPUT;

                INSERT dbo.LOG_CARGA_HUELLA
                    (BASE_ORIGEN, FECHA_OPERATIVA, DESDE, HASTA, FILAS_BORRADAS,
                     FILAS_INSERTADAS, TICKETS, IMPORTE, SEGUNDOS, ESTADO, MENSAJE)
                -- Una jornada sin ventas no es un exito: puede ser que la base
                -- de origen todavia no sincronizo. Se marca distinto para que
                -- salte a la vista en la bitacora.
                SELECT @base, @FechaOperativa, @desde, @hasta, @borradas, @insertadas,
                       COUNT(DISTINCT CASE WHEN ES_FACTURABLE = 1 THEN TICKET_KEY END),
                       ISNULL(SUM(IMPORTE), 0), DATEDIFF(second, @t0, SYSDATETIME()),
                       CASE WHEN @insertadas = 0 THEN 'VACIO' ELSE 'OK' END,
                       CASE WHEN @insertadas = 0
                            THEN 'La jornada no trajo ninguna venta. Verificar si la base de origen ya sincronizo ese dia.'
                       END
                FROM dbo.TRX_HUELLA_VENTA
                WHERE BASE_ORIGEN = @base AND FECHA_OPERATIVA = @FechaOperativa;
            END
        END TRY
        BEGIN CATCH
            SET @msg = LEFT(ERROR_MESSAGE(), 1000);
            INSERT dbo.LOG_CARGA_HUELLA
                (BASE_ORIGEN, FECHA_OPERATIVA, DESDE, HASTA, FILAS_BORRADAS,
                 FILAS_INSERTADAS, SEGUNDOS, ESTADO, MENSAJE)
            VALUES (@base, @FechaOperativa, @desde, @hasta, @borradas, 0,
                    DATEDIFF(second, @t0, SYSDATETIME()), 'ERROR', @msg);

            CLOSE cur; DEALLOCATE cur;
            -- RAISERROR no acepta date como sustitucion: va convertido a texto.
            DECLARE @fTxt varchar(10) = CONVERT(varchar(10), @FechaOperativa, 23);
            RAISERROR('usp_CargarHuellaVenta: fallo cargando "%s" para %s. %s',
                      16, 1, @base, @fTxt, @msg);
            RETURN;
        END CATCH

        FETCH NEXT FROM cur INTO @base, @zona;
    END
    CLOSE cur;
    DEALLOCATE cur;

    IF @Debug = 1 RETURN;

    -- Resumen de la corrida
    SELECT BASE_ORIGEN, FECHA_OPERATIVA, DESDE, HASTA, FILAS_BORRADAS, FILAS_INSERTADAS,
           TICKETS, IMPORTE, SEGUNDOS, ESTADO
    FROM dbo.LOG_CARGA_HUELLA
    WHERE FECHA_OPERATIVA = @FechaOperativa
      AND LOG_ID > (SELECT ISNULL(MAX(LOG_ID), 0) FROM dbo.LOG_CARGA_HUELLA
                    WHERE FECHA_CARGA < @t0 AND FECHA_OPERATIVA = @FechaOperativa)
    ORDER BY LOG_ID;
END
GO
