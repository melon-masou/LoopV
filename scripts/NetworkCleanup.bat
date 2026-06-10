@echo off
setlocal

net session >nul 2>&1
if not "%errorlevel%"=="0" (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%ComSpec%' -ArgumentList '/c ""%~f0""' -Verb RunAs"
    if errorlevel 1 pause
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\windows\NetworkApply.ps1" -Mode Cleanup
set "EXIT_CODE=%errorlevel%"
pause
endlocal & exit /b %EXIT_CODE%
