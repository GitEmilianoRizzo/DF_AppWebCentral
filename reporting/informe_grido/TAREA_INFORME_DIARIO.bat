@echo off
setlocal
:: ===========================================================================
:: Informe Diario GRIDO - lanzador de la tarea programada de Windows
::
:: Calcula la fecha de AYER (equivalente a GETDATE() - 1) y se la pasa al
:: script como parametro --fecha.
::
:: La corrida de las 13:00 del dia D pide la fecha D-1, y el script cubre la
:: jornada comercial de esa fecha: de las 02:00 del dia D-1 a las 02:00 del
:: dia D. Ese periodo ya cerro 11 horas antes de la corrida, asi que el dato
:: esta completo. NO cambiar este -1 a 0: correria la fecha del informe a un
:: dia que todavia no termino.
::
:: Acepta un parametro opcional para forzar una fecha puntual:
::    TAREA_INFORME_DIARIO.bat 2026-08-30
:: y la bandera --sin-mail para probar sin enviar:
::    TAREA_INFORME_DIARIO.bat 2026-08-30 --sin-mail
:: ===========================================================================

cd /d "%~dp0"

set "VENV_PY=%~dp0.venv\Scripts\python.exe"
if not exist "%VENV_PY%" (
    echo [ERROR] Falta el entorno virtual: %VENV_PY%
    exit /b 1
)

:: Fecha: la del parametro 1 si vino, si no la de ayer.
set "FECHA=%~1"
if "%FECHA%"=="" (
    for /f %%d in ('powershell -NoProfile -Command "(Get-Date).AddDays(-1).ToString('yyyy-MM-dd')"') do set "FECHA=%%d"
)

:: Si el primer parametro era en realidad una bandera, no es una fecha.
echo %FECHA% | findstr /r "^--" >nul
if not errorlevel 1 (
    set "EXTRA=%*"
    for /f %%d in ('powershell -NoProfile -Command "(Get-Date).AddDays(-1).ToString('yyyy-MM-dd')"') do set "FECHA=%%d"
) else (
    set "EXTRA=%~2 %~3"
)

echo [%date% %time%] Ejecutando informe para la fecha %FECHA%
"%VENV_PY%" "%~dp0informe_cli.py" --fecha %FECHA% %EXTRA%
set "RC=%errorlevel%"

if "%RC%"=="0" (
    echo [OK] Proceso finalizado sin errores.
) else (
    echo [FALLO] El proceso termino con codigo %RC%. Revise la carpeta logs\.
)

exit /b %RC%
