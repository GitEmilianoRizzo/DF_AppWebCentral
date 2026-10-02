# WebApp Central DF Group

## Regla del modulo de ventas

Todo cambio que toque ventas tiene que pasar por el agente `AgenteAuditoriaVentas` ANTES de publicarlo o commitearlo. Eso incluye:

- el SQL del DWH en `database/dwh/` (huella, agregado, informes, cargas, cuadre)
- los controladores y DTOs de ventas
- las pantallas Informe Diario GRIDO y Estadistica de Ventas
- `frontend/src/services/api.ts`
- el job `C:\PILL-DF\APPs\01.03_job_HuellaDiaria`

El agente cruza los montos de todos los informes contra SmartFran y devuelve APROBADO o RECHAZADO. Un RECHAZADO no se publica.

Para auditar a mano, sin el agente:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\auditoria_ventas\Auditar-Ventas.ps1           # ultimos 7 dias
powershell -NoProfile -ExecutionPolicy Bypass -File tools\auditoria_ventas\Auditar-Ventas.ps1 -Dias 30
```

## Ramas

- `main`: lo que esta publicado en produccion.
- `dev/...`: cambios en desarrollo, esperando definicion o publicacion.

Desarrollo corre desde este mismo directorio: la API en 7200 (Debug) y el front de Vite en 3000.

La base DF_DTW es UNA SOLA para desarrollo y produccion. Un SP desplegado lo ven los dos al instante. Por eso, mientras un cambio no se publique, solo se pueden desplegar cambios compatibles: agregar columnas o tablas, nunca cambiar el valor de una que ya existe.

## Excel de las 13:00 (Informe Diario GRIDO)

La fuente versionada esta en `reporting/informe_grido/`. La tarea programada "GRIDO - Informe Diario" corre desde `C:\PILL-DF\APPs\01.01_app_ReportingVentasBase`, que no esta en git.

- El `config.ini` de la copia del repo solo manda a Emiliano y no copia a Drive. Nunca va a git, porque tiene la contrasena de Gmail.
- Para probar: `informe_cli.py --fecha AAAA-MM-DD --sin-mail --sin-drive`.
- Para publicar:
  1. Hacer backup de `informe_grido.py` e `informe_cli.py` de produccion.
  2. Copiar los dos archivos del repo encima.
  3. Correr `TAREA_INFORME_DIARIO.bat <fecha> --sin-mail` en produccion para verificar.

## Publicar en produccion (puerto 7100)

Produccion corre como la tarea programada "DF WebApp - Deploy 7100", en S4U y sesion 0. Una consola sin elevacion no puede matar ese proceso, y la DLL queda bloqueada mientras corre.

Lo que funciona:

1. Compilar a una carpeta aparte: `dotnet build -c Release -o <staging>`.
2. Renombrar la `DFGroup.Api.dll` en uso (Windows permite renombrar una DLL cargada) y copiar la nueva con `[IO.File]::Copy`. `Copy-Item` puede fallar sin avisar.
3. Verificar los archivos copiados por hash, en un comando separado.
4. Probar la DLL nueva en otro puerto (por ejemplo 7101) antes de tocar produccion.
5. `Stop-ScheduledTask` y despues `Start-ScheduledTask`. `SERVICIO_7100_Deploy.bat` libera el puerto y relanza la app.
