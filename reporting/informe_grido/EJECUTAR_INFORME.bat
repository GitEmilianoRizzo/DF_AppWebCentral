@echo off
title Informe Diario GRIDO
echo ============================================
echo    INFORME DIARIO GRIDO - Iniciando...
echo ============================================
echo.

:: Ir al directorio del script
cd /d "%~dp0"

:: Python del entorno virtual local (no depende del PATH del sistema)
set "VENV_PY=%~dp0.venv\Scripts\python.exe"

if not exist "%VENV_PY%" (
    echo [ERROR] No se encontro el entorno virtual en:
    echo   %VENV_PY%
    echo.
    echo Para recrearlo, ejecute:
    echo   C:\PILL-DF\_runtime\Python313\python.exe -m venv "%~dp0.venv"
    echo   "%VENV_PY%" -m pip install -r "%~dp0requirements.txt"
    pause
    exit /b 1
)

:: Verificar dependencias
"%VENV_PY%" -c "import streamlit, pandas, pyodbc, openpyxl" >nul 2>&1
if errorlevel 1 (
    echo Instalando dependencias por primera vez...
    echo Esto puede tomar unos minutos...
    echo.
    "%VENV_PY%" -m pip install -r "%~dp0requirements.txt" --quiet
    if errorlevel 1 (
        echo [ERROR] No se pudieron instalar las dependencias.
        pause
        exit /b 1
    )
    echo Dependencias instaladas correctamente.
    echo.
)

:: Ejecutar la aplicacion
echo Abriendo navegador...
echo.
echo ============================================
echo  La aplicacion se abrira en su navegador.
echo  Si no se abre sola, entre a: http://localhost:8501
echo  NO cierre esta ventana mientras la usa.
echo  Para cerrar, presione Ctrl+C aqui.
echo ============================================
echo.

"%VENV_PY%" -m streamlit run informe_grido.py --server.port=8501 --browser.gatherUsageStats=false

pause
