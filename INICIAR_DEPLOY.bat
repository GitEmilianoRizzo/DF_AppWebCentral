@echo off
REM ===========================================================================
REM DF Group - WebApp Central  (modo deploy, un solo puerto)
REM
REM Levanta UN solo proceso que sirve la API y el frontend ya compilado desde
REM wwwroot. Para desarrollo seguir usando INICIAR_APP.bat, que levanta Vite
REM aparte con recarga en caliente.
REM
REM DONDE ESCUCHA Y POR QUE
REM -----------------------
REM   http://127.0.0.1:7100        solo desde este equipo
REM   http://100.91.239.59:7100    solo desde la red Tailscale
REM
REM Se ata a esas dos direcciones A PROPOSITO, y NO a 0.0.0.0. Este servidor
REM tiene la IP publica 69.10.52.78 directamente en su placa de red: atarlo a
REM 0.0.0.0 publicaria la aplicacion en internet. Atado asi, la IP publica ni
REM siquiera tiene el puerto abierto.
REM
REM Para que alguien entre desde afuera tiene que estar en la red Tailscale:
REM no hace falta abrir ningun puerto ni tocar el firewall.
REM
REM ANTES DE LEVANTARLO, si se cambio el codigo:
REM   cd frontend  ^&^& npm run build
REM   xcopy /E /I /Y frontend\dist backend\DFGroup.Api\wwwroot
REM   cd backend\DFGroup.Api ^&^& dotnet build -c Release
REM ===========================================================================
setlocal
set "RT=C:\PILL-DF\_runtime"
set "PATH=%RT%\dotnet;%PATH%"
set "ASPNETCORE_ENVIRONMENT=Production"
set "DOTNET_CLI_TELEMETRY_OPTOUT=1"

REM ---------------------------------------------------------------------------
REM Clave de firma de los tokens.
REM
REM appsettings.json trae "Secret": "${JWT_SECRET}" y .NET NO expande esa
REM sintaxis: la toma como texto literal de 13 caracteres, o sea 104 bits, y
REM HS256 exige 128 como minimo. En Desarrollo no se notaba porque
REM appsettings.Development.json la pisa con una clave larga; en Produccion el
REM login devolvia 400 con "IDX10653".
REM
REM La clave real vive FUERA del repositorio y se inyecta por variable de
REM entorno. El doble guion bajo es como .NET anida configuracion: Jwt__Secret
REM equivale a la seccion Jwt, clave Secret.
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
REM Es una CONTRASENA DE APLICACION de Gmail, de 16 caracteres, no la clave de
REM la cuenta. Fuera del repositorio por la misma razon que la de firma.
REM
REM A diferencia de la de firma, su ausencia NO frena el arranque: sin ella la
REM app funciona entera y lo unico que no se puede es mandar el aviso a los
REM locales. La pantalla lo dice con todas las letras cuando pasa.
REM ---------------------------------------------------------------------------
set "ARCHIVO_SMTP=C:\PILL-DF\_secrets\webapp_smtp.txt"
if exist "%ARCHIVO_SMTP%" (
    set /p Smtp__Password=<"%ARCHIVO_SMTP%"
) else (
    echo [AVISO] Falta %ARCHIVO_SMTP%: no se van a poder enviar los avisos de Estrategia.
)

REM ---------------------------------------------------------------------------
REM La IP de Tailscale se consulta en vivo: si cambia, el .bat sigue andando.
REM
REM Se prueban DOS caminos, y el segundo no es un lujo. El CLI de Tailscale
REM queda tomado por la sesion de usuario que tenga abierta la aplicacion, y a
REM cualquier otra le contesta:
REM
REM   401 Unauthorized: Tailscale already in use by WIN-6ARG3SUELOE\Administrator
REM
REM Cuando eso pasa, el .bat creia que Tailscale estaba caido y levantaba la
REM app SOLO en 127.0.0.1: desde afuera dejaba de verse, aunque la red estaba
REM perfecta. Paso el 29/09/2026 al publicar.
REM
REM La placa de red no tiene ese problema: la IP esta ahi la tenga tomada quien
REM la tenga. Por eso si el CLI no contesta se lee la interfaz Tailscale.
REM ---------------------------------------------------------------------------
REM OJO al tocar esto: el segundo intento NO va dentro de un "if (...)" ni
REM dentro de un "for /f". El comando de PowerShell lleva parentesis, comillas
REM simples y barras verticales, y meterlo en cualquiera de esas dos
REM construcciones termina en un "no se encuentra el archivo powershell" o en
REM un bloque cerrado antes de tiempo. Escribiendo la IP a un archivo y
REM leyendola con "set /p" no hay nada que escapar: todo el comando viaja
REM dentro de un solo par de comillas, que ya protege las barras.
set "TSIP="
for /f "tokens=*" %%i in ('"%ProgramFiles%\Tailscale\tailscale.exe" ip -4 2^>nul') do set "TSIP=%%i"
if not "%TSIP%"=="" goto :tiene_ip

set "ARCHIVO_IP=%TEMP%\dfgroup_tsip.txt"
if exist "%ARCHIVO_IP%" del "%ARCHIVO_IP%" >nul 2>&1
powershell -NoProfile -Command "Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object InterfaceAlias -like 'Tailscale*' | Select-Object -First 1 -ExpandProperty IPAddress | Set-Content -Encoding ascii -NoNewline '%ARCHIVO_IP%'" >nul 2>&1
if exist "%ARCHIVO_IP%" set /p TSIP=<"%ARCHIVO_IP%"
if exist "%ARCHIVO_IP%" del "%ARCHIVO_IP%" >nul 2>&1
if not "%TSIP%"=="" echo [INFO] El CLI de Tailscale no contesto; la IP se leyo de la placa de red.

:tiene_ip

if "%TSIP%"=="" (
    echo [ATENCION] Tailscale no responde. Se levanta solo para este equipo.
    set "ASPNETCORE_URLS=http://127.0.0.1:7100"
) else (
    set "ASPNETCORE_URLS=http://127.0.0.1:7100;http://%TSIP%:7100"
)

echo.
echo   Escuchando en: %ASPNETCORE_URLS%
echo.
echo   Local          http://localhost:7100
if not "%TSIP%"=="" echo   Por Tailscale  http://%TSIP%:7100
echo   API / Swagger  /swagger
echo.

REM Se ejecuta la DLL compilada y NO "dotnet run": launchSettings.json impone
REM su propio applicationUrl (localhost:7100) y pisaba ASPNETCORE_URLS, con lo
REM que la app quedaba sin escuchar en Tailscale.
cd /d "%~dp0backend\DFGroup.Api"
dotnet "bin\Release\net9.0\DFGroup.Api.dll"

endlocal
