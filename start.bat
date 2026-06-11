@echo off
setlocal

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start.ps1" %*
set EXIT_CODE=%ERRORLEVEL%

echo.
if not "%EXIT_CODE%"=="0" (
    echo Process exited with code %EXIT_CODE%.
)
pause
exit /b %EXIT_CODE%
