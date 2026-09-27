@echo off
REM ===========================================================================
REM DF Group - WebApp Central
REM
REM Levanta los dos procesos en ventanas separadas:
REM   backend  ASP.NET Core  http://localhost:7100  (Swagger en /swagger)
REM   frontend Vite + React  http://localhost:3000
REM
REM El frontend hace de proxy: todo lo que pida a /api lo reenvia al 7100, asi
REM que alcanza con abrir http://localhost:3000
REM
REM Los runtimes son portables y viven en C:\PILL-DF\_runtime. No hay nada
REM instalado a nivel maquina, por eso el PATH se arma aca.
REM ===========================================================================
setlocal
set "RT=C:\PILL-DF\_runtime"
set "PATH=%RT%\dotnet;%RT%\node;%RT%\git\cmd;%PATH%"
set "ASPNETCORE_ENVIRONMENT=Development"
set "DOTNET_CLI_TELEMETRY_OPTOUT=1"

if not exist "%RT%\dotnet\dotnet.exe" (
    echo [ERROR] Falta el SDK de .NET en %RT%\dotnet
    exit /b 1
)
if not exist "%RT%\node\node.exe" (
    echo [ERROR] Falta Node en %RT%\node
    exit /b 1
)

echo Levantando backend  (http://localhost:7100) ...
start "DFGroup API" cmd /k "cd /d "%~dp0backend\DFGroup.Api" && set PATH=%RT%\dotnet;%PATH% && dotnet run"

echo Esperando a que la API levante ...
timeout /t 12 /nobreak >nul

echo Levantando frontend (http://localhost:3000) ...
start "DFGroup Front" cmd /k "cd /d "%~dp0frontend" && set PATH=%RT%\node;%PATH% && npm run dev"

echo.
echo   Backend  http://localhost:7100/swagger
echo   Frontend http://localhost:3000
echo.
echo Para detener, cerrar las dos ventanas que se abrieron.
endlocal
