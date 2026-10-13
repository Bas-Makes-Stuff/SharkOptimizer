@echo off
rem Starts SharkOptimizer. The scripts can sit in a "data" folder next to this file, or in the same folder.
set "L=%~dp0data\SharkOptimizer-Launcher.ps1"
if not exist "%L%" set "L=%~dp0SharkOptimizer-Launcher.ps1"
if not exist "%L%" (
  echo Could not find SharkOptimizer-Launcher.ps1 in the data folder or next to this file.
  pause
  exit /b 1
)
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%L%"
