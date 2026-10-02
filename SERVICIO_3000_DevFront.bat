@echo off
REM ===========================================================================
REM SERVICIO_3000_DevFront
REM
REM Arranque automatico del frontend de DESARROLLO (Vite) al encender.
REM Lo dispara la tarea programada "DF WebApp - Dev Front 3000".
REM
REM QUE HACE VITE ACA
REM -----------------
REM Sirve el frontend con recarga en caliente y hace de PROXY: todo lo que la
REM pantalla pida a /api lo reenvia a la API de desarrollo. Por eso se apunta al
REM 7200 con VITE_API_PROXY; sin esa variable, vite.config.ts manda al 7100, o
REM sea a PRODUCCION, y uno creeria estar probando cambios que en realidad no
REM estan ahi. Es un error silencioso y cuesta caro.
REM
REM ESCUCHA EN LA IP DE TAILSCALE
REM ----------------------------
REM Para poder abrir desarrollo desde otra maquina de la red Tailscale. Si
REM Tailscale no levanto, se cae a 127.0.0.1 y al menos queda usable en el
REM propio servidor.
REM
REM SI NO HACE FALTA DESARROLLO CORRIENDO SIEMPRE
REM ---------------------------------------------
REM   Disable-ScheduledTask -TaskName "DF WebApp - Dev Front 3000"
REM ===========================================================================
setlocal enabledelayedexpansion
cd /d "%~dp0frontend"

set "RT=C:\PILL-DF\_runtime"
set "PATH=%RT%\node;%PATH%"
set "VITE_API_PROXY=http://127.0.0.1:7200"
set "VITE_PORT=3000"

if not exist "%~dp0logs" mkdir "%~dp0logs"
for /f %%i in ('powershell -NoProfile -Command "Get-Date -Format yyyy-MM-dd"') do set "HOY=%%i"
set "LOG=%~dp0logs\arranque_3000_%HOY%.log"

call :log "============================================================"
call :log "Arranque automatico del frontend de desarrollo (3000)"

REM Limpieza de sobrantes: ver la explicacion larga en SERVICIO_7100_Deploy.bat.
call :log "Liberando el puerto 3000 si quedo algo de una corrida anterior"
powershell -NoProfile -Command "Get-NetTCPConnection -State Listen -LocalPort 3000 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique | ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }" >nul 2>&1
timeout /t 3 /nobreak >nul

if not exist "%RT%\node\node.exe" (
    call :log "ERROR: falta Node en %RT%\node"
    endlocal & exit /b 1
)
if not exist "node_modules" (
    call :log "ERROR: falta node_modules. Correr una vez: npm install"
    endlocal & exit /b 2
)

REM --------------------------------------------------- espera: IP de Tailscale
REM Menos paciencia que produccion: si no aparece, desarrollo igual sirve en
REM localhost y no hay nadie esperando del otro lado.
set "TSIP="
set /a INTENTO=0
:espera_ts
set /a INTENTO+=1
set "ARCHIVO_IP=%TEMP%\dfgroup_front_ip.txt"
if exist "%ARCHIVO_IP%" del "%ARCHIVO_IP%" >nul 2>&1
powershell -NoProfile -Command "Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object InterfaceAlias -like 'Tailscale*' | Select-Object -First 1 -ExpandProperty IPAddress | Set-Content -Encoding ascii -NoNewline '%ARCHIVO_IP%'" >nul 2>&1
if exist "%ARCHIVO_IP%" set /p TSIP=<"%ARCHIVO_IP%"
if exist "%ARCHIVO_IP%" del "%ARCHIVO_IP%" >nul 2>&1
if not "!TSIP!"=="" goto :ts_listo
if !INTENTO! GEQ 9 (
    call :log "Tailscale no levanto en 90 segundos. Se sirve solo en 127.0.0.1."
    set "TSIP=127.0.0.1"
    goto :ts_listo
)
timeout /t 10 /nobreak >nul
goto :espera_ts

:ts_listo
call :log "Sirviendo en http://!TSIP!:%VITE_PORT% y con el proxy hacia %VITE_API_PROXY%"
call npx vite --host !TSIP!
set "RC=!ERRORLEVEL!"
call :log "Vite termino con codigo !RC!."
endlocal & exit /b %RC%

REM ---------------------------------------------------------------------------
:log
for /f %%t in ('powershell -NoProfile -Command "Get-Date -Format HH:mm:ss"') do set "T=%%t"
echo %T%  %~1
>> "%LOG%" echo %T%  %~1
exit /b 0
