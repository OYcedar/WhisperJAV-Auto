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
$TranslationPidFile = Join-Path $BaseDir "translation-pids.txt"
$GlobalLockFile = Join-Path $BaseDir "whisperjav-auto.lock"
$CurrentTaskFile = Join-Path $BaseDir "current-task.json"
$LastTaskFile = Join-Path $BaseDir "last-task.json"

function Stop-ProcessTree {
    param([int]$ProcessId)

    $children = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ParentProcessId -eq $ProcessId }

    foreach ($child in $children) {
        Stop-ProcessTree -ProcessId ([int]$child.ProcessId)
    }

    try {
        Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
    } catch {}
}

function Stop-WhisperJavAutoProcesses {
    $currentPid = $PID
    $excludedPids = @{}
    $cursorPid = $currentPid

    while ($cursorPid) {
        $excludedPids[[int]$cursorPid] = $true
        $cursor = Get-CimInstance Win32_Process -Filter "ProcessId=$cursorPid" -ErrorAction SilentlyContinue
        if ($null -eq $cursor -or $null -eq $cursor.ParentProcessId -or $cursor.ParentProcessId -eq 0) {
            break
        }
        $cursorPid = [int]$cursor.ParentProcessId
    }

    $patterns = @(
        $BaseDir,
        $WorkRoot,
        (Join-Path $WhisperJavInstallDir "Scripts\whisperjav"),
        (Join-Path $WhisperJavInstallDir "python.exe"),
        "multiprocessing.spawn",
        "whisperjav-translate"
    )

    $processes = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            if ($excludedPids.ContainsKey([int]$_.ProcessId) -or [string]::IsNullOrWhiteSpace($_.CommandLine)) {
                return $false
            }

            $commandLine = $_.CommandLine
            foreach ($pattern in $patterns) {
                if ($commandLine -like "*$pattern*") {
                    return $true
                }
            }

            return $false
        }

    foreach ($process in ($processes | Sort-Object ProcessId -Descending)) {
        try {
            Write-Host "正在停止残留相关进程树 PID: $($process.ProcessId) ($($process.Name))"
            Stop-ProcessTree -ProcessId ([int]$process.ProcessId)
        } catch {}
    }
}

Remove-Item -LiteralPath $EnableFlag -Force -ErrorAction SilentlyContinue
Write-Host "WhisperJAV-Auto 已关闭。"

schtasks /Change /TN "WhisperJAV NAS Chinese Auto Hourly" /DISABLE 2>$null

if (Test-Path -LiteralPath $CurrentTaskFile) {
    Write-Host ""
    Write-Host "当前任务记录："
    Get-Content -LiteralPath $CurrentTaskFile -Encoding UTF8 -ErrorAction SilentlyContinue |
        ForEach-Object { Write-Host $_ }

    try {
        $task = Get-Content -LiteralPath $CurrentTaskFile -Encoding UTF8 -Raw | ConvertFrom-Json
        $task.status = "stop_requested"
        $task.updatedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        $task | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $LastTaskFile -Encoding UTF8

        if ($task.videoPath) {
            $videoLockFile = "$($task.videoPath).whisperjav.lock"
            Remove-Item -LiteralPath $videoLockFile -Force -ErrorAction SilentlyContinue
        }
    } catch {}
} elseif (Test-Path -LiteralPath $LastTaskFile) {
    try {
        $task = Get-Content -LiteralPath $LastTaskFile -Encoding UTF8 -Raw | ConvertFrom-Json
        if ($task.status -eq "running" -or $task.status -eq "starting" -or $task.status -eq "translation_started") {
            $task.status = "stop_requested"
            $task.updatedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            $task | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $LastTaskFile -Encoding UTF8
        }

        if ($task.videoPath) {
            $videoLockFile = "$($task.videoPath).whisperjav.lock"
            Remove-Item -LiteralPath $videoLockFile -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

if (Test-Path -LiteralPath $CurrentPidFile) {
    $pidText = Get-Content -LiteralPath $CurrentPidFile -ErrorAction SilentlyContinue | Select-Object -First 1

    if ($pidText) {
        try {
            $processId = [int]$pidText
            Write-Host ""
            Write-Host "正在停止当前步骤进程树 PID: $processId"
            Stop-ProcessTree -ProcessId $processId
        } catch {}
    }
}

if (Test-Path -LiteralPath $TranslationPidFile) {
    $translationPids = Get-Content -LiteralPath $TranslationPidFile -ErrorAction SilentlyContinue |
        Where-Object { $_ -match '^\d+$' } |
        ForEach-Object { [int]$_ } |
        Sort-Object -Unique

    $staleTranslationPidCount = 0
    foreach ($translationPidText in $translationPids) {
        if ($translationPidText) {
            try {
                $translationPid = [int]$translationPidText
                $translationProcess = Get-Process -Id $translationPid -ErrorAction SilentlyContinue

                if ($null -ne $translationProcess) {
                    Write-Host "正在停止后台翻译进程树 PID: $translationPid"
                    Stop-ProcessTree -ProcessId $translationPid
                } else {
                    $staleTranslationPidCount++
                }
            } catch {}
        }
    }

    if ($staleTranslationPidCount -gt 0) {
        Write-Host "已忽略不存在的历史后台翻译 PID：$staleTranslationPidCount 个"
    }
}

if (Test-Path -LiteralPath $MainPidFile) {
    $mainPidText = Get-Content -LiteralPath $MainPidFile -ErrorAction SilentlyContinue | Select-Object -First 1

    if ($mainPidText) {
        try {
            $mainPid = [int]$mainPidText
            Write-Host "正在停止主脚本进程 PID: $mainPid"
            Stop-Process -Id $mainPid -Force -ErrorAction SilentlyContinue
        } catch {}
    }
}

Remove-Item -LiteralPath $CurrentPidFile -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $MainPidFile -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $TranslationPidFile -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $CurrentTaskFile -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $GlobalLockFile -Force -ErrorAction SilentlyContinue

Stop-WhisperJavAutoProcesses

Write-Host ""
Write-Host "已停止。正在处理中的视频会在下次开启后重新处理。"
pause


