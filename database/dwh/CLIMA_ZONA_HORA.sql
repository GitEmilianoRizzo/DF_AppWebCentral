/* ===========================================================================
   DF_DTW.dbo.CLIMA_ZONA_HORA  +  dbo.CFG_UBICACION_CLIMA
   ---------------------------------------------------------------------------
   El clima que hubo en cada sucursal, hora por hora, para cruzar contra
   TRX_HUELLA_VENTA.

   Lo llena la app C:\PILL-DF\APPs\01.02_app_ClimaHuella, que consulta
   Open-Meteo. Se guarda aparte de la huella a proposito: el clima se corrige y
   se completa despues (la API publica datos definitivos con algunos dias de
   demora), mientras que la huella de la venta no se toca nunca mas.

   COMO SE JOINEA
   --------------
   Por HORA:
     JOIN dbo.CLIMA_ZONA_HORA c
       ON c.BASE_ORIGEN = h.BASE_ORIGEN
      AND c.SUCURSAL    = h.SUCURSAL
      AND c.CLIMA_KEY_HORA = h.CLIMA_KEY_HORA
   Por DIA: usar la vista dbo.V_CLIMA_ZONA_DIA y CLIMA_KEY_DIA.

   SIEMPRE con SUCURSAL: el clima de Lanus no es el de Fiorito.

   Creado: 2026-09-15
   =========================================================================== */

USE DF_DTW;
GO

