@echo off
echo ========================================
echo   Parser Service - DF Group
echo   Starting on http://localhost:8000
echo ========================================
echo.

cd /d "%~dp0"

:: Check if venv exists
if not exist "venv" (
    echo Creating virtual environment...
    python -m venv venv
    call venv\Scripts\activate
    pip install -r requirements.txt
) else (
    call venv\Scripts\activate
)

echo.
echo Starting FastAPI server...
echo API Docs: http://localhost:8000/docs
echo.

uvicorn main:app --host 0.0.0.0 --port 8000 --reload
