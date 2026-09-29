# DF_DTW — el almacen de datos

Scripts de la base `DF_DTW` en `WIN-6ARG3SUELOE\SQLEXPRESS`: las tablas de la
huella de venta, el clima, los modelos calibrados y el modulo de Estrategia.

## Por que estan aca y no solo en el servidor

Hasta el 29/09/2026 vivian unicamente en `C:\PILL-DF\SQL\DF_DTW`, en el disco
de ese equipo, sin control de versiones. Son 300 KB donde esta **casi toda la
logica de negocio**: como se mide la venta, como se estima lo esperado dado el
clima, como se calibra el impacto de la lluvia. El codigo de la aplicacion sin
esto no reproduce ningun numero.

Se copian al repositorio para que existan en mas de un lugar. La copia
autoritativa para ejecutar sigue siendo la del servidor; esta es el respaldo
versionado y el historial de como fue cambiando el modelo.

## Como se aplican

Cada archivo es idempotente: las tablas se crean con `IF OBJECT_ID(...) IS
NULL`, las columnas nuevas con `IF COL_LENGTH(...) IS NULL ... ALTER TABLE`, y
los procedimientos con `CREATE OR ALTER`. Se pueden correr varias veces sin
romper nada.

```
sqlcmd -S "WIN-6ARG3SUELOE\SQLEXPRESS" -E -C -d DF_DTW -b -W -i <archivo>.sql
```

## Orden cuando se levanta de cero

El orden importa solo en estos casos:

1. `TRX_HUELLA_VENTA` y su carga, mas `CLIMA_ZONA_HORA`: son la base de todo.
2. `DIM_PESO_HORA` antes de `AGG_VENTA_DIA`, porque la exposicion a la lluvia
   se pondera con esos pesos.
3. `AGG_VENTA_DIA` antes de `DIM_IMPACTO_LLUVIA` y de `usp_MedirObjetivo`, que
   leen el agregado y no la huella cruda.
4. `ESTRATEGIA_CICLO` antes de los `usp_Estrategia_*`.

Despues, una carga completa del agregado:

```sql
EXEC dbo.usp_CalibrarPesoHora;
EXEC dbo.usp_CargarAggVentaDia @Rehacer = 1;
EXEC dbo.usp_RecalibrarModelos;
```

## Lo que corre solo

`APPs\01.03_job_HuellaDiaria\PILL_huellaventaDiaria.bat`, todos los dias a las
12:30, en seis pasos: huella, clima, agregado diario, pronostico,
recalibracion de modelos y medicion de los objetivos vigentes. Esta encajado
entre el restore de las 12:00 y el Informe Diario de las 13:00.

## Lo que hay que saber antes de tocar el modelo

- **En terminos relativos, nunca en pesos.** Con la inflacion argentina,
  promediar pesos de dos anos y medio hace que cualquier dia de hoy le gane a
  cualquier promedio historico.
- **La lluvia no es un bit.** Lo que explica la caida es la EXPOSICION: cuanto
  de la venta del dia cae en horas con lluvia. Un dia con menos del 10%
  expuesto no se distingue de uno seco; uno con mas de la mitad vende un 30%
  menos. `LLOVIO` los mete en la misma bolsa.
- **Misma definicion a los dos lados.** El modelo se calibra con el clima del
  pasado (`CLIMA_ZONA_HORA`) y se le pide una prediccion con el del futuro
  (`CLIMA_PRONOSTICO_HORA`). Si una definicion cambia, hay que cambiar las dos
  o el modelo compara cosas distintas sin avisar.
- **El desvio no significa nada sin el ruido al lado.** El error tipico de un
  dia es del 20% en los locales de mostrador. Un +8% en una semana esta dentro
  del ruido.
- **Mayorista no sigue el clima.** Su error tipico es del 51%: vende por
  pedidos de otros comercios, no por la temperatura en su puerta.