-- ---------------------------------------------------------------------------
-- Donde queda cada sucursal. Una fila por punto a consultar.
-- ---------------------------------------------------------------------------
IF OBJECT_ID('dbo.CFG_UBICACION_CLIMA', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.CFG_UBICACION_CLIMA (
        BASE_ORIGEN   sysname        NOT NULL,
        SUCURSAL      int            NOT NULL,
        NOMBRE        varchar(50)    NULL,
        LOCALIDAD     varchar(50)    NULL,
        DOMICILIO     varchar(100)   NULL,
        LATITUD       decimal(9,6)   NOT NULL,
        LONGITUD      decimal(9,6)   NOT NULL,
        ACTIVA        bit            NOT NULL CONSTRAINT DF_CFG_UBIC_ACTIVA DEFAULT (1),
        FECHA_ALTA    datetime2(0)   NOT NULL CONSTRAINT DF_CFG_UBIC_FECHA  DEFAULT (SYSDATETIME()),
        CONSTRAINT PK_CFG_UBICACION_CLIMA PRIMARY KEY (BASE_ORIGEN, SUCURSAL)
    );
END
GO

/* Coordenadas sembradas a nivel LOCALIDAD, tomadas del domicilio que tiene
   cargado cada sucursal en SUCURSALES. Son aproximadas: alcanzan de sobra para
   clima (las cuatro estan dentro de un radio de ~6 km y la grilla de la API es
   mas gruesa que eso), pero si alguna vez se quiere precision de cuadra, se
   corrigen aca y se recarga. La app no las toca. */
MERGE dbo.CFG_UBICACION_CLIMA AS d
USING (VALUES
    ('SRV_GRIDO_ZSUR', 1, 'Lanus Oeste', 'Lanus',                'Av. San Martin 3866',    -34.706000, -58.405000),
    ('SRV_GRIDO_ZSUR', 2, 'Escalada',    'Remedios de Escalada', 'Hipolito Yrigoyen 6179', -34.722200, -58.400300),
    ('SRV_GRIDO_ZSUR', 3, 'Fiorito',     'Villa Fiorito',        'Pilcomayo 270',          -34.702000, -58.456000),
    ('SRV_GRIDO_ZSUR', 4, 'Mayorista',   'Lanus',                'San Martin 3866',        -34.706000, -58.405000)
) AS s (BASE_ORIGEN, SUCURSAL, NOMBRE, LOCALIDAD, DOMICILIO, LATITUD, LONGITUD)
   ON d.BASE_ORIGEN = s.BASE_ORIGEN AND d.SUCURSAL = s.SUCURSAL
WHEN NOT MATCHED THEN
    INSERT (BASE_ORIGEN, SUCURSAL, NOMBRE, LOCALIDAD, DOMICILIO, LATITUD, LONGITUD)
    VALUES (s.BASE_ORIGEN, s.SUCURSAL, s.NOMBRE, s.LOCALIDAD, s.DOMICILIO, s.LATITUD, s.LONGITUD);
GO

-- ---------------------------------------------------------------------------
-- El clima, hora por hora
-- ---------------------------------------------------------------------------
IF OBJECT_ID('dbo.CLIMA_ZONA_HORA', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.CLIMA_ZONA_HORA (
        BASE_ORIGEN        sysname       NOT NULL,
        SUCURSAL           int           NOT NULL,
        ZONA               varchar(20)   NULL,
        SUCURSAL_NOMBRE    varchar(50)   NULL,

        -- Mismas claves y mismos tipos que TRX_HUELLA_VENTA, para que el join
        -- sea directo y sin conversiones.
        CLIMA_KEY_DIA      date          NOT NULL,
        CLIMA_KEY_HORA     datetime      NOT NULL,
        HORA               tinyint       NOT NULL,

        LATITUD            decimal(9,6)  NULL,
        LONGITUD           decimal(9,6)  NULL,

        TEMPERATURA        decimal(6,2)  NULL,   -- C
        SENSACION_TERMICA  decimal(6,2)  NULL,   -- C
        HUMEDAD            decimal(6,2)  NULL,   -- %
        PRECIPITACION      decimal(8,3)  NULL,   -- mm
        LLUVIA             decimal(8,3)  NULL,   -- mm
        NUBOSIDAD          decimal(6,2)  NULL,   -- %
        VIENTO_VELOCIDAD   decimal(6,2)  NULL,   -- km/h
        VIENTO_DIRECCION   decimal(6,2)  NULL,   -- grados
        PRESION            decimal(8,2)  NULL,   -- hPa
        CODIGO_TIEMPO      int           NULL,   -- WMO weather code
        DESCRIPCION_TIEMPO varchar(60)   NULL,
        ES_DE_DIA          bit           NULL,
        LLOVIO             bit           NULL,   -- precipitacion > 0

        FUENTE             varchar(20)   NULL,   -- forecast | archive
        FECHA_CARGA        datetime2(0)  NOT NULL CONSTRAINT DF_CLIMA_FECHA DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_CLIMA_ZONA_HORA
            PRIMARY KEY CLUSTERED (BASE_ORIGEN, SUCURSAL, CLIMA_KEY_HORA)
    );

    CREATE INDEX IX_CLIMA_DIA ON dbo.CLIMA_ZONA_HORA (CLIMA_KEY_DIA, SUCURSAL);
END
GO

-- ---------------------------------------------------------------------------
-- Grano diario, por si el cruce termina siendo por dia y no por hora.
-- Se promedia lo continuo y se acumula la lluvia: promediar milimetros no
-- tendria sentido.
-- ---------------------------------------------------------------------------
IF OBJECT_ID('dbo.V_CLIMA_ZONA_DIA', 'V') IS NOT NULL
    DROP VIEW dbo.V_CLIMA_ZONA_DIA;
GO

CREATE VIEW dbo.V_CLIMA_ZONA_DIA
AS
SELECT
    BASE_ORIGEN,
    SUCURSAL,
    ZONA,
    SUCURSAL_NOMBRE,
    CLIMA_KEY_DIA,
    HORAS_CON_DATO      = COUNT(*),
    TEMP_MEDIA          = AVG(TEMPERATURA),
    TEMP_MINIMA         = MIN(TEMPERATURA),
    TEMP_MAXIMA         = MAX(TEMPERATURA),
    SENSACION_MEDIA     = AVG(SENSACION_TERMICA),
    HUMEDAD_MEDIA       = AVG(HUMEDAD),
    PRECIPITACION_TOTAL = SUM(PRECIPITACION),
    LLUVIA_TOTAL        = SUM(LLUVIA),
    NUBOSIDAD_MEDIA     = AVG(NUBOSIDAD),
    VIENTO_MEDIO        = AVG(VIENTO_VELOCIDAD),
    VIENTO_MAXIMO       = MAX(VIENTO_VELOCIDAD),
    PRESION_MEDIA       = AVG(PRESION),
    HORAS_CON_LLUVIA    = SUM(CAST(LLOVIO AS int)),
    LLOVIO_EN_EL_DIA    = CAST(CASE WHEN SUM(CAST(LLOVIO AS int)) > 0 THEN 1 ELSE 0 END AS bit),
    -- Como "clima del dia" se toma el peor codigo WMO: la escala es creciente
    -- en severidad, asi que el maximo es el evento mas fuerte de la jornada.
    CODIGO_TIEMPO_PEOR  = MAX(CODIGO_TIEMPO)
FROM dbo.CLIMA_ZONA_HORA
GROUP BY BASE_ORIGEN, SUCURSAL, ZONA, SUCURSAL_NOMBRE, CLIMA_KEY_DIA;
GO
