@echo off
setlocal EnableExtensions EnableDelayedExpansion

net session >nul 2>&1
if not "%errorlevel%"=="0" (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -WorkingDirectory '%~dp0' -Verb RunAs"
  if errorlevel 1 pause
  exit /b
)

set "TASK_PREFIX=\LoopV\AttachWslSwitch-"
set "PORT_FORWARD_TASK=\LoopV\ApplyWslPortForwards"
set "DELETED=0"

for /f "tokens=*" %%T in ('schtasks.exe /Query /FO LIST ^| findstr /B /C:"TaskName: %TASK_PREFIX%"') do (
  set "TASK_LINE=%%T"
  setlocal enabledelayedexpansion
  set "TASK_NAME=!TASK_LINE:TaskName: =!"
  echo Unregistering scheduled task !TASK_NAME!...
  schtasks.exe /Delete /TN "!TASK_NAME!" /F
  if not "!errorlevel!"=="0" (
    endlocal
    echo Failed to unregister one or more scheduled tasks.
    pause
    exit /b 1
  )
  endlocal
  set "DELETED=1"
)

schtasks.exe /Query /TN "%PORT_FORWARD_TASK%" >nul 2>&1
if "%errorlevel%"=="0" (
  echo Unregistering scheduled task %PORT_FORWARD_TASK%...
  schtasks.exe /Delete /TN "%PORT_FORWARD_TASK%" /F
  if not "!errorlevel!"=="0" (
    echo Failed to unregister %PORT_FORWARD_TASK%.
    pause
    exit /b 1
  )
  set "DELETED=1"
)

if "%DELETED%"=="0" (
  echo No scheduled tasks found with prefix %TASK_PREFIX%
) else (
  echo.
  echo Unregistered scheduled tasks with prefix %TASK_PREFIX%
)

echo.
pause
endlocal & exit /b 0
