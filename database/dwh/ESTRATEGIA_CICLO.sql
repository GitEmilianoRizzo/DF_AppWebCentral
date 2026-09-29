/* ===========================================================================
   Ciclo de estrategia: objetivo -> sugerencias -> ejecucion -> medicion
   ---------------------------------------------------------------------------
   Sostiene el circuito:
     1. Damian entra y decide un objetivo
     2. Define si aplica igual a todas las sucursales o distinto por cada una
     3. Fija la ventana de tiempo
     4. Se avisa a los responsables de cada local
     5. La informacion diaria llega sola
     6. Responsables y Damian ven objetivo contra realidad

   POR QUE SE GUARDA LO DECIDIDO
   -----------------------------
   Sin registro de que se propuso, que se acepto y que paso despues, cada
   semana arranca de cero y nunca se aprende. Guardarlo permite dos cosas que
   valen mas que la sugerencia en si: ver si las sugerencias aceptadas rinden
   mejor que las descartadas, y que Damian pueda discutir con el dato.

   CONTRA QUE SE MIDE
   ------------------
   Contra lo ESPERADO DADO EL CLIMA QUE HUBO, no contra la semana anterior ni
   contra el ano pasado. Sin ajustar por clima, cualquier semana calurosa hace
   parecer brillante a cualquier estrategia. El esperado se congela en
   ESTRATEGIA_MEDICION el dia que se mide: si mañana se recalibra el modelo,
   la medicion vieja no cambia sola.
   =========================================================================== */

