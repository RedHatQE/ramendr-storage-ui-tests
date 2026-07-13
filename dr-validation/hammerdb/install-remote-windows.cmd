@echo off
setlocal
set "DATA_ROOT=C:\ProgramData\ramendr-dr-validation"
set "DONE_FLAG=%DATA_ROOT%\install.done"
set "FAIL_FLAG=%DATA_ROOT%\install.failed"
set "INSTALL_LOG=%DATA_ROOT%\install.log"

if not exist C:\Temp mkdir C:\Temp
if not exist "%DATA_ROOT%" mkdir "%DATA_ROOT%"
if not exist C:\Temp\ramendr-dr-validation-install mkdir C:\Temp\ramendr-dr-validation-install
del /f /q "%DONE_FLAG%" "%FAIL_FLAG%" 2>nul

tar -xzf C:\Temp\payload.tgz -C C:\Temp\ramendr-dr-validation-install

> C:\Temp\run-hammer-install.cmd (
  echo @echo off
  echo set REPO_ROOT=C:\Temp\ramendr-dr-validation-install
  echo powershell -NoProfile -ExecutionPolicy Bypass -File "%%REPO_ROOT%%\hammerdb\install-on-vm-windows.ps1" ^>^> "%INSTALL_LOG%" 2^>^&1
  echo if errorlevel 1 ^(
  echo   echo FAILED^> "%FAIL_FLAG%"
  echo   exit /b 1
  echo ^)
  echo echo OK^> "%DONE_FLAG%"
)

schtasks /Delete /TN "RamenDRHammerInstall" /F 2>nul
schtasks /Create /TN "RamenDRHammerInstall" /TR "C:\Temp\run-hammer-install.cmd" /SC ONCE /ST 00:00 /RU SYSTEM /RL HIGHEST /F
if errorlevel 1 exit /b 1
schtasks /Run /TN "RamenDRHammerInstall"
if errorlevel 1 exit /b 1
exit /b 0
