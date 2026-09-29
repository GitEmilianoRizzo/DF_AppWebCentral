/* ===========================================================================
   CLIMA_PRONOSTICO_HORA
   ---------------------------------------------------------------------------
   El clima que VIENE, hora por hora y por sucursal. Es lo que permite pasar
   de describir lo que paso a sugerir que hacer.

   POR QUE UNA TABLA APARTE Y NO LA MISMA DE SIEMPRE
   -------------------------------------------------
   CLIMA_ZONA_HORA guarda lo que EFECTIVAMENTE paso y es la base contra la que
   se mide. Un pronostico es otra cosa: se revisa cada vez que se consulta y
   puede estar equivocado. Mezclarlos significaria que la medicion de una
   estrategia se apoye, sin querer, en un pronostico viejo en vez del clima
   real. Separadas, la comparacion "esperado contra real" no se puede
   contaminar.

   Cuando el dia llega, el clima real entra por CLIMA_ZONA_HORA como siempre;
   la fila de pronostico queda y sirve para saber con que informacion se
   decidio.

   SE PISA EN CADA CORRIDA
   -----------------------
   Guarda siempre el pronostico MAS FRESCO por hora. DIAS_ANTICIPACION dice
   con cuanto se miro: un pronostico a 6 dias vale menos que uno a 1, y
   cuando se evalue si una sugerencia fallo hay que poder distinguir entre
   "la estrategia estuvo mal" y "el pronostico erro".
   =========================================================================== */

