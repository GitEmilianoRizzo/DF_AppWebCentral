/* ===========================================================================
   usp_GenerarSugerencias
   ---------------------------------------------------------------------------
   Convierte el pronostico y las calibraciones en frases accionables.

   REGLAS EXPLICITAS, NO UN MODELO
   -------------------------------
   Cada sugerencia sale de una regla que se puede leer, con el numero que la
   respalda guardado al lado. Un modelo entrenado daria recomendaciones que
   nadie podria discutir, y una recomendacion que no se puede discutir no se
   ejecuta.

   LO QUE NO HACE
   --------------
   No sugiere cuando no hay evidencia. Si la calibracion de una condicion no
   es confiable o no hay pronostico, esa regla simplemente no dispara. Una
   semana sin sugerencias es un resultado valido: significa que no se ve nada
   fuera de lo normal.

   LA METRICA DEL OBJETIVO CAMBIA QUE SE SUGIERE
   ---------------------------------------------
   FACTURACION  busca volumen: promo en el valle, upsell.
   MARGEN       protege el margen: no descontar en el pico, upsell, cafeteria.
   KILOS        empuja formatos grandes aunque el margen sufra.
   No son lo mismo y a veces se contradicen: un 2x1 sube kilos y baja margen.
   =========================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_GenerarSugerencias
    @ObjetivoId int,
    @BaseOrigen varchar(30) = 'SRV_GRIDO_ZSUR'
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @metrica varchar(20), @desde date, @hasta date, @nombre varchar(120);
    SELECT @metrica = METRICA, @desde = FECHA_DESDE, @hasta = FECHA_HASTA, @nombre = NOMBRE
    FROM dbo.ESTRATEGIA_OBJETIVO WHERE OBJETIVO_ID = @ObjetivoId;

    IF @metrica IS NULL
    BEGIN
        RAISERROR('No existe el objetivo indicado.', 16, 1);
        RETURN;
    END

    /* Se borran solo las que nadie decidio todavia: si Damian ya acepto o
       descarto algo, esa decision queda. Regenerar no puede pisar lo que una
       persona resolvio. */
    DELETE FROM dbo.ESTRATEGIA_SUGERENCIA
    WHERE OBJETIVO_ID = @ObjetivoId AND ESTADO = 'SUGERIDA';

    ---------------------------------------------------------------- pronostico
    /* Se calcula sobre TODO el pronostico disponible y recien despues se
       recorta a la ventana: el LAG necesita el dia anterior, que puede caer
       fuera del objetivo. */
    CREATE TABLE #P (
        SUCURSAL int, DIA date, DOW int, TMAX numeric(6,2), TMAX_AYER numeric(6,2),
        SALTO numeric(6,2), LLUEVE bit, HORAS_LLUVIA int,
        /* La lluvia NO entra como bandera. Lo que importa es que porcentaje de
           la venta del dia cae en horas con lluvia: medido sobre 2024-2026, un
           dia con menos del 10% expuesto no se distingue de uno seco, y uno con
           mas de la mitad vende un 30% menos. Llover once horas de madrugada y
           llover doce encima de la tarde son el mismo bit y dias opuestos. */
        EXPOSICION numeric(6,2), TRAMO_LLUVIA tinyint, IMPACTO_LLUVIA numeric(8,2),
        FACTOR numeric(8,4),
        ETIQUETA_SALTO varchar(40), META_PCT numeric(8,2), RESPONSABLE varchar(120)
    );

    ;WITH pron AS (
        SELECT p.SUCURSAL, DIA = p.CLIMA_KEY_DIA,
               TMAX = MAX(p.TEMPERATURA),
               LLUEVE = MAX(CASE WHEN p.LLUVIA > 0 THEN 1 ELSE 0 END),
               HORAS_LLUVIA = SUM(CASE WHEN p.LLUVIA > 0 THEN 1 ELSE 0 END),
               -- Misma definicion que AGG_VENTA_DIA: se calibra y se predice igual.
               EXPOSICION = CASE WHEN COUNT(w.PESO) = 0 THEN NULL
                                 ELSE CAST(SUM(CASE WHEN p.LLUVIA > 0 THEN ISNULL(w.PESO, 0) ELSE 0 END) * 100
                                           AS numeric(6,2)) END
        FROM dbo.CLIMA_PRONOSTICO_HORA p
        LEFT JOIN dbo.DIM_PESO_HORA w
               ON w.BASE_ORIGEN = p.BASE_ORIGEN AND w.SUCURSAL = p.SUCURSAL AND w.HORA = p.HORA
        WHERE p.BASE_ORIGEN = @BaseOrigen
        GROUP BY p.SUCURSAL, p.CLIMA_KEY_DIA
    ),
    conAyer AS (
        SELECT *, TMAX_AYER = LAG(TMAX) OVER (PARTITION BY SUCURSAL ORDER BY DIA),
               TRAMO = CASE WHEN EXPOSICION IS NULL THEN NULL
                            WHEN EXPOSICION = 0  THEN 0
                            WHEN EXPOSICION < 10 THEN 1
                            WHEN EXPOSICION < 25 THEN 2
                            WHEN EXPOSICION < 50 THEN 3
                            ELSE 4 END
        FROM pron
    )
    INSERT #P
    SELECT c.SUCURSAL, c.DIA,
           (DATEDIFF(day, '1900-01-01', c.DIA) % 7) + 1,
           c.TMAX, c.TMAX_AYER, c.TMAX - c.TMAX_AYER,
           c.LLUEVE, c.HORAS_LLUVIA,
           c.EXPOSICION, c.TRAMO, il.IMPACTO_VS_SECO_PCT,
           ISNULL(a.FACTOR, 1), ISNULL(a.ETIQUETA, 'sin dato'),
           os.META_PCT, os.RESPONSABLE
    FROM conAyer c
    JOIN dbo.ESTRATEGIA_OBJETIVO_SUCURSAL os
         ON os.OBJETIVO_ID = @ObjetivoId AND os.SUCURSAL = c.SUCURSAL
    LEFT JOIN dbo.DIM_AJUSTE_SALTO_TEMP a
         ON a.BASE_ORIGEN = @BaseOrigen AND a.CONFIABLE = 1
        AND (c.TMAX - c.TMAX_AYER) >= a.SALTO_DESDE
        AND (c.TMAX - c.TMAX_AYER) <  a.SALTO_HASTA
    -- La calibracion de la propia sucursal; la general (0) como respaldo.
    OUTER APPLY (
        SELECT TOP 1 l.IMPACTO_VS_SECO_PCT
        FROM dbo.DIM_IMPACTO_LLUVIA l
        WHERE l.BASE_ORIGEN = @BaseOrigen AND l.CONFIABLE = 1
          AND l.SUCURSAL IN (c.SUCURSAL, 0) AND l.TRAMO = c.TRAMO
        ORDER BY CASE WHEN l.SUCURSAL = c.SUCURSAL THEN 0 ELSE 1 END
    ) il
    /* Nunca dias ya pasados, aunque esten dentro de la ventana: sugerirle a un
       local que se prepare para ayer es ruido, y el pronostico de un dia que ya
       ocurrio tampoco es un pronostico. */
    WHERE c.DIA BETWEEN @desde AND @hasta
      AND c.DIA >= CAST(GETDATE() AS date);

    ---------------------------------------------------------------- regla 1
    /* SALTO TERMICO -> alerta operativa.
       Es el efecto mas grande que medimos y el unico que se puede anticipar
       con dias. No es una sugerencia de promocion: es stock y dotacion. La
       plata se pierde por quedarse sin producto, no por no tener la promo
       correcta. */
    INSERT dbo.ESTRATEGIA_SUGERENCIA
        (OBJETIVO_ID, SUCURSAL, FECHA, TIPO, TITULO, DETALLE, EVIDENCIA)
    /* El titulo describe la CONDICION y no el valor exacto: las cuatro
       sucursales estan en la misma zona y sus pronosticos difieren por
       decimas. Con el valor en el titulo salian cuatro alertas casi iguales
       que se leen como ruido; con la condicion, se consolidan en una sola. */
    SELECT @ObjetivoId, SUCURSAL, DIA, 'OPERATIVO',
           CONCAT('Sube la temperatura: esperar +',
                  CAST(CAST((FACTOR - 1) * 100 AS decimal(4,0)) AS varchar(8)), '%'),
           CONCAT('La maxima sube alrededor de ',
                  CAST(CAST(ROUND(SALTO, 0) AS int) AS varchar(8)),
                  ' grados. Reforzar stock y sumar gente en el turno tarde. ',
                  'La venta va a venir sola: no es dia de descuento.'),
           CONCAT('Calibrado con ',
                  (SELECT CAST(DIAS AS varchar(10)) FROM dbo.DIM_AJUSTE_SALTO_TEMP
                   WHERE BASE_ORIGEN = @BaseOrigen AND ETIQUETA = ETIQUETA_SALTO),
                  ' dias historicos: los dias que ', ETIQUETA_SALTO,
                  ' vendieron un ', CAST(CAST((FACTOR - 1) * 100 AS decimal(4,1)) AS varchar(8)),
                  '% sobre lo esperable para su temperatura.')
    FROM #P WHERE SALTO >= 2 AND FACTOR > 1.02;

    ---------------------------------------------------------------- regla 2
    /* FRIO -> empujar sobreventa.
       Medido: con 8 a 12 grados la aceptacion es 16,9% y con 24 a 28 baja a
       9,5%, mientras la tasa de OFERTA se mantiene plana. No es que se
       ofrezca menos con calor: la gente dice que no. Justo cuando menos
       gente entra, la que entra compra mas si le ofrecen. */
    INSERT dbo.ESTRATEGIA_SUGERENCIA
        (OBJETIVO_ID, SUCURSAL, FECHA, TIPO, TITULO, DETALLE, EVIDENCIA)
    SELECT @ObjetivoId, SUCURSAL, DIA, 'SOBREVENTA',
           'Dia fresco: es cuando mejor funciona la sobreventa',
           'Va a entrar menos gente, pero la que entra acepta casi el doble. ' +
           'Que el equipo ofrezca en todos los tickets.',
           'Aceptacion historica: 16,9% con 8 a 12 grados contra 9,5% con 24 a 28. ' +
           'La tasa de oferta se mantiene plana (67% a 78%), asi que la diferencia ' +
           'esta en la respuesta del cliente, no en el esfuerzo del mostrador.'
    FROM #P WHERE TMAX < 16;

    ---------------------------------------------------------------- regla 3
    /* CALOR -> no gastar descuento.
       Palitos hace 2,09 y Familiar 1,99 solos con mas de 30 grados.
       Descontarlos ahi es regalar margen a quien ya venia a comprar. */
    INSERT dbo.ESTRATEGIA_SUGERENCIA
        (OBJETIVO_ID, SUCURSAL, FECHA, TIPO, TITULO, DETALLE, EVIDENCIA)
    SELECT @ObjetivoId, SUCURSAL, DIA, 'PROMO',
           'Dia de calor: frenar descuentos',
           'La demanda viene sola. Descontar hoy es resignar margen sobre gente ' +
           'que iba a comprar igual. Guardar la promo para el valle de la semana.',
           'Con mas de 30 grados Palitos vende 2,09 veces su promedio y Familiar 1,99, sin promocion.'
    FROM #P
    WHERE TMAX >= 28 AND @metrica IN ('FACTURACION', 'MARGEN');

    ---------------------------------------------------------------- regla 4
    /* LLUVIA. La regla mas importante del motor, y la que estaba peor armada.
       Antes disparaba con "llovio alguna hora y fueron al menos cuatro", que
       trata igual a una lluvia de madrugada y a un temporal sobre la tarde.

       Ahora dispara por EXPOSICION: cuanto de la venta del dia cae en horas con
       lluvia. Son dos mensajes distintos segun el tramo, porque las decisiones
       son distintas:

         tramo 2 (10-25%)  ~ -12%  rotar el mix, el dia se salva
         tramo 3-4 (>25%)  -22/-30% ademas de rotar, ajustar compra y dotacion:
                                     un dia asi no se recupera con mostrador

       Un dia de menos del 10% de exposicion NO genera sugerencia: historicamente
       no se distingue de un dia seco y avisar por el solo entrena a ignorar los
       avisos. */
    INSERT dbo.ESTRATEGIA_SUGERENCIA
        (OBJETIVO_ID, SUCURSAL, FECHA, TIPO, TITULO, DETALLE, EVIDENCIA)
    SELECT @ObjetivoId, SUCURSAL, DIA, 'MIX',
           CASE WHEN TRAMO_LLUVIA >= 3
                THEN 'Lluvia sobre el horario fuerte: esperar ' +
                     CAST(CAST(ROUND(ISNULL(IMPACTO_LLUVIA, -25), 0) AS int) AS varchar(10)) + '%'
                ELSE 'Lluvia parcial: rota hacia lo que se lleva' END,
           CASE WHEN TRAMO_LLUVIA >= 3
                THEN 'Llueve encima de ' + CAST(CAST(ROUND(EXPOSICION, 0) AS int) AS varchar(10)) +
                     '% de la venta del dia. No es un dia de mostrador: reforzar tortas y postres, ' +
                     'bajar la preparacion de bocha y cucurucho, y no sobrecargar el turno. ' +
                     'Conviene mover a este dia lo que se pueda de la compra y del personal.'
                ELSE 'Llueve sobre ' + CAST(CAST(ROUND(EXPOSICION, 0) AS int) AS varchar(10)) +
                     '% de la venta. Cae el consumo en el momento y se sostiene el de llevar: ' +
                     'reforzar tortas y postres, y no esperar trafico de bocha ni cucurucho.' END,
           'Medido sobre 2024-2026 en esta sucursal: un dia con esta exposicion vende ' +
           CAST(ISNULL(IMPACTO_LLUVIA, -25) AS varchar(10)) + '% contra un dia SECO del mismo dia de ' +
           'semana y la misma temperatura. Para comparar, ir de 14 a 34 grados suma un 22%: ' +
           'la lluvia sobre el horario de venta pesa mas que el termometro. ' +
           'Ademas rota el consumo: Helado x Bocha 0,84 y Gridos 0,89, mientras Tortas y Tentacion quedan en 1,00.'
    FROM #P
    WHERE TRAMO_LLUVIA >= 2;

    ---------------------------------------------------------------- regla 5
    /* SEMANA FRIA -> decir la verdad sobre el mix.
       Una sola por sucursal y por ventana, no por dia. Y dice explicitamente
       que NO se puede compensar: los grupos que sostienen con frio suman
       menos del 6% de la venta. Prometer un balanceo que no existe seria
       vender humo. */
    INSERT dbo.ESTRATEGIA_SUGERENCIA
        (OBJETIVO_ID, SUCURSAL, FECHA, TIPO, TITULO, DETALLE, EVIDENCIA)
    SELECT @ObjetivoId, SUCURSAL, NULL, 'MIX',
           'Semana fresca: el mix rota, pero no se compensa',
           'Con frio cae practicamente todo. Los unicos grupos que sostienen o suben ' +
           'suman menos del 6% de la venta, asi que no alcanzan para cubrir la caida. ' +
           'Lo que si conviene: empujar cafeteria, que es el unico que crece, y no ' +
           'gastar promocion en palitos.',
           'Indices con frio: Cafeteria 1,39 (unico que sube), Frizzio 1,02, Congelados 0,91. ' +
           'En contra: Palitos 0,44, Familiar 0,52, Helado x Kilo 0,73. ' +
           'Cafeteria hoy pesa 0,59% de la venta: hay lugar para crecer.'
    FROM #P
    GROUP BY SUCURSAL
    HAVING AVG(TMAX) < 18;

    ---------------------------------------------------------------- regla 6
    /* VALLE -> es el unico lugar donde el descuento se paga.
       El dia mas flojo de la ventana por sucursal. Solo si el objetivo es
       facturacion o kilos: si se busca margen, descontar en el valle tampoco
       ayuda. */
    IF @metrica IN ('FACTURACION', 'KILOS')
        INSERT dbo.ESTRATEGIA_SUGERENCIA
            (OBJETIVO_ID, SUCURSAL, FECHA, TIPO, TITULO, DETALLE, EVIDENCIA)
        SELECT @ObjetivoId, p.SUCURSAL, p.DIA, 'PROMO',
               'Valle de la semana: aca si conviene la promo',
               CONCAT('Es el dia mas flojo esperado (maxima ',
                      CAST(CAST(p.TMAX AS decimal(4,1)) AS varchar(8)),
                      ' grados). Una promocion aca genera trafico en vez de ',
                      'regalar margen sobre demanda que ya existe.',
                      CASE WHEN @metrica = 'KILOS'
                           THEN ' Para kilos, el 2x1 en formatos grandes es el que mueve.'
                           ELSE '' END),
               'El descuento rinde donde falta demanda, no donde sobra.'
        FROM #P p
        WHERE p.TMAX = (SELECT MIN(q.TMAX) FROM #P q WHERE q.SUCURSAL = p.SUCURSAL);

    DECLARE @sucursales int = (SELECT COUNT(*) FROM dbo.ESTRATEGIA_OBJETIVO_SUCURSAL
                               WHERE OBJETIVO_ID = @ObjetivoId);
    DROP TABLE #P;

    ---------------------------------------------------------------- consolidar
    /* Cuando la misma sugerencia aplica a TODAS las sucursales del objetivo,
       se deja una sola con SUCURSAL nula.

       Las cuatro estan en la misma zona y comparten el pronostico, asi que
       sin esto la semana sale con ocho alertas casi identicas. Una lista larga
       de obviedades repetidas es la forma mas rapida de que alguien deje de
       leer la pantalla; conviene decir cada cosa una vez. */
    /* Se decide PRIMERO cual sobrevive de cada grupo completo y recien
       despues se borra. Al reves habria que adivinar despues del borrado
       cuales quedaron solas porque se consolidaron y cuales porque nunca
       aplicaron a todas, que son casos distintos. */
    CREATE TABLE #Cons (QUEDA int PRIMARY KEY);

    INSERT #Cons
    SELECT MIN(SUGERENCIA_ID)
    FROM dbo.ESTRATEGIA_SUGERENCIA
    WHERE OBJETIVO_ID = @ObjetivoId AND ESTADO = 'SUGERIDA' AND SUCURSAL IS NOT NULL
    GROUP BY TIPO, FECHA, TITULO
    HAVING COUNT(DISTINCT SUCURSAL) = @sucursales AND @sucursales > 1;

    DELETE s
    FROM dbo.ESTRATEGIA_SUGERENCIA s
    WHERE s.OBJETIVO_ID = @ObjetivoId AND s.ESTADO = 'SUGERIDA'
      AND s.SUCURSAL IS NOT NULL
      AND s.SUGERENCIA_ID NOT IN (SELECT QUEDA FROM #Cons)
      AND EXISTS (SELECT 1 FROM dbo.ESTRATEGIA_SUGERENCIA q
                  JOIN #Cons c ON c.QUEDA = q.SUGERENCIA_ID
                  WHERE q.TIPO = s.TIPO AND q.TITULO = s.TITULO
                    AND (q.FECHA = s.FECHA OR (q.FECHA IS NULL AND s.FECHA IS NULL)));

    UPDATE s SET SUCURSAL = NULL
    FROM dbo.ESTRATEGIA_SUGERENCIA s
    JOIN #Cons c ON c.QUEDA = s.SUGERENCIA_ID;

    DROP TABLE #Cons;

    ---------------------------------------------------------------- resultado
    SELECT TIPO, SUCURSAL, FECHA, TITULO, DETALLE, EVIDENCIA
    FROM dbo.ESTRATEGIA_SUGERENCIA
    WHERE OBJETIVO_ID = @ObjetivoId AND ESTADO = 'SUGERIDA'
    ORDER BY CASE TIPO WHEN 'OPERATIVO' THEN 1 WHEN 'PROMO' THEN 2
                       WHEN 'SOBREVENTA' THEN 3 ELSE 4 END,
             SUCURSAL, FECHA;
END
GO
