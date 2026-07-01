$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$ScriptDir = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { $PSScriptRoot }
$BaseDir = if ([System.IO.Path]::GetFileName($ScriptDir) -ieq "internal") { Split-Path -Parent $ScriptDir } else { $ScriptDir }
$InternalDir = Join-Path $BaseDir "internal"
$ConfigLoader = Join-Path $InternalDir "Load-WhisperJAV-Config.ps1"
if (!(Test-Path -LiteralPath $ConfigLoader)) {
    $ConfigLoader = Join-Path $BaseDir "Load-WhisperJAV-Config.ps1"
}
. $ConfigLoader
$EnableFlag = Join-Path $BaseDir "enabled.flag"
$ProgressScript = Join-Path $InternalDir "Show-WhisperJAV-Progress.ps1"
if (!(Test-Path -LiteralPath $ProgressScript)) {
    $ProgressScript = Join-Path $BaseDir "Show-WhisperJAV-Progress.ps1"
}

New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null
Set-Content -LiteralPath $EnableFlag -Value "enabled" -Encoding ASCII

Write-Host "WhisperJAV-Auto 已开启。"

schtasks /Change /TN "WhisperJAV NAS Chinese Auto Hourly" /ENABLE 2>$null

if (Test-Path -LiteralPath $WindowsTerminal) {
    Start-Process `
        -FilePath $WindowsTerminal `
        -ArgumentList "-w new nt --title `"WhisperJAV-Auto 任务进度`" `"$SystemPowerShell`" -NoProfile -ExecutionPolicy Bypass -NoExit -File `"$ProgressScript`"" `
        -WindowStyle Normal
} else {
    Start-Process `
        -FilePath $SystemPowerShell `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$ProgressScript`"" `
        -WindowStyle Normal
}

Write-Host "已打开任务进度窗口。关闭那个进度窗口即可中断当前任务进程。"
pause


