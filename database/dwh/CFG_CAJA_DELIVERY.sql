/* ===========================================================================
   CFG_CAJA_DELIVERY
   ---------------------------------------------------------------------------
   Que caja de cada sucursal atiende el delivery (PedidosYa, Rappi y propio).

   POR QUE UNA TABLA Y NO UN TEXTO FIJO
   ------------------------------------
   Damian pidio (02/10/2026) que el Informe Diario diga:
       Cajas Delivery   Escalada: 2   Fiorito: 1   Lanus Oeste: 2
   Si eso se escribe a mano en la pantalla y en el Excel, el dia que un local
   cambie de caja hay que acordarse de tocar dos programas. Con la tabla, el
   cambio es un UPDATE y la leyenda y la marca en la columna Caja salen solas
   en los dos informes.

   Solo se registran las cajas que SON de delivery; una caja que no esta aca
   es de salon.

   Creado: 2026-10-02
   =========================================================================== */

USE DF_DTW;
GO

IF OBJECT_ID('dbo.CFG_CAJA_DELIVERY', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.CFG_CAJA_DELIVERY (
        BASE_ORIGEN  varchar(30)  NOT NULL,
        SUCURSAL     int          NOT NULL,
        CAJA         int          NOT NULL,
        NOTA         varchar(200) NULL,
        ACTUALIZADO  datetime2(0) NOT NULL CONSTRAINT DF_CCD_ACT DEFAULT SYSDATETIME(),
        CONSTRAINT PK_CFG_CAJA_DELIVERY PRIMARY KEY (BASE_ORIGEN, SUCURSAL, CAJA)
    );
    PRINT 'CFG_CAJA_DELIVERY creada.';
END
GO

-- Valores informados por Damian el 02/10/2026. Idempotente.
MERGE dbo.CFG_CAJA_DELIVERY AS d
USING (VALUES
    ('SRV_GRIDO_ZSUR', 2, 2, 'Escalada - informado por Damian 02/10/2026'),
    ('SRV_GRIDO_ZSUR', 3, 1, 'Fiorito - informado por Damian 02/10/2026'),
    ('SRV_GRIDO_ZSUR', 1, 2, 'Lanus Oeste - informado por Damian 02/10/2026')
) AS o (BASE_ORIGEN, SUCURSAL, CAJA, NOTA)
    ON d.BASE_ORIGEN = o.BASE_ORIGEN AND d.SUCURSAL = o.SUCURSAL AND d.CAJA = o.CAJA
WHEN NOT MATCHED THEN INSERT (BASE_ORIGEN, SUCURSAL, CAJA, NOTA)
    VALUES (o.BASE_ORIGEN, o.SUCURSAL, o.CAJA, o.NOTA);
GO
