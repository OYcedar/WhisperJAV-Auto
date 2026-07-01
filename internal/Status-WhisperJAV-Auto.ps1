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
$CurrentPidFile = Join-Path $BaseDir "current-pid.txt"
$MainPidFile = Join-Path $BaseDir "main-pid.txt"
$CurrentTaskFile = Join-Path $BaseDir "current-task.json"
$LastTaskFile = Join-Path $BaseDir "last-task.json"
$LogDir = Join-Path $BaseDir "logs"
$FailedVideoFile = Join-Path $BaseDir "failed-videos.txt"

if (Test-Path -LiteralPath $EnableFlag) {
    Write-Host "状态：ON，中文字幕自动生成已开启。"
} else {
    Write-Host "状态：OFF，中文字幕自动生成已关闭。"
}

Write-Host "DeepSeek 模型：$DeepSeekModel"
Write-Host "目标语言：$TargetLanguage"
Write-Host "翻译风格：$TranslateTone"

Write-Host ""

if (Test-Path -LiteralPath $MainPidFile) {
    $mainPidText = Get-Content -LiteralPath $MainPidFile -ErrorAction SilentlyContinue | Select-Object -First 1
    $mainProcess = Get-Process -Id ([int]$mainPidText) -ErrorAction SilentlyContinue

    if ($mainProcess) {
        Write-Host "主脚本 PID：$mainPidText，正在运行。"
    } else {
        Write-Host "主脚本 PID：$mainPidText，但进程不存在。"
    }
} else {
    Write-Host "当前没有记录中的主脚本任务。"
}

if (Test-Path -LiteralPath $CurrentPidFile) {
    $pidText = Get-Content -LiteralPath $CurrentPidFile -ErrorAction SilentlyContinue | Select-Object -First 1
    $process = Get-Process -Id ([int]$pidText) -ErrorAction SilentlyContinue

    if ($process) {
        Write-Host "当前步骤 PID：$pidText，正在运行。"
    } else {
        Write-Host "当前步骤 PID：$pidText，但进程不存在。"
    }
} else {
    Write-Host "当前没有记录中的步骤进程。"
}

if (Test-Path -LiteralPath $CurrentTaskFile) {
    Write-Host ""
    Write-Host "当前任务："
    $task = Get-Content -LiteralPath $CurrentTaskFile -Encoding UTF8 -Raw | ConvertFrom-Json
    Write-Host "更新时间：$($task.updatedAt)"
    Write-Host "状态：$($task.status)"
    Write-Host "步骤：$($task.step)"
    Write-Host "视频：$($task.videoPath)"
    Write-Host "工作目录：$($task.jobDir)"
    Write-Host "日志：$($task.logFile)"
} elseif (Test-Path -LiteralPath $LastTaskFile) {
    Write-Host ""
    Write-Host "最近一次任务："
    $task = Get-Content -LiteralPath $LastTaskFile -Encoding UTF8 -Raw | ConvertFrom-Json
    Write-Host "更新时间：$($task.updatedAt)"
    Write-Host "状态：$($task.status)"
    Write-Host "步骤：$($task.step)"
    Write-Host "视频：$($task.videoPath)"
    Write-Host "工作目录：$($task.jobDir)"
    Write-Host "日志：$($task.logFile)"
}

Write-Host ""
if (Test-Path -LiteralPath $FailedVideoFile) {
    $failedCount = @(Get-Content -LiteralPath $FailedVideoFile -Encoding UTF8 -ErrorAction SilentlyContinue |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
    Write-Host "失败跳过清单：$failedCount 个视频。"
}

Write-Host ""
Write-Host "最近工作目录："

Get-ChildItem -LiteralPath $WorkRoot -Directory -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 5 |
    ForEach-Object {
        $srtFiles = @(Get-ChildItem -LiteralPath $_.FullName -File -Filter "*.srt" -ErrorAction SilentlyContinue)
        $jaCount = @($srtFiles | Where-Object { $_.Name -match '(\.ja\.merged\.whisperjav|\.ja\.pass1|\.ja\.whisperjav|\.ja\.)' -and $_.Name -notmatch 'zh|cn|chi|chinese|translated|translation|中文' }).Count
        $zhCount = @($srtFiles | Where-Object { $_.Name -match 'zh|cn|chi|chinese|translated|translation|中文' }).Count
        Write-Host ("{0} | 日语SRT:{1} 中文字幕:{2}" -f $_.FullName, $jaCount, $zhCount)
    }

Write-Host ""
Write-Host "最近日志："

Get-ChildItem -LiteralPath $LogDir -Filter "*.log" -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 5 |
    ForEach-Object {
        Write-Host $_.FullName
    }

pause

