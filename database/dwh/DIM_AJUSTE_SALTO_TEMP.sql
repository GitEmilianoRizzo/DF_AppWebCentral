/* ===========================================================================
   DIM_AJUSTE_SALTO_TEMP
   ---------------------------------------------------------------------------
   Cuanto se desvia la venta de lo esperado segun COMO LLEGO la temperatura,
   no solo cuanto marca.

   EL HALLAZGO
   -----------
   Damian lo planteo por intuicion y los datos lo confirman: un dia que salta
   5 grados o mas respecto del anterior vende un 18,6% MAS de lo que explica
   su temperatura. Subir 2 a 5 grados vale +6,9%. Son 2,5 anos de historia y
   el efecto es monotonico: a mayor salto, mayor desvio.

   DONDE NO SE CONFIRMO
   --------------------
   La intuicion incluia que a la baja pasaba lo mismo al reves. NO ocurre:
   bajar 5 grados o mas da +2,2%, no una caida. Lo que se percibe como
   derrumbe es el dia excepcional que termino; contra lo NORMAL para esa
   temperatura, la venta simplemente se normaliza. Importa para no emitir
   alertas de "prepararse para vender menos" que serian falsas.

   POR QUE UN FACTOR Y NO UNA DIMENSION MAS
   ----------------------------------------
   Sumar el salto a las cinco dimensiones que ya tiene el modelo de
   expectativa multiplicaria las celdas y dejaria a casi todas sin casos, que
   es justo lo que el retroceso por niveles trata de evitar. Como factor
   multiplicativo se aplica encima de una expectativa que sigue teniendo
   muchas observaciones detras.

   Los factores se CALCULAN de la historia, no se escriben a mano, y quedan en
   tabla para poder discutirlos.
   =========================================================================== */

IF OBJECT_ID('dbo.DIM_AJUSTE_SALTO_TEMP', 'U') IS NOT NULL
    DROP TABLE dbo.DIM_AJUSTE_SALTO_TEMP;
GO

CREATE TABLE dbo.DIM_AJUSTE_SALTO_TEMP (
    BASE_ORIGEN  varchar(30)   NOT NULL,
    ORDEN        int           NOT NULL,
    ETIQUETA     varchar(40)   NOT NULL,
    SALTO_DESDE  numeric(6,2)  NOT NULL,   -- inclusive
    SALTO_HASTA  numeric(6,2)  NOT NULL,   -- exclusive
    DIAS         int           NOT NULL,
    DESVIO_PCT   numeric(8,2)  NOT NULL,
    FACTOR       numeric(8,4)  NOT NULL,
    CONFIABLE    bit           NOT NULL,
    FECHA_CALIB  datetime2(0)  NOT NULL CONSTRAINT DF_DAST_FECHA DEFAULT SYSDATETIME(),
    CONSTRAINT PK_DIM_AJUSTE_SALTO_TEMP PRIMARY KEY (BASE_ORIGEN, ORDEN)
);
GO


CREATE OR ALTER PROCEDURE dbo.usp_CalibrarAjusteSalto
    @BaseOrigen varchar(30) = 'SRV_GRIDO_ZSUR',
    @DesdeHist  date        = '2024-01-01',
    @MinDias    int         = 40
