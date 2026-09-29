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

REM ---------------------------------------------------------------------------
REM Clave de firma de los tokens.
REM
REM Desarrollo la toma del mismo archivo que el deploy. Antes estaba escrita
REM dentro de appsettings.Development.json, pero ese archivo viaja al
REM repositorio, que es publico: cualquiera podia firmar tokens validos contra
REM una instancia en modo Desarrollo. Ahora no hay ninguna clave en el codigo.
REM
REM El doble guion bajo es como .NET anida configuracion: Jwt__Secret equivale
REM a la seccion Jwt, clave Secret.
REM ---------------------------------------------------------------------------
set "ARCHIVO_JWT=C:\PILL-DF\_secrets\webapp_jwt.txt"
if not exist "%ARCHIVO_JWT%" (
    echo [ERROR] Falta la clave de firma en %ARCHIVO_JWT%
    echo Generar una con:
    echo   powershell -Command "$b=New-Object byte[] 48;[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b);[Convert]::ToBase64String($b)^|Set-Content '%ARCHIVO_JWT%' -NoNewline"
    exit /b 1
)
set /p Jwt__Secret=<"%ARCHIVO_JWT%"

REM ---------------------------------------------------------------------------
REM Clave del correo saliente (avisos del modulo de Estrategia).
REM
REM Es una CONTRASENA DE APLICACION de Gmail, no la clave de la cuenta. Misma
REM logica que la de firma: fuera del codigo, porque appsettings.json viaja al
REM repositorio.
REM
REM Si falta, la app levanta igual y el modulo de Estrategia funciona entero;
REM lo unico que no se puede es mandar el aviso a los locales. No vale la pena
REM frenar todo por eso.
REM ---------------------------------------------------------------------------
set "ARCHIVO_SMTP=C:\PILL-DF\_secrets\webapp_smtp.txt"
if exist "%ARCHIVO_SMTP%" (
    set /p Smtp__Password=<"%ARCHIVO_SMTP%"
) else (
    echo [AVISO] Falta %ARCHIVO_SMTP%: no se van a poder enviar los avisos de Estrategia.
)

echo Levantando backend  (http://localhost:7100) ...
start "DFGroup API" cmd /k "cd /d "%~dp0backend\DFGroup.Api" && set PATH=%RT%\dotnet;%PATH% && set Jwt__Secret=%Jwt__Secret% && set Smtp__Password=%Smtp__Password% && dotnet run"

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
