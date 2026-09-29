/* ===========================================================================
   usp_MedirObjetivo
   ---------------------------------------------------------------------------
   Compara, dia por dia y sucursal por sucursal, lo que se vendio contra lo que
   correspondia AL CLIMA QUE HUBO, y lo congela en ESTRATEGIA_MEDICION.

   COMO SE CONSTRUYE EL ESPERADO
   -----------------------------
       ESPERADO = NIVEL x INDICE x FACTOR_SALTO x CENTRADO

   NIVEL       El nivel actual del negocio en esa sucursal: el promedio de los
               ultimos 28 dias, YA DESESTACIONALIZADO (ver abajo).
   INDICE      Cuanto rinde un dia asi respecto de un dia cualquiera: por dia
               de semana, franja de temperatura y lluvia. Sale de todo el
               historico, en terminos relativos.
   FACTOR      Ajuste por salto termico (DIM_AJUSTE_SALTO_TEMP): no importa
               solo cuanto marca el termometro sino como llego.
   CENTRADO    Correccion por sucursal para que el modelo de, en promedio, cero
               desvio sobre la historia.

   POR QUE EN TERMINOS RELATIVOS Y NO EN PESOS
   -------------------------------------------
   Con la inflacion argentina, promediar pesos de dos anos y medio hace que
   cualquier dia de hoy le gane a cualquier promedio historico. Peor: la
   temperatura es estacional y la inflacion es monotona, asi que "dias de 30
   grados" son tambien "dias con los precios de enero de cada ano". Dividir
   cada dia por el nivel de SU momento antes de promediar cancela la inflacion,
   porque numerador y denominador tienen los mismos precios.

   POR QUE DOS PASADAS
   -------------------
   La primera version de este procedimiento tenia una sola, con el nivel
   calculado como el promedio crudo de los ultimos 28 dias. Media +25% a +31%
   en las cuatro sucursales para la semana del 14 al 20/09/2026: un sesgo, no
   una gesta.

   La causa: el promedio de los ultimos 28 dias ARRASTRA EL CLIMA de esos 28
   dias. En septiembre el nivel viene de un mes frio, asi que un dia de 23
   grados queda muy por encima de su propia referencia. Y al reves en enero,
   donde 23 grados es un dia FRESCO respecto de su mes. Un indice armado por
   temperatura ABSOLUTA mezcla esas dos poblaciones opuestas, y en un mes de
   transicion como septiembre subestima sistematicamente.

   La segunda pasada arregla eso:
     1a  se estima un indice crudo y con el se DESESTACIONALIZA cada dia
         historico: ADJ = VAL / (indice x factor).
     2a  el nivel se recalcula como el promedio movil de ADJ, que ya no tiene
         clima adentro, y con ese nivel limpio se recalcula el indice.

   Asi 23 grados en septiembre y 23 grados en enero se comparan contra la misma
   clase de referencia. Lo que quede de estacionalidad verdadera (vacaciones,
   dias mas largos, costumbre) se va al NIVEL, que es donde corresponde: es un
   cambio de nivel del negocio, no un efecto del termometro.

   EL DIA QUE SE MIDE NO ENTRA EN SU PROPIO PROMEDIO
   -------------------------------------------------
   El indice y el centrado se calculan EXCLUYENDO la ventana del objetivo. Si
   la incluyeran, una semana excelente subiria el promedio contra el que se
   compara y se mediria a si misma: el desvio tenderia a cero pase lo que pase.

   QUE SE MIDE SEGUN LA METRICA
   ----------------------------
     FACTURACION  IMPORTE
     MARGEN       CONTRIB_MARGINAL (descuenta mercaderia E insumos; es el
                  margen real, no el que se compara contra SmartFran)
     KILOS        KILOS
   =========================================================================== */

/* Columnas que agrego el diagnostico de ruido. Van con ALTER porque las tablas
   ya estaban creadas y en uso. */
IF COL_LENGTH('dbo.ESTRATEGIA_MEDICION', 'ERROR_TIPICO_PCT') IS NULL
BEGIN
    /* Cuanto se equivoca tipicamente el modelo EN UN DIA para esa sucursal,
       medido sobre la historia. Sin este numero al lado, un +68% parece una
       hazana cuando en realidad esta dentro del error del modelo. */
    ALTER TABLE dbo.ESTRATEGIA_MEDICION ADD ERROR_TIPICO_PCT numeric(8,2) NULL;
    PRINT 'ESTRATEGIA_MEDICION: columna ERROR_TIPICO_PCT agregada.';
END
GO

IF COL_LENGTH('dbo.ESTRATEGIA_MEDICION', 'EXPOS_LLUVIA') IS NULL
BEGIN
    /* Que porcentaje de la venta del dia cayo en horas con lluvia. Es lo que
       de verdad explica la caida, y "llovio si/no" no lo dice: la pantalla
       tiene que poder mostrar "el 74% de la venta estuvo bajo la lluvia". */
    ALTER TABLE dbo.ESTRATEGIA_MEDICION ADD EXPOS_LLUVIA numeric(6,2) NULL;
    PRINT 'ESTRATEGIA_MEDICION: columna EXPOS_LLUVIA agregada.';
END
GO