AS
BEGIN
    SET NOCOUNT ON;

    /* Un renglon por sucursal y jornada, con la maxima del dia y la del
       anterior. Se usa la MAXIMA y no el promedio: para el consumo de helado
       lo que manda es cuanto calor hizo en el pico de la tarde. */
    CREATE TABLE #D (
        SUCURSAL int, DIA date, VENTA numeric(18,4),
        TMAX numeric(6,2), FRANJA int, DOW int, TMAX_AYER numeric(6,2)
    );

    INSERT #D
    SELECT v.SUCURSAL, v.DIA, v.VENTA, c.TMAX,
           CAST(FLOOR(c.TMAX / 2) * 2 AS int),
           (DATEDIFF(day, '1900-01-01', v.DIA) % 7) + 1,
           LAG(c.TMAX) OVER (PARTITION BY v.SUCURSAL ORDER BY v.DIA)
    FROM (SELECT SUCURSAL, DIA = FECHA_OPERATIVA, VENTA = SUM(IMPORTE)
          FROM dbo.TRX_HUELLA_VENTA
          WHERE BASE_ORIGEN = @BaseOrigen AND ES_ANULADA = 0
            AND FECHA_OPERATIVA >= @DesdeHist
          GROUP BY SUCURSAL, FECHA_OPERATIVA) v
    JOIN (SELECT SUCURSAL, DIA = CAST(CLIMA_KEY_HORA AS date), TMAX = MAX(TEMPERATURA)
          FROM dbo.CLIMA_ZONA_HORA
          WHERE BASE_ORIGEN = @BaseOrigen
          GROUP BY SUCURSAL, CAST(CLIMA_KEY_HORA AS date)) c
      ON c.SUCURSAL = v.SUCURSAL AND c.DIA = v.DIA;

    /* Expectativa por nivel, que es contra la que se mide el desvio. Pide 8
       observaciones minimas: con menos, el "esperado" es la propia fila y el
       residuo daria cero por construccion. */
    CREATE TABLE #E (SUCURSAL int, DOW int, FRANJA int, ESPERADO numeric(18,4));
    INSERT #E
    SELECT SUCURSAL, DOW, FRANJA, AVG(VENTA)
    FROM #D GROUP BY SUCURSAL, DOW, FRANJA HAVING COUNT(*) >= 8;

    DELETE FROM dbo.DIM_AJUSTE_SALTO_TEMP WHERE BASE_ORIGEN = @BaseOrigen;

    INSERT dbo.DIM_AJUSTE_SALTO_TEMP
        (BASE_ORIGEN, ORDEN, ETIQUETA, SALTO_DESDE, SALTO_HASTA,
         DIAS, DESVIO_PCT, FACTOR, CONFIABLE)
    SELECT @BaseOrigen, b.orden, b.etiqueta, b.desde, b.hasta,
           DIAS = COUNT(*),
           DESVIO = CAST(AVG(100.0 * (d.VENTA - e.ESPERADO) / NULLIF(e.ESPERADO, 0)) AS numeric(8,2)),
           FACTOR = CAST(1 + AVG((d.VENTA - e.ESPERADO) / NULLIF(e.ESPERADO, 0)) AS numeric(8,4)),
           CONFIABLE = CASE WHEN COUNT(*) >= @MinDias THEN 1 ELSE 0 END
    FROM #D d
    JOIN #E e ON e.SUCURSAL = d.SUCURSAL AND e.DOW = d.DOW AND e.FRANJA = d.FRANJA
    CROSS APPLY (VALUES
        (1, 'bajo 5 o mas',   -99.0,  -5.0),
        (2, 'bajo 2 a 5',      -5.0,  -2.0),
        (3, 'sin cambio',      -2.0,   2.0),
        (4, 'subio 2 a 5',      2.0,   5.0),
        (5, 'subio 5 o mas',    5.0,  99.0)
    ) b(orden, etiqueta, desde, hasta)
    WHERE d.TMAX_AYER IS NOT NULL
      AND (d.TMAX - d.TMAX_AYER) >= b.desde
      AND (d.TMAX - d.TMAX_AYER) <  b.hasta
    GROUP BY b.orden, b.etiqueta, b.desde, b.hasta;

    DROP TABLE #D; DROP TABLE #E;

    SELECT ORDEN, ETIQUETA, DIAS, DESVIO_PCT, FACTOR, CONFIABLE
    FROM dbo.DIM_AJUSTE_SALTO_TEMP
    WHERE BASE_ORIGEN = @BaseOrigen ORDER BY ORDEN;
END
GO

EXEC dbo.usp_CalibrarAjusteSalto;
GO
