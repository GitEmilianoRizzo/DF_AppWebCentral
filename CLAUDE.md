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

## Publicar en produccion (puerto 7100)

Produccion corre como la tarea programada "DF WebApp - Deploy 7100", en S4U y sesion 0. Una consola sin elevacion no puede matar ese proceso, y la DLL queda bloqueada mientras corre.

Lo que funciona:

1. Compilar a una carpeta aparte: `dotnet build -c Release -o <staging>`.
2. Renombrar la `DFGroup.Api.dll` en uso (Windows permite renombrar una DLL cargada) y copiar la nueva con `[IO.File]::Copy`. `Copy-Item` puede fallar sin avisar.
3. Verificar los archivos copiados por hash, en un comando separado.
4. Probar la DLL nueva en otro puerto (por ejemplo 7101) antes de tocar produccion.
5. `Stop-ScheduledTask` y despues `Start-ScheduledTask`. `SERVICIO_7100_Deploy.bat` libera el puerto y relanza la app.