IF OBJECT_ID('dbo.CLIMA_PRONOSTICO_HORA', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.CLIMA_PRONOSTICO_HORA (
        BASE_ORIGEN        varchar(30)  NOT NULL,
        SUCURSAL           int          NOT NULL,
        SUCURSAL_NOMBRE    varchar(60)  NULL,
        CLIMA_KEY_DIA      date         NOT NULL,
        CLIMA_KEY_HORA     datetime     NOT NULL,
        HORA               tinyint      NOT NULL,
        TEMPERATURA        numeric(6,2) NULL,
        SENSACION_TERMICA  numeric(6,2) NULL,
        HUMEDAD            numeric(6,2) NULL,
        PRECIPITACION      numeric(8,2) NULL,
        LLUVIA             numeric(8,2) NULL,
        NUBOSIDAD          numeric(6,2) NULL,
        VIENTO_VELOCIDAD   numeric(8,2) NULL,
        VIENTO_DIRECCION   numeric(8,2) NULL,
        PRESION            numeric(10,2) NULL,
        CODIGO_TIEMPO      int          NULL,
        DESCRIPCION_TIEMPO varchar(60)  NULL,
        ES_DE_DIA          bit          NULL,
        LLOVIO             bit          NULL,
        /* Con cuantos dias de anticipacion se hizo este pronostico. */
        DIAS_ANTICIPACION  int          NOT NULL,
        FECHA_CONSULTA     datetime2(0) NOT NULL CONSTRAINT DF_CPH_CONS DEFAULT SYSDATETIME(),
        CONSTRAINT PK_CLIMA_PRONOSTICO_HORA
            PRIMARY KEY (BASE_ORIGEN, SUCURSAL, CLIMA_KEY_HORA)
    );

    CREATE NONCLUSTERED INDEX IX_CPH_DIA
        ON dbo.CLIMA_PRONOSTICO_HORA (BASE_ORIGEN, CLIMA_KEY_DIA, SUCURSAL);

    PRINT 'CLIMA_PRONOSTICO_HORA creada.';
END
ELSE
    PRINT 'CLIMA_PRONOSTICO_HORA ya existia.';
GO


/* ---------------------------------------------------------------------------
   Resumen diario del pronostico, que es como lo consume el motor.

   Devuelve la maxima de cada dia y la del dia ANTERIOR, porque el salto
   termico necesita las dos. Para el primer dia del pronostico el anterior
   sale del clima real, no de otro pronostico: ya paso, se sabe.
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_PronosticoDiario
    @Sucursal   int         = NULL,
    @Dias       int         = 7,
    @BaseOrigen varchar(30) = 'SRV_GRIDO_ZSUR'
AS
BEGIN
    SET NOCOUNT ON;

    /* La EXPOSICION se calcula igual que en AGG_VENTA_DIA, con los mismos
       pesos por hora. Tiene que ser la misma definicion a los dos lados: el
       modelo se calibra con la exposicion del pasado y se le pide una
       prediccion con la del futuro. Si una contara las 24 horas parejo y la
       otra las ponderara, estarian hablando de cosas distintas. */
    ;WITH pron AS (
        SELECT p.SUCURSAL, DIA = p.CLIMA_KEY_DIA,
               TMAX = MAX(p.TEMPERATURA),
               TMIN = MIN(p.TEMPERATURA),
               LLUVIA_MM = SUM(ISNULL(p.PRECIPITACION, 0)),
               LLUEVE = MAX(CASE WHEN p.LLUVIA > 0 THEN 1 ELSE 0 END),
               HORAS_LLUVIA = SUM(CASE WHEN p.LLUVIA > 0 THEN 1 ELSE 0 END),
               EXPOSICION = CASE WHEN COUNT(w.PESO) = 0 THEN NULL
                                 ELSE CAST(SUM(CASE WHEN p.LLUVIA > 0 THEN ISNULL(w.PESO, 0) ELSE 0 END) * 100
                                           AS numeric(6,2)) END,
               ANTICIPACION = MIN(p.DIAS_ANTICIPACION)
        FROM dbo.CLIMA_PRONOSTICO_HORA p
        LEFT JOIN dbo.DIM_PESO_HORA w
               ON w.BASE_ORIGEN = p.BASE_ORIGEN AND w.SUCURSAL = p.SUCURSAL AND w.HORA = p.HORA
        WHERE p.BASE_ORIGEN = @BaseOrigen
          AND p.CLIMA_KEY_DIA >= CAST(GETDATE() AS date)
          AND p.CLIMA_KEY_DIA <  DATEADD(day, @Dias, CAST(GETDATE() AS date))
          AND (@Sucursal IS NULL OR p.SUCURSAL = @Sucursal)
        GROUP BY p.SUCURSAL, p.CLIMA_KEY_DIA
    ),
    real_ayer AS (
        SELECT SUCURSAL, DIA = CAST(CLIMA_KEY_HORA AS date), TMAX = MAX(TEMPERATURA)
        FROM dbo.CLIMA_ZONA_HORA
        WHERE BASE_ORIGEN = @BaseOrigen
          AND CLIMA_KEY_HORA >= DATEADD(day, -2, CAST(GETDATE() AS date))
        GROUP BY SUCURSAL, CAST(CLIMA_KEY_HORA AS date)
    )
    SELECT p.SUCURSAL,
           Dia          = p.DIA,
           DiaSemana    = (DATEDIFF(day, '1900-01-01', p.DIA) % 7) + 1,
           TMax         = p.TMAX,
           TMin         = p.TMIN,
           /* La maxima de ayer sale del pronostico del dia previo si existe;
              si no (primer dia), del clima real ya registrado. */
           TMaxAyer     = COALESCE(
                            LAG(p.TMAX) OVER (PARTITION BY p.SUCURSAL ORDER BY p.DIA),
                            (SELECT r.TMAX FROM real_ayer r
                             WHERE r.SUCURSAL = p.SUCURSAL
                               AND r.DIA = DATEADD(day, -1, p.DIA))),
           Llueve       = p.LLUEVE,
           HorasLluvia  = p.HORAS_LLUVIA,
           LluviaMm     = CAST(p.LLUVIA_MM AS numeric(8,2)),
           /* Que porcentaje de la venta del dia cae en horas con lluvia. Es LA
              variable de lluvia: medido sobre 2024-2026, un dia con mas de la
              mitad expuesta vende un 30% menos que un dia seco de la misma
              temperatura y dia de semana, mientras que uno con menos del 10%
              no se distingue de un dia seco. "Llueve si/no" no separa eso. */
           Exposicion   = p.EXPOSICION,
           TramoLluvia  = CASE
                              WHEN p.EXPOSICION IS NULL THEN NULL
                              WHEN p.EXPOSICION = 0  THEN 0
                              WHEN p.EXPOSICION < 10 THEN 1
                              WHEN p.EXPOSICION < 25 THEN 2
                              WHEN p.EXPOSICION < 50 THEN 3
                              ELSE 4 END,
           /* Cuanto se espera que cueste, segun la calibracion de esa sucursal.
              Va con el pronostico para que la sugerencia pueda decir el numero
              en vez de limitarse a avisar que llueve. */
           ImpactoPct   = (SELECT TOP 1 l.IMPACTO_VS_SECO_PCT
                           FROM dbo.DIM_IMPACTO_LLUVIA l
                           WHERE l.BASE_ORIGEN = @BaseOrigen
                             AND l.SUCURSAL IN (p.SUCURSAL, 0)
                             AND l.CONFIABLE = 1
                             AND l.TRAMO = CASE
                                 WHEN p.EXPOSICION IS NULL THEN -1
                                 WHEN p.EXPOSICION = 0  THEN 0
                                 WHEN p.EXPOSICION < 10 THEN 1
                                 WHEN p.EXPOSICION < 25 THEN 2
                                 WHEN p.EXPOSICION < 50 THEN 3
                                 ELSE 4 END
                           -- La propia sucursal primero; la general como respaldo.
                           ORDER BY CASE WHEN l.SUCURSAL = p.SUCURSAL THEN 0 ELSE 1 END),
           Anticipacion = p.ANTICIPACION
    FROM pron p
    ORDER BY p.SUCURSAL, p.DIA;
END
GO
