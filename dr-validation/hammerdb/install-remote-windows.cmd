@echo off
setlocal
if not exist C:\Temp mkdir C:\Temp
if not exist C:\Temp\ramendr-dr-validation-install mkdir C:\Temp\ramendr-dr-validation-install
tar -xzf C:\Temp\payload.tgz -C C:\Temp\ramendr-dr-validation-install
set REPO_ROOT=C:\Temp\ramendr-dr-validation-install
powershell -NoProfile -ExecutionPolicy Bypass -File "%REPO_ROOT%\hammerdb\install-on-vm-windows.ps1"
exit /b %ERRORLEVEL%
