@echo off
setlocal
set "REPO=%~dp0.."

for /f "usebackq delims=" %%i in (`powershell -NoProfile -ExecutionPolicy Bypass -Command ". '%REPO%\config\Config.ps1'; '{0}@{1}' -f $CloudInitConfig.VmUser,$NetworkConfig.VmGateway"`) do set "TARGET=%%i"

ssh -i "%REPO%\_run\vm_ssh_key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL %TARGET% %*
endlocal
