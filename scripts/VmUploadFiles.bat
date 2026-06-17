@echo off
setlocal
set "REPO=%~dp0.."
set "KEY=%REPO%\_run\vm_ssh_key"
set "SSHOPT=-o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL"

for /f "usebackq delims=" %%i in (`powershell -NoProfile -ExecutionPolicy Bypass -Command ". '%REPO%\config\Config.ps1'; '{0}@{1}' -f $CloudInitConfig.VmUser,$NetworkConfig.VmGateway"`) do set "TARGET=%%i"

scp -i "%KEY%" %SSHOPT% -r "%REPO%\vm-files" %TARGET%:/tmp/loopv-vm-files
ssh -i "%KEY%" %SSHOPT% %TARGET% "sudo mkdir -p /etc/loopv && sudo cp /tmp/loopv-vm-files/* /etc/loopv/ && sudo chmod +x /etc/loopv/*.sh && rm -rf /tmp/loopv-vm-files && echo Uploaded vm-files to /etc/loopv"
endlocal
