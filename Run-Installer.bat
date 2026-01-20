@echo off
setlocal

set "script=%~dp0HMD-WrapperUI.ps1"
if not exist "%script%" (
  echo Could not find "%script%".
  echo Place this .bat in the same folder as the installer.
  pause
  exit /b 1
)

powershell.exe -Sta -NoProfile -ExecutionPolicy Bypass -File "HMD-WrapperUI.ps1"

endlocal
