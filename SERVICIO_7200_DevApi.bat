@echo off
REM ===========================================================================
REM SERVICIO_7200_DevApi
REM
REM Arranque automatico de la API de DESARROLLO al encender el servidor.
REM Lo dispara la tarea programada "DF WebApp - Dev API 7200".
REM
REM POR QUE EN EL 7200 Y NO EN EL 7100
REM ----------------------------------
REM El 7100 es la app que usa la gente. Desarrollo tiene que poder reiniciarse,
REM romperse y recompilarse sin que nadie lo note, asi que vive en otro puerto y
REM sobre la compilacion Debug. Son dos procesos distintos leyendo la MISMA base
REM (DF_DTW): los procedimientos nuevos se ven en los dos al instante, y por eso
REM conviene probarlos en desarrollo antes de publicar la pantalla.
REM
REM SOLO ESCUCHA EN 127.0.0.1
REM -------------------------
REM A proposito. Desarrollo se consume a traves del front de Vite (puerto 3000),
REM que hace de proxy. No hay ninguna razon para exponer una compilacion Debug
REM en la red, ni siquiera en Tailscale.
REM
REM SI NO HACE FALTA DESARROLLO CORRIENDO SIEMPRE
REM ---------------------------------------------
REM Desactivar la tarea, no borrarla:
REM   Disable-ScheduledTask -TaskName "DF WebApp - Dev API 7200"
REM Son dos procesos mas en un servidor con la memoria justa (SQL Express topea
REM el buffer pool en 1.410 MB), asi que si no se esta trabajando, apagarlos es
REM razonable.
REM ===========================================================================
setlocal enabledelayedexpansion
cd /d "%~dp0"

set "RT=C:\PILL-DF\_runtime"
set "PATH=%RT%\dotnet;%PATH%"
set "ASPNETCORE_ENVIRONMENT=Development"
set "ASPNETCORE_URLS=http://127.0.0.1:7200"
set "DOTNET_CLI_TELEMETRY_OPTOUT=1"

if not exist "logs" mkdir "logs"
for /f %%i in ('powershell -NoProfile -Command "Get-Date -Format yyyy-MM-dd"') do set "HOY=%%i"
set "LOG=%~dp0logs\arranque_7200_%HOY%.log"

call :log "============================================================"
call :log "Arranque automatico de la API de desarrollo (7200)"

REM Limpieza de sobrantes: ver la explicacion larga en SERVICIO_7100_Deploy.bat.
REM Resumen: parar la tarea no mata el dotnet que cuelga de este cmd, y ese
REM huerfano se queda con el puerto.
call :log "Liberando el puerto 7200 si quedo algo de una corrida anterior"
powershell -NoProfile -Command "Get-NetTCPConnection -State Listen -LocalPort 7200 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique | ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }" >nul 2>&1
timeout /t 3 /nobreak >nul

REM ---------------------------------------------------------------- secretos
REM Los mismos dos archivos que usa produccion. La clave de firma es
REM obligatoria (sin ella la app no arranca); la de correo no, porque lo unico
REM que se pierde es el aviso a los locales.
set "ARCHIVO_JWT=C:\PILL-DF\_secrets\webapp_jwt.txt"
if not exist "%ARCHIVO_JWT%" (
    call :log "ERROR: falta la clave de firma en %ARCHIVO_JWT%. No se puede arrancar."
    endlocal & exit /b 1
)
set /p Jwt__Secret=<"%ARCHIVO_JWT%"

set "ARCHIVO_SMTP=C:\PILL-DF\_secrets\webapp_smtp.txt"
if exist "%ARCHIVO_SMTP%" (
    set /p Smtp__Password=<"%ARCHIVO_SMTP%"
) else (
    call :log "AVISO: falta %ARCHIVO_SMTP%. No se van a poder enviar los avisos de Estrategia."
)

REM ------------------------------------------------------ espera: SQL Server
set /a INTENTO=0
:reintento_sql
set /a INTENTO+=1
sqlcmd -S "WIN-6ARG3SUELOE\SQLEXPRESS" -E -C -b -l 5 -Q "SELECT 1" >nul 2>&1
if not errorlevel 1 goto :sql_listo
if !INTENTO! GEQ 18 (
    call :log "ATENCION: SQL Server no respondio en 3 minutos. Se levanta igual."
    goto :levantar
)
timeout /t 10 /nobreak >nul
goto :reintento_sql

:sql_listo
call :log "SQL Server responde (intento !INTENTO!)."

REM ------------------------------------------------------------- a levantar
:levantar
set "DLL=%~dp0backend\DFGroup.Api\bin\Debug\net9.0\DFGroup.Api.dll"
if not exist "%DLL%" (
    call :log "ERROR: falta %DLL%. Hay que compilar Debug una vez: dotnet build"
    endlocal & exit /b 2
)

call :log "Levantando en %ASPNETCORE_URLS%"
cd /d "%~dp0backend\DFGroup.Api"
REM Se ejecuta la DLL y NO "dotnet run": launchSettings.json impone su propio
REM applicationUrl y pisaria ASPNETCORE_URLS, con lo que desarrollo se pelearia
REM con produccion por el 7100.
dotnet "bin\Debug\net9.0\DFGroup.Api.dll"
set "RC=!ERRORLEVEL!"
call :log "La API de desarrollo termino con codigo !RC!."
endlocal & exit /b %RC%

REM ---------------------------------------------------------------------------
:log
for /f %%t in ('powershell -NoProfile -Command "Get-Date -Format HH:mm:ss"') do set "T=%%t"
echo %T%  %~1
>> "%LOG%" echo %T%  %~1
exit /b 0
