@echo off
setlocal

net session >nul 2>&1
if not "%errorlevel%"=="0" (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -WorkingDirectory '%~dp0' -Verb RunAs"
  if errorlevel 1 pause
  exit /b
)

for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -Command ". '%~dp0..\config\Config.ps1'; $NetworkConfig.InternalSwitchName"`) do set "SWITCH_NAME=%%I"
if "%SWITCH_NAME%"=="" (
  echo Cannot read InternalSwitchName from "%~dp0..\config\Config.ps1"
  pause
  exit /b 1
)

set "TASK_NAME=\LoopV\AttachWslSwitch-%SWITCH_NAME%"
set "EXE=%~dp0..\_run\WSLAttachSwitch.exe"

if not exist "%EXE%" (
  echo Cannot find "%EXE%"
  pause
  exit /b 1
)

echo Registering scheduled task %TASK_NAME%...
schtasks.exe /Create /TN "%TASK_NAME%" /TR "\"%EXE%\" \"%SWITCH_NAME%\"" /SC ONCE /ST 23:59 /RL HIGHEST /F
if not "%errorlevel%"=="0" (
  echo Failed to register scheduled task.
  pause
  exit /b 1
)

echo.
echo Registered %TASK_NAME%
echo Run it with:
echo   schtasks.exe /Run /TN "%TASK_NAME%"
echo.
pause
endlocal & exit /b 0
