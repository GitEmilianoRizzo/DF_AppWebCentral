@echo off
REM ===========================================================================
REM SERVICIO_7100_Deploy
REM
REM Arranque automatico de la aplicacion PRODUCTIVA al encender el servidor.
REM Lo dispara la tarea programada "DF WebApp - Deploy 7100".
REM
REM POR QUE ES UN ENVOLTORIO Y NO SE TOCA INICIAR_DEPLOY.bat
REM -------------------------------------------------------
REM Porque INICIAR_DEPLOY.bat se usa tambien a mano, y porque cmd.exe relee los
REM .bat por posicion de byte: editar uno mientras esta corriendo hace que
REM retome en un offset corrido y reejecute lineas sueltas. Paso el 29/09/2026
REM y dejo un proceso fantasma ocupando el puerto. El envoltorio permite
REM cambiar la logica de arranque sin tocar el archivo que esta en ejecucion.
REM
REM QUE AGREGA
REM ----------
REM Espera. Al encender, la app arranca antes que sus dependencias:
REM
REM   Tailscale  si la interfaz todavia no levanto, su IP no existe y la app
REM              queda escuchando SOLO en 127.0.0.1. Desde afuera no se ve, y
REM              nadie se entera hasta que alguien intenta entrar.
REM   SQL Server la app tolera que no este (conecta por consulta), pero si
REM              arranca antes, el primer usuario se come un error.
REM
REM Sin esta espera el arranque automatico funcionaria casi siempre, que es la
REM peor forma de funcionar.
REM ===========================================================================
setlocal enabledelayedexpansion
cd /d "%~dp0"

if not exist "logs" mkdir "logs"
for /f %%i in ('powershell -NoProfile -Command "Get-Date -Format yyyy-MM-dd"') do set "HOY=%%i"
set "LOG=%~dp0logs\arranque_7100_%HOY%.log"

call :log "============================================================"
call :log "Arranque automatico de la app productiva (7100)"

REM -------------------------------------------------- limpieza de sobrantes
REM Ni "Stop-ScheduledTask" ni "schtasks /End" matan el arbol: terminan este
REM cmd y dejan vivo el dotnet que cuelga de el. Ese huerfano se queda con el
REM puerto y el arranque siguiente falla con "address already in use".
REM
REM Tampoco se lo puede matar desde una sesion interactiva comun: al correr con
REM S4U vive en la sesion 0 y hace falta elevacion. Pero ESTE script si puede,
REM porque corre en el mismo contexto. Por eso la limpieza va aca y no afuera.
REM
REM Se mata por PUERTO y no por nombre de proceso: es lo que de verdad estorba,
REM y evita llevarse puesta la instancia de desarrollo, que es otro dotnet.
call :log "Liberando el puerto 7100 si quedo algo de una corrida anterior"
powershell -NoProfile -Command "Get-NetTCPConnection -State Listen -LocalPort 7100 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique | ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }" >nul 2>&1
timeout /t 3 /nobreak >nul

REM ------------------------------------------------------- espera: Tailscale
REM Hasta 3 minutos. Es generoso a proposito: un arranque en frio con
REM actualizaciones pendientes puede tardar, y es mejor demorar la app que
REM publicarla a medias.
set "TSIP="
set /a INTENTO=0
:espera_ts
set /a INTENTO+=1
set "ARCHIVO_IP=%TEMP%\dfgroup_arranque_ip.txt"
if exist "%ARCHIVO_IP%" del "%ARCHIVO_IP%" >nul 2>&1
powershell -NoProfile -Command "Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object InterfaceAlias -like 'Tailscale*' | Select-Object -First 1 -ExpandProperty IPAddress | Set-Content -Encoding ascii -NoNewline '%ARCHIVO_IP%'" >nul 2>&1
if exist "%ARCHIVO_IP%" set /p TSIP=<"%ARCHIVO_IP%"
if exist "%ARCHIVO_IP%" del "%ARCHIVO_IP%" >nul 2>&1
if not "!TSIP!"=="" goto :ts_listo
if !INTENTO! GEQ 18 goto :ts_sin_ip
call :log "Tailscale todavia sin IP (intento !INTENTO! de 18). Se espera 10 segundos."
timeout /t 10 /nobreak >nul
goto :espera_ts

:ts_sin_ip
call :log "ATENCION: Tailscale no levanto en 3 minutos. La app va a quedar solo en 127.0.0.1."
goto :espera_sql

:ts_listo
call :log "Tailscale listo en !TSIP! (intento !INTENTO!)."

REM ------------------------------------------------------ espera: SQL Server
:espera_sql
set /a INTENTO=0
:reintento_sql
set /a INTENTO+=1
sqlcmd -S "WIN-6ARG3SUELOE\SQLEXPRESS" -E -C -b -l 5 -Q "SELECT 1" >nul 2>&1
if not errorlevel 1 goto :sql_listo
if !INTENTO! GEQ 18 (
    call :log "ATENCION: SQL Server no respondio en 3 minutos. Se levanta igual."
    goto :levantar
)
call :log "SQL Server todavia no responde (intento !INTENTO! de 18). Se espera 10 segundos."
timeout /t 10 /nobreak >nul
goto :reintento_sql

:sql_listo
call :log "SQL Server responde (intento !INTENTO!)."

REM ------------------------------------------------------------- a levantar
:levantar
call :log "Llamando a INICIAR_DEPLOY.bat"
REM CALL y no START: la tarea programada tiene que quedar viva mientras la app
REM corre. Si terminara, el Programador la daria por completada y no habria
REM forma de reiniciarla ante una caida.
call "%~dp0INICIAR_DEPLOY.bat"
set "RC=!ERRORLEVEL!"
call :log "INICIAR_DEPLOY.bat termino con codigo !RC!. La app ya no esta corriendo."
endlocal & exit /b %RC%

REM ---------------------------------------------------------------------------
:log
for /f %%t in ('powershell -NoProfile -Command "Get-Date -Format HH:mm:ss"') do set "T=%%t"
echo %T%  %~1
>> "%LOG%" echo %T%  %~1
exit /b 0
