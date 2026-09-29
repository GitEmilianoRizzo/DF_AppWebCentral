/* ===========================================================================
   DIM_IMPACTO_LLUVIA
   ---------------------------------------------------------------------------
   Cuanto cuesta cada tramo de exposicion a la lluvia, por sucursal.

   POR QUE UNA TABLA PROPIA
   ------------------------
   El modelo de medicion ya calcula este factor internamente, pero lo necesitan
   tambien las SUGERENCIAS, que corren antes de que el dia pase. Y hace falta
   poder mostrarle el numero a Damian: una sugerencia que dice "manana llueve
   toda la tarde, espera un 29% menos" se discute; una que dice "va a llover"
   se ignora.

   QUE ES LA EXPOSICION
   -------------------
   El porcentaje de la venta tipica del dia que cae en horas con lluvia,
   ponderado por DIM_PESO_HORA. No es lo mismo que "llovio": medido sobre
   2024-2026, un dia con menos del 10% de exposicion rinde 1,03 y uno con mas
   del 50% rinde 0,71. El bit "llovio" los mete en la misma bolsa y por eso
   reduce el error del modelo cuatro veces menos que el tramo.

   EL FACTOR ES RELATIVO Y YA DESCUENTA LA TEMPERATURA
   ---------------------------------------------------
   Se calcula sobre el residuo despues de sacar el dia de semana y la franja de
   temperatura. Los dias de lluvia suelen ser mas frescos: sin ese control, a la
   lluvia se le atribuiria una caida que en realidad es del termometro.
   =========================================================================== */

