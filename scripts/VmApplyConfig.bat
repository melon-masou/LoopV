@echo off
setlocal
set "REPO=%~dp0.."
set "KEY=%REPO%\_run\vm_ssh_key"
set "SSHOPT=-o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL"

for /f "usebackq delims=" %%i in (`powershell -NoProfile -ExecutionPolicy Bypass -Command ". '%REPO%\config\Config.ps1'; '{0}@{1}' -f $CloudInitConfig.VmUser,$NetworkConfig.VmGateway"`) do set "TARGET=%%i"
if not defined TARGET goto :failed

ssh -i "%KEY%" %SSHOPT% %TARGET% "rm -rf /tmp/loopv-apply && mkdir -p /tmp/loopv-apply"
if errorlevel 1 goto :failed

scp -i "%KEY%" %SSHOPT% -r "%REPO%\vm-files" %TARGET%:/tmp/loopv-apply/
if errorlevel 1 goto :failed

scp -i "%KEY%" %SSHOPT% "%REPO%\config\VmLoopVConfig.env" %TARGET%:/tmp/loopv-apply/VmLoopVConfig.env
if errorlevel 1 goto :failed

ssh -i "%KEY%" %SSHOPT% %TARGET% "sudo mkdir -p /etc/loopv/tproxy.env.d && sudo cp /tmp/loopv-apply/vm-files/* /etc/loopv/ && sudo cp /tmp/loopv-apply/vm-files/loopv-init.sh /opt/loopv-init.sh && sudo cp /tmp/loopv-apply/vm-files/loopv-tproxy.service /etc/systemd/system/loopv-tproxy.service && sudo cp /tmp/loopv-apply/VmLoopVConfig.env /etc/loopv/tproxy.env.d/VmLoopVConfig.env && sudo chmod +x /etc/loopv/*.sh /opt/loopv-init.sh && sudo systemctl daemon-reload && sudo systemctl restart loopv-tproxy.service && rm -rf /tmp/loopv-apply"
if errorlevel 1 goto :failed

echo VM configuration applied successfully.
set "EXIT_CODE=0"
goto :done

:failed
echo ERROR: Failed to apply VM configuration.
set "EXIT_CODE=1"

:done
pause
endlocal & exit /b %EXIT_CODE%