-- 1) El objetivo declarado --------------------------------------------------
IF OBJECT_ID('dbo.ESTRATEGIA_OBJETIVO', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.ESTRATEGIA_OBJETIVO (
        OBJETIVO_ID   int IDENTITY(1,1) NOT NULL,
        BASE_ORIGEN   varchar(30)  NOT NULL,
        NOMBRE        varchar(120) NOT NULL,
        /* FACTURACION | MARGEN | KILOS. Se elige uno: no son lo mismo y a
           veces se contradicen (un 2x1 sube kilos y baja margen). Pedir las
           tres cosas a la vez es no elegir. */
        METRICA       varchar(20)  NOT NULL,
        FECHA_DESDE   date         NOT NULL,
        FECHA_HASTA   date         NOT NULL,
        ESTADO        varchar(15)  NOT NULL CONSTRAINT DF_EO_ESTADO DEFAULT 'BORRADOR',
        NOTAS         varchar(1000) NULL,
        CREADO_POR    varchar(60)  NULL,
        CREADO_EL     datetime2(0) NOT NULL CONSTRAINT DF_EO_CREADO DEFAULT SYSDATETIME(),
        AVISADO_EL    datetime2(0) NULL,     -- cuando se notifico a los locales
        CERRADO_EL    datetime2(0) NULL,
        CONSTRAINT PK_ESTRATEGIA_OBJETIVO PRIMARY KEY (OBJETIVO_ID),
        CONSTRAINT CK_EO_METRICA CHECK (METRICA IN ('FACTURACION','MARGEN','KILOS')),
        CONSTRAINT CK_EO_ESTADO  CHECK (ESTADO IN ('BORRADOR','VIGENTE','CERRADO','ANULADO')),
        CONSTRAINT CK_EO_RANGO   CHECK (FECHA_HASTA >= FECHA_DESDE)
    );
    PRINT 'ESTRATEGIA_OBJETIVO creada.';
END
GO

-- 2) La meta por sucursal ---------------------------------------------------
IF OBJECT_ID('dbo.ESTRATEGIA_OBJETIVO_SUCURSAL', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.ESTRATEGIA_OBJETIVO_SUCURSAL (
        OBJETIVO_ID   int          NOT NULL,
        SUCURSAL      int          NOT NULL,
        /* La meta se expresa contra lo ESPERADO, no contra un numero fijo:
           "+5% sobre lo que corresponderia a este clima" es exigible; "vender
           10 millones" depende de si hace frio o calor y no mide gestion. */
        META_PCT      numeric(8,2) NOT NULL CONSTRAINT DF_EOS_META DEFAULT 0,
        RESPONSABLE   varchar(120) NULL,
        MAIL          varchar(200) NULL,
        NOTAS         varchar(500) NULL,
        CONSTRAINT PK_ESTRATEGIA_OBJETIVO_SUCURSAL PRIMARY KEY (OBJETIVO_ID, SUCURSAL),
        CONSTRAINT FK_EOS_OBJETIVO FOREIGN KEY (OBJETIVO_ID)
            REFERENCES dbo.ESTRATEGIA_OBJETIVO (OBJETIVO_ID) ON DELETE CASCADE
    );
    PRINT 'ESTRATEGIA_OBJETIVO_SUCURSAL creada.';
END
GO

-- 3) Lo que el motor sugirio y que se decidio -------------------------------
IF OBJECT_ID('dbo.ESTRATEGIA_SUGERENCIA', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.ESTRATEGIA_SUGERENCIA (
        SUGERENCIA_ID int IDENTITY(1,1) NOT NULL,
        OBJETIVO_ID   int          NOT NULL,
        SUCURSAL      int          NULL,      -- NULL = para todas
        FECHA         date         NULL,      -- NULL = para toda la ventana
        HORA_DESDE    tinyint      NULL,
        HORA_HASTA    tinyint      NULL,
        /* PROMO      activar o frenar una promocion
           SOBREVENTA empujar el upsell
           MIX        correr el foco a otro grupo de producto
           OPERATIVO  stock y dotacion (el salto termico cae aca) */
        TIPO          varchar(15)  NOT NULL,
        TITULO        varchar(200) NOT NULL,
        DETALLE       varchar(1000) NULL,
        /* El numero que respalda la sugerencia, en texto legible. Va guardado
           y no recalculado: si manana cambia la calibracion, hay que poder
           ver con que evidencia se decidio en su momento. */
        EVIDENCIA     varchar(1000) NULL,
        IMPACTO_EST   numeric(18,2) NULL,
        ESTADO        varchar(15)  NOT NULL CONSTRAINT DF_ES_ESTADO DEFAULT 'SUGERIDA',
        DECIDIDO_POR  varchar(60)  NULL,
        DECIDIDO_EL   datetime2(0) NULL,
        COMENTARIO    varchar(500) NULL,
        CREADO_EL     datetime2(0) NOT NULL CONSTRAINT DF_ES_CREADO DEFAULT SYSDATETIME(),
        CONSTRAINT PK_ESTRATEGIA_SUGERENCIA PRIMARY KEY (SUGERENCIA_ID),
        CONSTRAINT FK_ES_OBJETIVO FOREIGN KEY (OBJETIVO_ID)
            REFERENCES dbo.ESTRATEGIA_OBJETIVO (OBJETIVO_ID) ON DELETE CASCADE,
        CONSTRAINT CK_ES_TIPO   CHECK (TIPO IN ('PROMO','SOBREVENTA','MIX','OPERATIVO')),
        CONSTRAINT CK_ES_ESTADO CHECK (ESTADO IN ('SUGERIDA','ACEPTADA','DESCARTADA','VENCIDA'))
    );
    CREATE NONCLUSTERED INDEX IX_ES_OBJETIVO
        ON dbo.ESTRATEGIA_SUGERENCIA (OBJETIVO_ID, SUCURSAL, FECHA);
    PRINT 'ESTRATEGIA_SUGERENCIA creada.';
END
GO

-- 4) La medicion diaria -----------------------------------------------------
IF OBJECT_ID('dbo.ESTRATEGIA_MEDICION', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.ESTRATEGIA_MEDICION (
        OBJETIVO_ID   int          NOT NULL,
        SUCURSAL      int          NOT NULL,
        FECHA         date         NOT NULL,
        /* El clima que efectivamente hubo, congelado: es la base de la
           comparacion y no puede quedar sujeto a que manana se recalcule. */
        TMAX          numeric(6,2) NULL,
        TMAX_AYER     numeric(6,2) NULL,
        LLOVIO        bit          NULL,
        FACTOR_SALTO  numeric(8,4) NULL,
        ESPERADO      numeric(18,2) NULL,
        REAL_         numeric(18,2) NULL,
        DESVIO_PCT    numeric(8,2) NULL,
        META_PCT      numeric(8,2) NULL,
        CUMPLE        bit          NULL,
        NIVEL_MODELO  varchar(60)  NULL,   -- con que precision se estimo
        CALCULADO_EL  datetime2(0) NOT NULL CONSTRAINT DF_EM_CALC DEFAULT SYSDATETIME(),
        CONSTRAINT PK_ESTRATEGIA_MEDICION PRIMARY KEY (OBJETIVO_ID, SUCURSAL, FECHA),
        CONSTRAINT FK_EM_OBJETIVO FOREIGN KEY (OBJETIVO_ID)
            REFERENCES dbo.ESTRATEGIA_OBJETIVO (OBJETIVO_ID) ON DELETE CASCADE
    );
    PRINT 'ESTRATEGIA_MEDICION creada.';
END
GO

PRINT '';
PRINT 'Ciclo de estrategia listo.';
GO