IF COL_LENGTH('dbo.ESTRATEGIA_OBJETIVO_SUCURSAL', 'RUIDO_VENTANA_PCT') IS NULL
BEGIN
    /* El error tipico ACUMULADO sobre una ventana del largo de este objetivo.
       Es el piso de lo que se puede medir: una meta por debajo de este numero
       no se distingue del ruido, y conviene saberlo ANTES de prometerla. */
    ALTER TABLE dbo.ESTRATEGIA_OBJETIVO_SUCURSAL ADD RUIDO_VENTANA_PCT numeric(8,2) NULL;
    PRINT 'ESTRATEGIA_OBJETIVO_SUCURSAL: columna RUIDO_VENTANA_PCT agregada.';
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_MedirObjetivo
    @ObjetivoId int,
    /* Dias para el nivel. 28 son cuatro semanas completas: cubre los siete
       dias de la semana cuatro veces y no arrastra el mes anterior. */
    @Ventana    int         = 28,
    /* Minimo de dias historicos para que un nivel del indice sea usable. A
       grano diario hay muchos menos casos que a grano ticket: con dos anos y
       medio, (dia de semana + franja + lluvia) puede tener apenas un punado. */
    @MinCasos   int         = 8,
    @DesdeHist  date        = '2024-01-01',
    @BaseOrigen varchar(30) = 'SRV_GRIDO_ZSUR',
    /* 1 = no graba nada y devuelve el detalle. Para calibrar sin ensuciar. */
    @SoloVer    bit         = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @metrica varchar(20), @desde date, @hasta date;

    SELECT @metrica = METRICA, @desde = FECHA_DESDE, @hasta = FECHA_HASTA
    FROM dbo.ESTRATEGIA_OBJETIVO
    WHERE OBJETIVO_ID = @ObjetivoId AND BASE_ORIGEN = @BaseOrigen;

    IF @metrica IS NULL
    BEGIN
        RAISERROR('No existe el objetivo indicado.', 16, 1);
        RETURN;
    END

    -- ---------------------------------------------------------------- 1) dias
    CREATE TABLE #D (
        SUCURSAL   int NOT NULL,
        FECHA      date NOT NULL,
        DIA_SEMANA tinyint NOT NULL,
        FRANJA     int NULL,
        LLOVIO     bit NULL,          -- solo para dejar constancia en la medicion
        /* La dimension de lluvia con la que agrupa el modelo. NO es el bit: el
           bit mete en la misma bolsa una garua de las 7 (indice 1,03) con un
           temporal de las 19 (0,71), y medido sobre 2024-2026 reduce el error
           cuatro veces menos que el tramo. */
        TRAMO      tinyint NULL,
        EXPOS      numeric(6,2) NULL,
        TMAX       numeric(6,2) NULL,
        TMAX_AYER  numeric(6,2) NULL,
        VAL        numeric(18,4) NULL,
        FACTOR     numeric(8,4) NOT NULL DEFAULT 1,
        NIVEL1     numeric(18,4) NULL,   -- promedio crudo (1a pasada)
        ESTAC      numeric(18,6) NULL,   -- indice x factor de la 1a pasada
        ADJ        numeric(18,4) NULL,   -- dia desestacionalizado
        NIVEL      numeric(18,4) NULL,   -- promedio de ADJ (2a pasada)
        EN_VENTANA bit NOT NULL,
        PRIMARY KEY (SUCURSAL, FECHA)
    );

    INSERT #D (SUCURSAL, FECHA, DIA_SEMANA, FRANJA, LLOVIO, TRAMO, EXPOS, TMAX, TMAX_AYER, VAL, EN_VENTANA)
    SELECT a.SUCURSAL, a.FECHA, a.DIA_SEMANA, a.FRANJA_TMAX, a.LLOVIO,
           a.TRAMO_LLUVIA, a.EXPOS_LLUVIA,
           a.TMAX, a.TMAX_AYER,
           CASE @metrica WHEN 'FACTURACION' THEN a.IMPORTE
                         WHEN 'MARGEN'      THEN a.CONTRIB_MARGINAL
                         ELSE a.KILOS END,
           CASE WHEN a.FECHA BETWEEN @desde AND @hasta THEN 1 ELSE 0 END
    FROM dbo.AGG_VENTA_DIA a
    WHERE a.BASE_ORIGEN = @BaseOrigen
      AND a.FECHA >= @DesdeHist
      AND EXISTS (SELECT 1 FROM dbo.ESTRATEGIA_OBJETIVO_SUCURSAL s
                  WHERE s.OBJETIVO_ID = @ObjetivoId AND s.SUCURSAL = a.SUCURSAL);

    -- --------------------------------------------- 2) factor de salto termico
    UPDATE d
    SET FACTOR = a.FACTOR
    FROM #D d
    JOIN dbo.DIM_AJUSTE_SALTO_TEMP a
         ON a.BASE_ORIGEN = @BaseOrigen
        AND a.CONFIABLE = 1
        AND (d.TMAX - d.TMAX_AYER) >= a.SALTO_DESDE
        AND (d.TMAX - d.TMAX_AYER) <  a.SALTO_HASTA
    WHERE d.TMAX IS NOT NULL AND d.TMAX_AYER IS NOT NULL;

    -- ============================== PRIMERA PASADA ==========================
    /* Nivel crudo: promedio de los @Ventana dias CALENDARIO anteriores. Por
       dias calendario y no por "las 28 filas anteriores": si el local estuvo
       cerrado, las filas se estiran hacia atras y el nivel dejaria de ser el
       de las ultimas cuatro semanas. */
    UPDATE d
    SET NIVEL1 = (SELECT AVG(b.VAL) FROM #D b
                  WHERE b.SUCURSAL = d.SUCURSAL
                    AND b.FECHA >= DATEADD(day, -@Ventana, d.FECHA)
                    AND b.FECHA <  d.FECHA)
    FROM #D d;

    /* ------------------------------------------------------------------
       EL INDICE ES UN PRODUCTO DE FACTORES, NO UNA CELDA UNICA
       ------------------------------------------------------------------
       La version anterior agrupaba por (dia de semana x franja x lluvia) en
       una sola celda. Con siete dias, catorce franjas y cinco tramos de lluvia
       eso da casi quinientas celdas para unos mil dias por sucursal: la mayoria
       queda con dos o tres casos y el modelo retrocede a un nivel mas grueso.
       Se vio al pasar la lluvia de bit a tramo: el nivel mas preciso cayo de
       1.505 a 1.250 dias y el error no mejoro, aunque por separado la lluvia
       ponderada explicaba cuatro veces mas que el bit.

       Ahora cada efecto se estima por separado y se multiplican:

           INDICE = F(dia de semana) x G(temperatura) x H(lluvia)

       Cada factor se calcula sobre el residuo del anterior, asi que no se
       pisan entre si. Con mil dias por sucursal, F tiene ~140 casos por nivel,
       G ~70 y H ~200: todos solidos. Se pierden las interacciones (que la
       lluvia pese distinto un sabado), pero con esta cantidad de datos el error
       de ignorarlas es menor que el de estimar celdas de tres casos.

       Una franja sin casos suficientes cae a una banda de seis grados, y si
       tampoco alcanza queda en 1 (sin ajuste) en vez de inventar un numero. */
    CREATE TABLE #F1 (SUCURSAL int, DIA_SEMANA tinyint, F numeric(18,6), CASOS int,
                      PRIMARY KEY (SUCURSAL, DIA_SEMANA));
    CREATE TABLE #G1 (SUCURSAL int, FRANJA int, G numeric(18,6), CASOS int,
                      PRIMARY KEY (SUCURSAL, FRANJA));
    CREATE TABLE #H1 (SUCURSAL int, TRAMO tinyint, H numeric(18,6), CASOS int,
                      PRIMARY KEY (SUCURSAL, TRAMO));

    ;WITH r AS (
        SELECT SUCURSAL, DIA_SEMANA, RATIO = VAL / NULLIF(NIVEL1, 0)
        FROM #D WHERE EN_VENTANA = 0 AND NIVEL1 > 0 AND VAL IS NOT NULL
    )
    INSERT #F1 SELECT SUCURSAL, DIA_SEMANA, AVG(RATIO), COUNT(*)
    FROM r GROUP BY SUCURSAL, DIA_SEMANA;

    ;WITH r AS (
        SELECT d.SUCURSAL, d.FRANJA, RESTO = (d.VAL / NULLIF(d.NIVEL1, 0)) / NULLIF(f.F, 0)
        FROM #D d JOIN #F1 f ON f.SUCURSAL = d.SUCURSAL AND f.DIA_SEMANA = d.DIA_SEMANA
        WHERE d.EN_VENTANA = 0 AND d.NIVEL1 > 0 AND d.VAL IS NOT NULL AND d.FRANJA IS NOT NULL
    )
    INSERT #G1 SELECT SUCURSAL, FRANJA, AVG(RESTO), COUNT(*)
    FROM r GROUP BY SUCURSAL, FRANJA;

    ;WITH r AS (
        SELECT d.SUCURSAL, d.TRAMO,
               RESTO = (d.VAL / NULLIF(d.NIVEL1, 0)) / NULLIF(f.F * ISNULL(g.G, 1), 0)
        FROM #D d
        JOIN #F1 f ON f.SUCURSAL = d.SUCURSAL AND f.DIA_SEMANA = d.DIA_SEMANA
        LEFT JOIN #G1 g ON g.SUCURSAL = d.SUCURSAL AND g.FRANJA = d.FRANJA AND g.CASOS >= @MinCasos
        WHERE d.EN_VENTANA = 0 AND d.NIVEL1 > 0 AND d.VAL IS NOT NULL AND d.TRAMO IS NOT NULL
    )
    INSERT #H1 SELECT SUCURSAL, TRAMO, AVG(RESTO), COUNT(*)
    FROM r GROUP BY SUCURSAL, TRAMO;

    /* El componente estacional de cada dia, y el dia limpio de clima. */
    UPDATE d
    SET ESTAC = ISNULL(f.F, 1) * ISNULL(g.G, 1) * ISNULL(h.H, 1) * d.FACTOR,
        ADJ   = d.VAL / NULLIF(ISNULL(f.F, 1) * ISNULL(g.G, 1) * ISNULL(h.H, 1) * d.FACTOR, 0)
    FROM #D d
    LEFT JOIN #F1 f ON f.SUCURSAL = d.SUCURSAL AND f.DIA_SEMANA = d.DIA_SEMANA AND f.CASOS >= @MinCasos
    LEFT JOIN #G1 g ON g.SUCURSAL = d.SUCURSAL AND g.FRANJA     = d.FRANJA     AND g.CASOS >= @MinCasos
    LEFT JOIN #H1 h ON h.SUCURSAL = d.SUCURSAL AND h.TRAMO      = d.TRAMO      AND h.CASOS >= @MinCasos;

    -- ============================== SEGUNDA PASADA ==========================
    /* El nivel sale de los dias SIN clima adentro, y CON LA TENDENCIA
       CORREGIDA. Este es el que se usa de verdad.

       POR QUE NO ALCANZA EL PROMEDIO MOVIL
       ------------------------------------
       Un promedio de los 28 dias anteriores esta centrado 14 dias ATRAS. Si el
       negocio viene subiendo, ese promedio queda por debajo del nivel de hoy y
       el modelo pide de menos; si viene bajando, al reves. En un negocio de
       helados la diferencia no es un detalle: la version con promedio simple
       media +23% en septiembre y -16% en abril. No medía gestion: medía en que
       parte de la curva estacional caia el mes.

       Y el sesgo NO se cancela solo contra el indice, porque el indice se arma
       con toda la historia y promedia la tendencia de los doce meses: se queda
       con la tendencia media y deja afuera la de cada mes.

       LA CORRECCION
       -------------
       En vez del promedio se ajusta una recta sobre la ventana y se la evalua
       EN EL DIA. Con x = dias respecto de d (negativos, porque son pasados),
       el nivel es la ordenada en x = 0:

           NIVEL = promedio(y) - pendiente x promedio(x)

       Solo usa dias anteriores, asi que sirve igual en produccion, donde del
       dia que se mide todavia no se sabe nada.

       EL TOPE DE LA CORRECCION
       ------------------------
       Se limita a +-30% del promedio. Con pocos dias o un feriado en el medio,
       una recta puede salir disparada y proyectar un nivel absurdo. Preferible
       un nivel algo atrasado que uno inventado. */
    UPDATE d
    SET NIVEL = CASE
            WHEN t.n < 8 OR t.prom IS NULL THEN t.prom
            /* promedio - pendiente * promedio(x), con la correccion topeada */
            ELSE t.prom + CASE
                WHEN -t.pend * t.promx >  0.30 * t.prom THEN  0.30 * t.prom
                WHEN -t.pend * t.promx < -0.30 * t.prom THEN -0.30 * t.prom
                ELSE -t.pend * t.promx END
        END
    FROM #D d
    CROSS APPLY (
        SELECT n = COUNT(*), prom = AVG(b.ADJ), promx = AVG(CAST(b.X AS float)),
               pend = CASE
                   WHEN COUNT(*) * SUM(CAST(b.X AS float) * CAST(b.X AS float))
                        - SUM(CAST(b.X AS float)) * SUM(CAST(b.X AS float)) = 0 THEN 0
                   ELSE (COUNT(*) * SUM(CAST(b.X AS float) * CAST(b.ADJ AS float))
                         - SUM(CAST(b.X AS float)) * SUM(CAST(b.ADJ AS float)))
                        / (COUNT(*) * SUM(CAST(b.X AS float) * CAST(b.X AS float))
                           - SUM(CAST(b.X AS float)) * SUM(CAST(b.X AS float)))
               END
        FROM (
            SELECT ADJ, X = DATEDIFF(day, d.FECHA, FECHA)
            FROM #D
            WHERE SUCURSAL = d.SUCURSAL
              AND FECHA >= DATEADD(day, -@Ventana, d.FECHA)
              AND FECHA <  d.FECHA
              AND ADJ IS NOT NULL
        ) b
    ) t;

    /* Los mismos tres factores, ahora sobre el nivel limpio. Estos son los que
       se usan de verdad. */
    CREATE TABLE #F (SUCURSAL int, DIA_SEMANA tinyint, F numeric(18,6), CASOS int,
                     PRIMARY KEY (SUCURSAL, DIA_SEMANA));
    CREATE TABLE #G (SUCURSAL int, FRANJA int, G numeric(18,6), CASOS int,
                     PRIMARY KEY (SUCURSAL, FRANJA));
    /* Banda ancha de seis grados, para cuando una franja de dos no junta casos:
       en los extremos (8 grados, 36 grados) hay pocos dias y caer a "sin ajuste
       por temperatura" justo ahi seria caer donde mas importa. */
    CREATE TABLE #GB (SUCURSAL int, BANDA int, G numeric(18,6), CASOS int,
                      PRIMARY KEY (SUCURSAL, BANDA));
    CREATE TABLE #H (SUCURSAL int, TRAMO tinyint, H numeric(18,6), CASOS int,
                     PRIMARY KEY (SUCURSAL, TRAMO));

    ;WITH r AS (
        SELECT SUCURSAL, DIA_SEMANA, RATIO = VAL / NULLIF(NIVEL, 0)
        FROM #D WHERE EN_VENTANA = 0 AND NIVEL > 0 AND VAL IS NOT NULL
    )
    INSERT #F SELECT SUCURSAL, DIA_SEMANA, AVG(RATIO), COUNT(*)
    FROM r GROUP BY SUCURSAL, DIA_SEMANA;

    ;WITH r AS (
        SELECT d.SUCURSAL, d.FRANJA, RESTO = (d.VAL / NULLIF(d.NIVEL, 0)) / NULLIF(f.F, 0)
        FROM #D d JOIN #F f ON f.SUCURSAL = d.SUCURSAL AND f.DIA_SEMANA = d.DIA_SEMANA
        WHERE d.EN_VENTANA = 0 AND d.NIVEL > 0 AND d.VAL IS NOT NULL AND d.FRANJA IS NOT NULL
    )
    INSERT #G SELECT SUCURSAL, FRANJA, AVG(RESTO), COUNT(*)
    FROM r GROUP BY SUCURSAL, FRANJA;

    ;WITH r AS (
        SELECT d.SUCURSAL, BANDA = (d.FRANJA / 6) * 6,
               RESTO = (d.VAL / NULLIF(d.NIVEL, 0)) / NULLIF(f.F, 0)
        FROM #D d JOIN #F f ON f.SUCURSAL = d.SUCURSAL AND f.DIA_SEMANA = d.DIA_SEMANA
        WHERE d.EN_VENTANA = 0 AND d.NIVEL > 0 AND d.VAL IS NOT NULL AND d.FRANJA IS NOT NULL
    )
    INSERT #GB SELECT SUCURSAL, BANDA, AVG(RESTO), COUNT(*)
    FROM r GROUP BY SUCURSAL, BANDA;

    ;WITH r AS (
        SELECT d.SUCURSAL, d.TRAMO,
               RESTO = (d.VAL / NULLIF(d.NIVEL, 0))
                       / NULLIF(f.F * COALESCE(g.G, gb.G, 1), 0)
        FROM #D d
        JOIN #F f ON f.SUCURSAL = d.SUCURSAL AND f.DIA_SEMANA = d.DIA_SEMANA
        LEFT JOIN #G  g  ON g.SUCURSAL  = d.SUCURSAL AND g.FRANJA  = d.FRANJA          AND g.CASOS  >= @MinCasos
        LEFT JOIN #GB gb ON gb.SUCURSAL = d.SUCURSAL AND gb.BANDA = (d.FRANJA / 6) * 6 AND gb.CASOS >= @MinCasos
        WHERE d.EN_VENTANA = 0 AND d.NIVEL > 0 AND d.VAL IS NOT NULL AND d.TRAMO IS NOT NULL
    )
    INSERT #H SELECT SUCURSAL, TRAMO, AVG(RESTO), COUNT(*)
    FROM r GROUP BY SUCURSAL, TRAMO;

    -- ------------------------------ 3) esperado crudo de cada dia historico
    CREATE TABLE #E (
        SUCURSAL   int NOT NULL, FECHA date NOT NULL, EN_VENTANA bit NOT NULL,
        VAL        numeric(18,4) NULL, CRUDO numeric(18,4) NULL,
        ORDEN      tinyint NULL, CASOS int NULL,
        PRIMARY KEY (SUCURSAL, FECHA)
    );

    /* ORDEN ya no es "que nivel de celda se uso" sino CUANTOS de los tres
       factores se pudieron aplicar. Es lo que despues se le muestra a Damian
       como "con que se estimo": un dia estimado con los tres no es lo mismo que
       uno al que solo se le pudo aplicar el dia de semana. */
    INSERT #E (SUCURSAL, FECHA, EN_VENTANA, VAL, CRUDO, ORDEN, CASOS)
    SELECT d.SUCURSAL, d.FECHA, d.EN_VENTANA, d.VAL,
           d.NIVEL * ISNULL(f.F, 1) * COALESCE(g.G, gb.G, 1) * ISNULL(h.H, 1) * d.FACTOR,
           ORDEN = CASE
               WHEN f.F IS NOT NULL AND COALESCE(g.G, gb.G) IS NOT NULL AND h.H IS NOT NULL THEN 1
               WHEN f.F IS NOT NULL AND COALESCE(g.G, gb.G) IS NOT NULL THEN 2
               WHEN f.F IS NOT NULL THEN 3
               ELSE 4 END,
           /* Los casos del factor mas fino que se aplico: es el que limita. */
           CASOS = CASE
               WHEN h.H IS NOT NULL THEN h.CASOS
               WHEN g.G IS NOT NULL THEN g.CASOS
               WHEN gb.G IS NOT NULL THEN gb.CASOS
               ELSE f.CASOS END
    FROM #D d
    LEFT JOIN #F  f  ON f.SUCURSAL  = d.SUCURSAL AND f.DIA_SEMANA = d.DIA_SEMANA     AND f.CASOS  >= @MinCasos
    LEFT JOIN #G  g  ON g.SUCURSAL  = d.SUCURSAL AND g.FRANJA     = d.FRANJA         AND g.CASOS  >= @MinCasos
    LEFT JOIN #GB gb ON gb.SUCURSAL = d.SUCURSAL AND gb.BANDA = (d.FRANJA / 6) * 6   AND gb.CASOS >= @MinCasos
    LEFT JOIN #H  h  ON h.SUCURSAL  = d.SUCURSAL AND h.TRAMO      = d.TRAMO          AND h.CASOS  >= @MinCasos
    WHERE d.NIVEL > 0;

    -- ---------------------------------------------------- 4) centrado
    /* Un escalar por sucursal: cuanto se desvia el modelo, en promedio, sobre
       la historia. Se usa la MEDIANA y no el promedio porque un solo dia
       excepcional (un feriado, un corte de luz) corre el promedio y no la
       mediana, y lo que se quiere corregir es el sesgo tipico. */
    CREATE TABLE #K (
        SUCURSAL int PRIMARY KEY,
        CENTRADO numeric(18,6) NOT NULL,
        DIAS     int NOT NULL,
        /* Error tipico de un dia: mediana del |desvio| sobre la historia. */
        ERROR_DIA numeric(8,2) NULL,
        /* Error tipico acumulado sobre una ventana del largo de este objetivo. */
        RUIDO_VENTANA numeric(8,2) NULL
    );

    INSERT #K (SUCURSAL, CENTRADO, DIAS)
    SELECT SUCURSAL, ISNULL(NULLIF(MAX(mediana), 0), 1), MAX(dias)
    FROM (
        SELECT SUCURSAL,
               mediana = PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY VAL / NULLIF(CRUDO, 0))
                         OVER (PARTITION BY SUCURSAL),
               dias = COUNT(*) OVER (PARTITION BY SUCURSAL)
        FROM #E WHERE EN_VENTANA = 0 AND CRUDO > 0 AND VAL IS NOT NULL
    ) q
    GROUP BY SUCURSAL;

    /* ------------------------------------------------ 4b) cuanto ruido hay
       El desvio de un dia cualquiera no es cero ni con la mejor gestion: el
       modelo tiene su propio error. Medirlo es lo que permite distinguir
       "cumplio" de "tuvo suerte".

       ERROR_DIA      mediana del |desvio| dia a dia sobre la historia.
       RUIDO_VENTANA  lo mismo pero sobre bloques del largo de esta ventana. Es
                      bastante menor, porque los dias buenos y malos se
                      compensan: es el piso real de lo que se puede exigir.

       Si la meta de una sucursal queda por debajo de su RUIDO_VENTANA, esa meta
       no se puede verificar. Mejor decirlo que fingir que se midio. */
    UPDATE k
    SET ERROR_DIA = e.err
    FROM #K k
    JOIN (
        SELECT SUCURSAL, err = CAST(MAX(m) AS numeric(8,2))
        FROM (
            SELECT SUCURSAL,
                   m = PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY ABS(VAL / NULLIF(CRUDO, 0) - 1) * 100)
                       OVER (PARTITION BY SUCURSAL)
            FROM #E WHERE EN_VENTANA = 0 AND CRUDO > 0 AND VAL IS NOT NULL
        ) q GROUP BY SUCURSAL
    ) e ON e.SUCURSAL = k.SUCURSAL;

    DECLARE @largo int = DATEDIFF(day, @desde, @hasta) + 1;

    UPDATE k
    SET RUIDO_VENTANA = b.ruido
    FROM #K k
    JOIN (
        SELECT SUCURSAL, ruido = CAST(MAX(m) AS numeric(8,2))
        FROM (
            SELECT SUCURSAL,
                   m = PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY ABS(desvio))
                       OVER (PARTITION BY SUCURSAL)
            FROM (
                /* Cada dia historico abre un bloque de @largo dias; se compara
                   el total real contra el total esperado de ese bloque. */
                SELECT e.SUCURSAL,
                       desvio = (SELECT SUM(b2.VAL) / NULLIF(SUM(b2.CRUDO), 0) - 1
                                 FROM #E b2
                                 WHERE b2.SUCURSAL = e.SUCURSAL
                                   AND b2.EN_VENTANA = 0
                                   AND b2.CRUDO > 0
                                   AND b2.FECHA >= e.FECHA
                                   AND b2.FECHA <  DATEADD(day, @largo, e.FECHA)) * 100
                FROM #E e
                WHERE e.EN_VENTANA = 0 AND e.CRUDO > 0 AND e.VAL IS NOT NULL
                  -- Solo bloques completos: uno de dos dias no mide lo mismo.
                  AND DATEADD(day, @largo - 1, e.FECHA) <= (SELECT MAX(FECHA) FROM #E x WHERE x.SUCURSAL = e.SUCURSAL)
            ) bl
            WHERE desvio IS NOT NULL
        ) q GROUP BY SUCURSAL
    ) b ON b.SUCURSAL = k.SUCURSAL;

    /* Se guarda en la meta de cada sucursal: la pantalla lo muestra al lado de
       la meta, que es donde sirve. En modo @SoloVer no se graba NADA, y esto
       tambien es grabar. */
    IF @SoloVer = 0
        UPDATE s
        SET RUIDO_VENTANA_PCT = k.RUIDO_VENTANA
        FROM dbo.ESTRATEGIA_OBJETIVO_SUCURSAL s
        JOIN #K k ON k.SUCURSAL = s.SUCURSAL
        WHERE s.OBJETIVO_ID = @ObjetivoId;

    -- ------------------------------------------------ 5) resultado
    IF @SoloVer = 1
    BEGIN
        /* Calibracion: todos los dias, dentro y fuera de la ventana. Sirve
           para ver si el modelo esta centrado en cada mes del ano, que es la
           unica forma de detectar un sesgo estacional. */
        SELECT e.SUCURSAL, e.FECHA, e.EN_VENTANA,
               Anio = YEAR(e.FECHA), Mes = MONTH(e.FECHA),
               d.TMAX, d.TMAX_AYER, d.LLOVIO, d.EXPOS, d.FACTOR,
               Nivel = CAST(d.NIVEL AS numeric(18,2)),
               Esperado = CAST(e.CRUDO * k.CENTRADO AS numeric(18,2)),
               Real_ = CAST(e.VAL AS numeric(18,2)),
               DesvioPct = CAST((e.VAL / NULLIF(e.CRUDO * k.CENTRADO, 0) - 1) * 100 AS numeric(8,2)),
               Orden = e.ORDEN, Casos = e.CASOS, Centrado = k.CENTRADO
        FROM #E e
        JOIN #D d ON d.SUCURSAL = e.SUCURSAL AND d.FECHA = e.FECHA
        JOIN #K k ON k.SUCURSAL = e.SUCURSAL
        WHERE e.CRUDO > 0 AND e.VAL IS NOT NULL
        ORDER BY e.SUCURSAL, e.FECHA;

        DROP TABLE #D; DROP TABLE #F1; DROP TABLE #G1; DROP TABLE #H1;
        DROP TABLE #F; DROP TABLE #G; DROP TABLE #GB; DROP TABLE #H;
        DROP TABLE #E; DROP TABLE #K;
        RETURN;
    END

    MERGE dbo.ESTRATEGIA_MEDICION AS m
    USING (
        SELECT e.SUCURSAL, e.FECHA,
               d.TMAX, d.TMAX_AYER, d.LLOVIO, d.EXPOS, d.FACTOR,
               ESPERADO = CAST(e.CRUDO * k.CENTRADO AS numeric(18,2)),
               REAL_    = CAST(e.VAL AS numeric(18,2)),
               DESVIO   = CAST((e.VAL / NULLIF(e.CRUDO * k.CENTRADO, 0) - 1) * 100 AS numeric(8,2)),
               s.META_PCT,
               ERROR_TIPICO = k.ERROR_DIA,
               NIVEL_MODELO =
                   CASE e.ORDEN
                       WHEN 1 THEN 'dia de semana + temperatura + exposicion a la lluvia'
                       WHEN 2 THEN 'dia de semana + temperatura'
                       WHEN 3 THEN 'dia de semana'
                       ELSE 'solo nivel de la sucursal'
                   END
                   + ' (' + CAST(e.CASOS AS varchar(10)) + ' dias)'
        FROM #E e
        JOIN #D d ON d.SUCURSAL = e.SUCURSAL AND d.FECHA = e.FECHA
        JOIN #K k ON k.SUCURSAL = e.SUCURSAL
        JOIN dbo.ESTRATEGIA_OBJETIVO_SUCURSAL s
             ON s.OBJETIVO_ID = @ObjetivoId AND s.SUCURSAL = e.SUCURSAL
        WHERE e.EN_VENTANA = 1 AND e.CRUDO > 0 AND e.VAL IS NOT NULL
    ) AS o
        ON m.OBJETIVO_ID = @ObjetivoId AND m.SUCURSAL = o.SUCURSAL AND m.FECHA = o.FECHA
    WHEN MATCHED THEN UPDATE SET
        m.TMAX = o.TMAX, m.TMAX_AYER = o.TMAX_AYER, m.LLOVIO = o.LLOVIO,
        m.EXPOS_LLUVIA = o.EXPOS,
        m.FACTOR_SALTO = o.FACTOR, m.ESPERADO = o.ESPERADO, m.REAL_ = o.REAL_,
        m.DESVIO_PCT = o.DESVIO, m.META_PCT = o.META_PCT,
        m.CUMPLE = CASE WHEN o.DESVIO >= o.META_PCT THEN 1 ELSE 0 END,
        m.NIVEL_MODELO = o.NIVEL_MODELO, m.ERROR_TIPICO_PCT = o.ERROR_TIPICO,
        m.CALCULADO_EL = SYSDATETIME()
    WHEN NOT MATCHED BY TARGET THEN INSERT
        (OBJETIVO_ID, SUCURSAL, FECHA, TMAX, TMAX_AYER, LLOVIO, EXPOS_LLUVIA, FACTOR_SALTO,
         ESPERADO, REAL_, DESVIO_PCT, META_PCT, CUMPLE, NIVEL_MODELO, ERROR_TIPICO_PCT)
        VALUES
        (@ObjetivoId, o.SUCURSAL, o.FECHA, o.TMAX, o.TMAX_AYER, o.LLOVIO, o.EXPOS, o.FACTOR,
         o.ESPERADO, o.REAL_, o.DESVIO, o.META_PCT,
         CASE WHEN o.DESVIO >= o.META_PCT THEN 1 ELSE 0 END, o.NIVEL_MODELO,
         o.ERROR_TIPICO);

    DECLARE @medidos int = @@ROWCOUNT;

    SELECT Medidos = @medidos, Metrica = @metrica, Desde = @desde, Hasta = @hasta,
           Centrado = (SELECT CAST(AVG(CENTRADO) AS numeric(8,4)) FROM #K),
           DiasHistoricos = (SELECT MIN(DIAS) FROM #K),
           ErrorDiaPeor = (SELECT MAX(ERROR_DIA) FROM #K),
           RuidoVentanaPeor = (SELECT MAX(RUIDO_VENTANA) FROM #K);

    DROP TABLE #D; DROP TABLE #F1; DROP TABLE #G1; DROP TABLE #H1;
    DROP TABLE #F; DROP TABLE #G; DROP TABLE #GB; DROP TABLE #H;
    DROP TABLE #E; DROP TABLE #K;
END
GO


/* ---------------------------------------------------------------------------
   Lo que la pantalla lee: la medicion de un objetivo, en dos cortes.
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_ObtenerMedicion
    @ObjetivoId int
AS
BEGIN
    SET NOCOUNT ON;

    -- 1) Un resumen por sucursal: es lo primero que se mira.
    SELECT Sucursal = m.SUCURSAL,
           MetaPct  = MAX(m.META_PCT),
           Dias     = COUNT(*),
           DiasCumplidos = SUM(CAST(m.CUMPLE AS int)),
           Esperado = SUM(m.ESPERADO),
           Real     = SUM(m.REAL_),
           /* El desvio acumulado se calcula sobre los TOTALES y no promediando
              los desvios diarios: un lunes flojo de poca venta pesaria igual
              que un sabado, y no es lo mismo. */
           DesvioPct = CAST((SUM(m.REAL_) / NULLIF(SUM(m.ESPERADO), 0) - 1) * 100 AS numeric(8,2)),
           Cumple = CASE WHEN (SUM(m.REAL_) / NULLIF(SUM(m.ESPERADO), 0) - 1) * 100
                              >= MAX(m.META_PCT) THEN CAST(1 AS bit) ELSE CAST(0 AS bit) END,
           ErrorTipicoPct = MAX(m.ERROR_TIPICO_PCT),
           RuidoVentanaPct = MAX(s.RUIDO_VENTANA_PCT),
           /* Concluyente cuando el desvio se despega del ruido. Si no lo hace,
              el resultado no dice nada: ni que cumplio ni que fallo. Es la
              diferencia entre medir y adivinar con decimales. */
           Concluyente = CASE
               WHEN MAX(s.RUIDO_VENTANA_PCT) IS NULL THEN CAST(0 AS bit)
               WHEN ABS((SUM(m.REAL_) / NULLIF(SUM(m.ESPERADO), 0) - 1) * 100)
                    >= MAX(s.RUIDO_VENTANA_PCT) THEN CAST(1 AS bit)
               ELSE CAST(0 AS bit) END
    FROM dbo.ESTRATEGIA_MEDICION m
    LEFT JOIN dbo.ESTRATEGIA_OBJETIVO_SUCURSAL s
           ON s.OBJETIVO_ID = m.OBJETIVO_ID AND s.SUCURSAL = m.SUCURSAL
    WHERE m.OBJETIVO_ID = @ObjetivoId
    GROUP BY m.SUCURSAL
    ORDER BY m.SUCURSAL;

    -- 2) El detalle dia por dia.
    SELECT Sucursal = SUCURSAL, Fecha = FECHA,
           TMax = TMAX, TMaxAyer = TMAX_AYER, Llovio = LLOVIO,
           ExposLluvia = EXPOS_LLUVIA,
           FactorSalto = FACTOR_SALTO,
           Esperado = ESPERADO, Real = REAL_, DesvioPct = DESVIO_PCT,
           MetaPct = META_PCT, Cumple = CUMPLE,
           ErrorTipicoPct = ERROR_TIPICO_PCT,
           NivelModelo = NIVEL_MODELO, CalculadoEl = CALCULADO_EL
    FROM dbo.ESTRATEGIA_MEDICION
    WHERE OBJETIVO_ID = @ObjetivoId
    ORDER BY FECHA, SUCURSAL;
END
GO


/* ---------------------------------------------------------------------------
   Mide todos los objetivos que estan corriendo. Es lo que llama la tarea
   diaria: la informacion llega sola, como dice el circuito.

   Tambien mide los cerrados cuya ventana termino hace poco: el ultimo dia de
   una ventana recien se puede medir al dia siguiente, cuando llego su venta.
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_MedirObjetivosVigentes
    @BaseOrigen varchar(30) = 'SRV_GRIDO_ZSUR'
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @id int, @n int = 0;
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT OBJETIVO_ID FROM dbo.ESTRATEGIA_OBJETIVO
        WHERE BASE_ORIGEN = @BaseOrigen
          AND ESTADO IN ('VIGENTE', 'CERRADO')
          AND FECHA_HASTA >= DATEADD(day, -7, CAST(GETDATE() AS date))
        ORDER BY OBJETIVO_ID;

    OPEN c;
    FETCH NEXT FROM c INTO @id;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        /* Un objetivo que falla no puede frenar a los demas: cada uno tiene
           sus propias sucursales y su propia historia. */
        BEGIN TRY
            EXEC dbo.usp_MedirObjetivo @ObjetivoId = @id, @BaseOrigen = @BaseOrigen;
            SET @n = @n + 1;
        END TRY
        BEGIN CATCH
            PRINT 'Objetivo ' + CAST(@id AS varchar(10)) + ': ' + ERROR_MESSAGE();
        END CATCH
        FETCH NEXT FROM c INTO @id;
    END
    CLOSE c; DEALLOCATE c;

    PRINT CAST(@n AS varchar(10)) + ' objetivo(s) medidos.';
END
GO

PRINT '';
PRINT 'Medicion de objetivos lista.';
GO