IF OBJECT_ID('dbo.DIM_IMPACTO_LLUVIA', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.DIM_IMPACTO_LLUVIA (
        BASE_ORIGEN  varchar(30) NOT NULL,
        SUCURSAL     int         NOT NULL,   -- 0 = todas juntas
        TRAMO        tinyint     NOT NULL,   -- 0 nada .. 4 mas del 50%
        ETIQUETA     varchar(60) NOT NULL,
        EXPOS_DESDE  numeric(6,2) NOT NULL,
        EXPOS_HASTA  numeric(6,2) NOT NULL,
        FACTOR       numeric(8,4) NOT NULL,  -- residuo crudo del tramo
        IMPACTO_PCT  numeric(8,2) NOT NULL,  -- (factor - 1) * 100
        /* Lo mismo pero CONTRA UN DIA SECO del mismo dia de semana y la misma
           temperatura, que es la comparacion que se entiende y la que hay que
           poner en una sugerencia. El factor crudo no esta centrado en 1 porque
           la enorme mayoria de los dias no tiene lluvia y arrastra la base. */
        FACTOR_VS_SECO numeric(8,4) NULL,
        IMPACTO_VS_SECO_PCT numeric(8,2) NULL,
        CASOS        int         NOT NULL,
        CONFIABLE    bit         NOT NULL,
        VENTANA_DESDE date NULL,
        VENTANA_HASTA date NULL,
        FECHA_CALIB  datetime2(0) NOT NULL CONSTRAINT DF_DIL_CALIB DEFAULT SYSDATETIME(),
        CONSTRAINT PK_DIM_IMPACTO_LLUVIA PRIMARY KEY (BASE_ORIGEN, SUCURSAL, TRAMO)
    );
    PRINT 'DIM_IMPACTO_LLUVIA creada.';
END
ELSE
    PRINT 'DIM_IMPACTO_LLUVIA ya existia.';
GO


CREATE OR ALTER PROCEDURE dbo.usp_CalibrarImpactoLluvia
    @Ventana    int         = 28,
    @MinCasos   int         = 15,
    @DesdeHist  date        = '2024-01-01',
    @BaseOrigen varchar(30) = 'SRV_GRIDO_ZSUR'
AS
BEGIN
    SET NOCOUNT ON;

    /* Mismo esquema que el modelo de medicion: el dia relativo a su nivel
       movil, y despues se le sacan el dia de semana y la temperatura. */
    CREATE TABLE #d (
        SUCURSAL int, FECHA date, DIA_SEMANA tinyint, FRANJA int, TRAMO tinyint,
        VAL numeric(18,4), NIVEL numeric(18,4), RATIO numeric(18,6), RESTO numeric(18,6),
        PRIMARY KEY (SUCURSAL, FECHA)
    );

    INSERT #d (SUCURSAL, FECHA, DIA_SEMANA, FRANJA, TRAMO, VAL)
    SELECT SUCURSAL, FECHA, DIA_SEMANA, FRANJA_TMAX, TRAMO_LLUVIA, IMPORTE
    FROM dbo.AGG_VENTA_DIA
    WHERE BASE_ORIGEN = @BaseOrigen AND FECHA >= @DesdeHist;

    UPDATE d SET NIVEL = (SELECT AVG(b.VAL) FROM #d b
                          WHERE b.SUCURSAL = d.SUCURSAL
                            AND b.FECHA >= DATEADD(day, -@Ventana, d.FECHA)
                            AND b.FECHA <  d.FECHA)
    FROM #d d;

    UPDATE #d SET RATIO = VAL / NULLIF(NIVEL, 0) WHERE NIVEL > 0;

    -- Se saca el dia de semana y despues la temperatura.
    UPDATE d SET RESTO = d.RATIO / NULLIF(f.m, 0)
    FROM #d d
    JOIN (SELECT SUCURSAL, DIA_SEMANA, m = AVG(RATIO) FROM #d WHERE RATIO IS NOT NULL
          GROUP BY SUCURSAL, DIA_SEMANA) f
      ON f.SUCURSAL = d.SUCURSAL AND f.DIA_SEMANA = d.DIA_SEMANA
    WHERE d.RATIO IS NOT NULL;

    UPDATE d SET RESTO = d.RESTO / NULLIF(g.m, 0)
    FROM #d d
    JOIN (SELECT SUCURSAL, FRANJA, m = AVG(RESTO) FROM #d WHERE RESTO IS NOT NULL AND FRANJA IS NOT NULL
          GROUP BY SUCURSAL, FRANJA) g
      ON g.SUCURSAL = d.SUCURSAL AND g.FRANJA = d.FRANJA
    WHERE d.RESTO IS NOT NULL AND d.FRANJA IS NOT NULL;

    DELETE FROM dbo.DIM_IMPACTO_LLUVIA WHERE BASE_ORIGEN = @BaseOrigen;

    ;WITH t AS (
        SELECT SUCURSAL, TRAMO, f = AVG(RESTO), n = COUNT(*)
        FROM #d WHERE RESTO IS NOT NULL AND TRAMO IS NOT NULL
        GROUP BY SUCURSAL, TRAMO
        UNION ALL
        -- Sucursal 0: todas juntas, para cuando una no tiene casos propios.
        SELECT 0, TRAMO, AVG(RESTO), COUNT(*)
        FROM #d WHERE RESTO IS NOT NULL AND TRAMO IS NOT NULL
        GROUP BY TRAMO
    )
    INSERT dbo.DIM_IMPACTO_LLUVIA
        (BASE_ORIGEN, SUCURSAL, TRAMO, ETIQUETA, EXPOS_DESDE, EXPOS_HASTA,
         FACTOR, IMPACTO_PCT, CASOS, CONFIABLE, VENTANA_DESDE, VENTANA_HASTA)
    SELECT @BaseOrigen, t.SUCURSAL, t.TRAMO,
           CASE t.TRAMO
               WHEN 0 THEN 'sin lluvia en horario de venta'
               WHEN 1 THEN 'lluvia marginal (menos del 10% de la venta)'
               WHEN 2 THEN 'lluvia sobre el 10 al 25% de la venta'
               WHEN 3 THEN 'lluvia sobre el 25 al 50% de la venta'
               ELSE        'lluvia sobre mas de la mitad de la venta'
           END,
           CASE t.TRAMO WHEN 0 THEN 0 WHEN 1 THEN 0 WHEN 2 THEN 10 WHEN 3 THEN 25 ELSE 50 END,
           CASE t.TRAMO WHEN 0 THEN 0 WHEN 1 THEN 10 WHEN 2 THEN 25 WHEN 3 THEN 50 ELSE 100 END,
           CAST(t.f AS numeric(8,4)),
           CAST((t.f - 1) * 100 AS numeric(8,2)),
           t.n,
           CASE WHEN t.n >= @MinCasos THEN 1 ELSE 0 END,
           (SELECT MIN(FECHA) FROM #d), (SELECT MAX(FECHA) FROM #d)
    FROM t;

    DROP TABLE #d;

    /* Y ahora todo contra el dia seco de la misma sucursal. */
    UPDATE l
    SET FACTOR_VS_SECO = CAST(l.FACTOR / NULLIF(s.FACTOR, 0) AS numeric(8,4)),
        IMPACTO_VS_SECO_PCT = CAST((l.FACTOR / NULLIF(s.FACTOR, 0) - 1) * 100 AS numeric(8,2))
    FROM dbo.DIM_IMPACTO_LLUVIA l
    JOIN dbo.DIM_IMPACTO_LLUVIA s
         ON s.BASE_ORIGEN = l.BASE_ORIGEN AND s.SUCURSAL = l.SUCURSAL AND s.TRAMO = 0
    WHERE l.BASE_ORIGEN = @BaseOrigen;

    SELECT SUCURSAL, TRAMO, ETIQUETA, FACTOR, ImpactoVsSeco = IMPACTO_VS_SECO_PCT,
           CASOS, CONFIABLE
    FROM dbo.DIM_IMPACTO_LLUVIA
    WHERE BASE_ORIGEN = @BaseOrigen
    ORDER BY SUCURSAL, TRAMO;
END
GO

PRINT '';
PRINT 'Impacto de la lluvia listo.';
GO
