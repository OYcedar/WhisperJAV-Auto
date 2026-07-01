@echo off
set "BASE=%~dp0"
set "WT=%LOCALAPPDATA%\Microsoft\WindowsApps\wt.exe"
set "PS=C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%WT%" (
    "%WT%" -w new nt --title "WhisperJAV-Auto Stop" "%PS%" -NoProfile -ExecutionPolicy Bypass -NoExit -File "%BASE%internal\Stop-WhisperJAV-Auto.ps1"
) else (
    "%PS%" -NoProfile -ExecutionPolicy Bypass -NoExit -File "%BASE%internal\Stop-WhisperJAV-Auto.ps1"
)
