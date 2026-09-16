@echo off
echo ========================================
echo   Toast Parser - DF Group
echo ========================================
echo.

cd /d "%~dp0"

echo Procesando archivos en input/...
echo.

python toast_parser.py --input input --output output

echo.
echo ========================================
echo   Proceso completado
echo ========================================
echo.
echo Los archivos JSON estan en: output/
echo.
pause
