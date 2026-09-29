/* ===========================================================================
   Modelo de expectativa: cuanto se deberia vender dadas las condiciones.
   ---------------------------------------------------------------------------
   POR QUE EXISTE
   --------------
   Para medir si una estrategia funciono hay que compararla contra algo. La
   semana anterior no sirve (otro clima) y el mismo mes del ano pasado tampoco
   (otro clima y otro tamano de negocio). La unica comparacion honesta es
   contra lo que era esperable DADAS LAS CONDICIONES QUE HUBO: "con estas
   temperaturas y estas lluvias lo normal eran $X; hicimos $Y".

   Sin esto, cualquier semana calurosa hace parecer genial a cualquier
   estrategia.

   COMO FUNCIONA
   -------------
   Es un promedio historico por (sucursal, dia de semana, hora, franja de
   temperatura, llovio o no). Nada de modelos entrenados: con 2 anos y pico de
   historia el promedio explica casi todo, y sobre todo se puede EXPLICAR en
   una frase. Un numero que Damian no pueda discutir no lo va a usar.

   RETROCESO POR FALTA DE DATOS
   ----------------------------
   Muchas combinaciones tienen poca historia: en Mayorista a las 8 de la
   manana con 34 grados puede no haber pasado nunca. En vez de devolver un
   promedio de dos observaciones, se va soltando dimensiones hasta juntar
   suficientes casos, y se informa CON QUE nivel se respondio:

     1. sucursal + dia + hora + temperatura + lluvia   (el ideal)
     2. sucursal + dia + hora + temperatura
     3. sucursal + dia + hora
     4. sucursal + hora

   Devolver "no se" es una respuesta valida y mejor que inventar. Es lo que
   separa una herramienta que se usa de una que se quema la primera vez que
   sugiere una pavada.
   =========================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_EstrategiaEsperado
    @Sucursal    int,
    @DiaSemana   int,           -- 1 = lunes .. 7 = domingo
    @Hora        int,
    @Temperatura numeric(6,2),
    @Lluvia      bit          = 0,
    /* Maxima del dia anterior. Con esto se aplica el ajuste por salto
       termico: un dia que sube 5 grados o mas vende ~19% arriba de lo que
       explica su temperatura. Si no se informa, no se ajusta y se avisa. */
    @TempMaxAyer numeric(6,2) = NULL,
    @MinCasos    int          = 30,
    @DesdeHist   date         = '2024-01-01',
    @BaseOrigen  varchar(30)  = 'SRV_GRIDO_ZSUR'
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @franja int = CAST(FLOOR(@Temperatura / 2) * 2 AS int);

    /* Ajuste por como LLEGO la temperatura, no solo cuanto marca.
       El factor sale de DIM_AJUSTE_SALTO_TEMP, calibrado con la historia. */
    DECLARE @salto numeric(6,2) = @Temperatura - @TempMaxAyer;
    DECLARE @factor numeric(8,4) = 1, @etiquetaSalto varchar(60) = 'sin ajuste (no se informo la maxima de ayer)';

    IF @TempMaxAyer IS NOT NULL
    BEGIN
        SELECT TOP 1 @factor = a.FACTOR,
               @etiquetaSalto = a.ETIQUETA + ' (' + CAST(CAST(@salto AS decimal(5,1)) AS varchar(10)) + ' grados)'
        FROM dbo.DIM_AJUSTE_SALTO_TEMP a
        WHERE a.BASE_ORIGEN = @BaseOrigen
          AND @salto >= a.SALTO_DESDE AND @salto < a.SALTO_HASTA
          AND a.CONFIABLE = 1;

        IF @@ROWCOUNT = 0
        BEGIN
            SET @factor = 1;
            SET @etiquetaSalto = 'sin ajuste (no hay calibracion confiable para ese salto)';
        END
    END

    /* Una fila por ticket: las metricas del negocio se miden por ticket, no
       por linea. Sumar lineas contaria dos veces el mismo cliente. */
    CREATE TABLE #T (
        TICKET_KEY varchar(90) PRIMARY KEY,
        SUCURSAL   int,
        DIA_SEMANA int,
        HORA       tinyint,
        FRANJA     int,
        LLOVIA     bit,
        IMPORTE    numeric(18,4),
        MARGEN     numeric(18,4),
        KILOS      numeric(18,6)
    );

    INSERT #T
    SELECT h.TICKET_KEY,
           MAX(h.SUCURSAL),
           MAX((DATEDIFF(day, '1900-01-01', h.FECHA_HORA) % 7) + 1),
           MAX(h.HORA),
           CAST(FLOOR(MAX(c.TEMPERATURA) / 2) * 2 AS int),
           MAX(CASE WHEN c.LLUVIA > 0 THEN 1 ELSE 0 END),
           SUM(h.IMPORTE),
           SUM(h.CONTRIB_MARGINAL),
           SUM(h.KILOS)
    FROM dbo.TRX_HUELLA_VENTA h
    JOIN dbo.CLIMA_ZONA_HORA c
         ON c.BASE_ORIGEN = h.BASE_ORIGEN AND c.SUCURSAL = h.SUCURSAL
        AND c.CLIMA_KEY_HORA = h.CLIMA_KEY_HORA
    WHERE h.BASE_ORIGEN = @BaseOrigen
      AND h.SUCURSAL = @Sucursal
      AND h.ES_ANULADA = 0
      AND h.FECHA_OPERATIVA >= @DesdeHist
      AND h.HORA = @Hora
    GROUP BY h.TICKET_KEY;

    /* Se prueban los niveles de mayor a menor precision y se corta en el
       primero que junta @MinCasos. */
    DECLARE @nivel varchar(60), @casos int;

    ;WITH candidatos AS (
        /* OJO con el nombre de esta columna: NO puede llamarse igual que un
           alias de salida del SELECT final. Se llamaba "nivel" y el SELECT
           exponia "Nivel = precision_"; SQL Server resuelve el ORDER BY
           contra el alias de SALIDA antes que contra la columna de origen, y
           sin distinguir mayusculas. Resultado: ordenaba alfabeticamente por
           el texto de la precision y elegia siempre "sucursal+dia+hora",
           ignorando la temperatura. El modelo parecia andar y no miraba el
           clima. */
        SELECT orden_nivel = 1, precision_ = 'sucursal+dia+hora+temperatura+lluvia',
               casos = COUNT(*), tickets_hora = CAST(COUNT(*) AS numeric(18,4)),
               importe = AVG(IMPORTE), margen = AVG(MARGEN), kilos = AVG(KILOS)
        FROM #T WHERE DIA_SEMANA = @DiaSemana AND FRANJA = @franja AND LLOVIA = @Lluvia
        UNION ALL
        SELECT 2, 'sucursal+dia+hora+temperatura',
               COUNT(*), CAST(COUNT(*) AS numeric(18,4)),
               AVG(IMPORTE), AVG(MARGEN), AVG(KILOS)
        FROM #T WHERE DIA_SEMANA = @DiaSemana AND FRANJA = @franja
        UNION ALL
        SELECT 3, 'sucursal+dia+hora',
               COUNT(*), CAST(COUNT(*) AS numeric(18,4)),
               AVG(IMPORTE), AVG(MARGEN), AVG(KILOS)
        FROM #T WHERE DIA_SEMANA = @DiaSemana
        UNION ALL
        SELECT 4, 'sucursal+hora',
               COUNT(*), CAST(COUNT(*) AS numeric(18,4)),
               AVG(IMPORTE), AVG(MARGEN), AVG(KILOS)
        FROM #T
    )
    SELECT TOP 1
        Sucursal        = @Sucursal,
        DiaSemana       = @DiaSemana,
        Hora            = @Hora,
        Franja          = @franja,
        Lluvia          = @Lluvia,
        Nivel           = precision_,
        Casos           = casos,
        /* Casos son tickets historicos en esa condicion. Para pasar a
           "tickets esperados en una hora" hay que dividir por cuantas veces
           se dio la condicion, que se calcula afuera con el pronostico. */
        TicketBase      = CAST(importe AS numeric(18,2)),
        AjusteSalto     = @etiquetaSalto,
        Factor          = @factor,
        -- Lo ajustado es lo que hay que usar para comparar y para decidir.
        TicketPromedio  = CAST(importe * @factor AS numeric(18,2)),
        MargenPromedio  = CAST(margen  * @factor AS numeric(18,2)),
        KilosPromedio   = CAST(kilos   * @factor AS numeric(18,4)),
        Confiable       = CASE WHEN casos >= @MinCasos THEN CAST(1 AS bit) ELSE CAST(0 AS bit) END
    FROM candidatos
    WHERE casos >= @MinCasos
    ORDER BY orden_nivel;

    /* Si ningun nivel llego al minimo, se devuelve explicitamente que no hay
       evidencia en vez de un promedio flojo disfrazado de dato. */
    IF @@ROWCOUNT = 0
        SELECT Sucursal = @Sucursal, DiaSemana = @DiaSemana, Hora = @Hora,
               Franja = @franja, Lluvia = @Lluvia,
               Nivel = 'sin evidencia suficiente', Casos = 0,
               TicketBase = CAST(NULL AS numeric(18,2)),
               AjusteSalto = @etiquetaSalto, Factor = @factor,
               TicketPromedio = CAST(NULL AS numeric(18,2)),
               MargenPromedio = CAST(NULL AS numeric(18,2)),
               KilosPromedio  = CAST(NULL AS numeric(18,4)),
               Confiable = CAST(0 AS bit);

    DROP TABLE #T;
END
GO
