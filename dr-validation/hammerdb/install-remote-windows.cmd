@echo off
setlocal
set "DATA_ROOT=C:\ProgramData\ramendr-dr-validation"
set "DONE_FLAG=%DATA_ROOT%\install.done"
set "FAIL_FLAG=%DATA_ROOT%\install.failed"
set "INSTALL_LOG=%DATA_ROOT%\install.log"
set "RUN_TOKEN=%~1"
if "%RUN_TOKEN%"=="" set "RUN_TOKEN=%RAMENDR_INSTALL_TOKEN%"
if "%RUN_TOKEN%"=="" set "RUN_TOKEN=default"

if not exist C:\Temp mkdir C:\Temp
if not exist "%DATA_ROOT%" mkdir "%DATA_ROOT%"
if not exist C:\Temp\ramendr-dr-validation-install mkdir C:\Temp\ramendr-dr-validation-install
del /f /q "%DONE_FLAG%" "%FAIL_FLAG%" 2>nul
del /f /q "%INSTALL_LOG%" 2>nul
powershell -NoProfile -ExecutionPolicy Bypass -Command "Remove-Item -LiteralPath '%DONE_FLAG%','%FAIL_FLAG%','%INSTALL_LOG%' -Force -ErrorAction SilentlyContinue" >nul 2>nul

tar -xzf C:\Temp\payload.tgz -C C:\Temp\ramendr-dr-validation-install

> C:\Temp\run-hammer-install.cmd (
  echo @echo off
  echo set REPO_ROOT=C:\Temp\ramendr-dr-validation-install
  echo echo [ramendr] install start token=%RUN_TOKEN% %%date%% %%time%% ^> "%INSTALL_LOG%"
  echo powershell -NoProfile -ExecutionPolicy Bypass -File "%%REPO_ROOT%%\hammerdb\install-on-vm-windows.ps1" ^>^> "%INSTALL_LOG%" 2^>^&1
  echo if errorlevel 1 ^(
  echo   echo FAILED token=%RUN_TOKEN%^> "%FAIL_FLAG%"
  echo   exit /b 1
  echo ^)
  echo echo [ramendr] install complete token=%RUN_TOKEN% %%date%% %%time%% ^>^> "%INSTALL_LOG%"
  echo echo OK token=%RUN_TOKEN%^> "%DONE_FLAG%"
)

schtasks /Delete /TN "RamenDRHammerInstall" /F 2>nul
schtasks /Create /TN "RamenDRHammerInstall" /TR "C:\Temp\run-hammer-install.cmd" /SC ONCE /ST 00:00 /RU SYSTEM /RL HIGHEST /F
if errorlevel 1 exit /b 1
schtasks /Run /TN "RamenDRHammerInstall"
if errorlevel 1 exit /b 1
exit /b 0
