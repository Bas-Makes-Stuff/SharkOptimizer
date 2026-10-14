@echo off
rem SharkOptimizer 2.0.1 startup entry point
setlocal

set "ROOT=%~dp0"
set "LAUNCHER=%ROOT%legacy\SharkOptimizer-Launcher.ps1"
set "POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%LAUNCHER%" (
    echo SharkOptimizer launcher was not found:
    echo "%LAUNCHER%"
    pause
    exit /b 1
)

if not exist "%POWERSHELL%" (
    echo Windows PowerShell 5.1 was not found:
    echo "%POWERSHELL%"
    pause
    exit /b 1
)

"%POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%LAUNCHER%"
if errorlevel 1 (
    echo The SharkOptimizer launcher exited with an error.
    pause
    exit /b 1
)

exit /b 0
