param(
    [Parameter(Mandatory = $true)][string]$BaseDir,
    [Parameter(Mandatory = $true)][string]$JapaneseSrt,
    [Parameter(Mandatory = $true)][string]$VideoPath,
    [Parameter(Mandatory = $true)][string]$JobDir
)

$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$env:PYTHONIOENCODING = "utf-8"

$LogDir = Join-Path $BaseDir "logs"
$ProcessLogDir = Join-Path $BaseDir "process-logs"
$InternalDir = Join-Path $BaseDir "internal"
$ConfigLoader = Join-Path $InternalDir "Load-WhisperJAV-Config.ps1"
if (!(Test-Path -LiteralPath $ConfigLoader)) {
    $ConfigLoader = Join-Path $BaseDir "Load-WhisperJAV-Config.ps1"
}
. $ConfigLoader
$LogFile = Join-Path $LogDir ("translate-" + (Get-Date -Format "yyyyMMdd-HHmmss") + "-" + ([Guid]::NewGuid().ToString("N").Substring(0, 8)) + ".log")

New-Item -ItemType Directory -Force -Path $ProcessLogDir | Out-Null

function Write-JobLog {
    param([string]$Message)

    $line = "[" + (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "] " + $Message
    Write-Host $line
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
}

function Write-JobProgress {
    param([string]$Message)

    Write-JobLog "进度 [DeepSeek] $Message"
}

function Format-ElapsedText {
    param([datetime]$StartedAt)

    $elapsed = (Get-Date) - $StartedAt
    return "{0:00}:{1:00}:{2:00}" -f [int]$elapsed.TotalHours, $elapsed.Minutes, $elapsed.Seconds
}

function Quote-Arg {
    param([string]$Text)

    if ($Text -match '[\s"]') {
        return '"' + ($Text -replace '"', '\"') + '"'
    }

    return $Text
}

function Test-ImportantTranslateOutputLine {
    param([string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return $false
    }

    return ($Line -match 'ERROR|WARNING|Traceback|Exception|Insufficient Balance|Successfully translated|Translation completed|Batch statistics|Batches processed|Successful batches|Any subtitles translated|All subtitles translated|TRANSLATION COMPLETE|Output:|Complete:')
}

function Write-TranslateOutputSummary {
    param(
        [object[]]$Lines,
        [int]$MaxImportantLines = 80
    )

    if ($null -eq $Lines -or $Lines.Count -eq 0) {
        return
    }

    $important = @($Lines | Where-Object { Test-ImportantTranslateOutputLine $_ })
    Write-JobLog "DeepSeek 原始输出摘要：$($Lines.Count) 行，关键行 $($important.Count) 行。"

    $important |
        Select-Object -Last $MaxImportantLines |
        ForEach-Object { Write-JobLog "$_" }
}

function Get-ToolCommand {
    param([string]$ToolName)

    $candidates = @(
        (Join-Path $WhisperJavInstallDir "Scripts\$ToolName.exe"),
        (Join-Path $WhisperJavInstallDir ".venv\Scripts\$ToolName.exe"),
        (Join-Path $WhisperJavInstallDir "Library\bin\$ToolName.exe"),
        (Join-Path $WhisperJavInstallDir "$ToolName.exe"),
        "$env:LOCALAPPDATA\WhisperJAV\Scripts\$ToolName.exe"
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return $ToolName
}

function Get-SameNameSubtitlePath {
    param([string]$VideoPath)

    $dir = Split-Path -Parent $VideoPath
    $base = [System.IO.Path]::GetFileNameWithoutExtension($VideoPath)
    return Join-Path $dir "$base.srt"
}

function Copy-FinalSubtitle {
    param(
        [string]$SourcePath,
        [string]$VideoPath
    )

    if (!(Test-Path -LiteralPath $SourcePath)) {
        throw "源中文字幕不存在：$SourcePath"
    }

    $target = Get-SameNameSubtitlePath -VideoPath $VideoPath
    $targetDir = Split-Path -Parent $target

    if (!(Test-Path -LiteralPath $targetDir)) {
        throw "目标视频目录不可访问：$targetDir"
    }

    try {
        Copy-Item -LiteralPath $SourcePath -Destination $target -Force -ErrorAction Stop
    } catch {
        $message = $_.Exception.Message
        if ($_.Exception -is [System.UnauthorizedAccessException]) {
            $message = "$message；目标目录可能没有写入权限，请检查 NAS 共享权限：$targetDir"
        }
        throw $message
    }

    $copied = Get-Item -LiteralPath $target -ErrorAction Stop
    if ($copied.Length -le 0) {
        throw "目标字幕已创建但大小为 0：$target"
    }

    return $target
}

function Find-TranslatedChineseSrt {
    param(
        [string]$JobDir,
        [string]$JapaneseSrt,
        [object]$TranslateStartedAt
    )

    if ($null -eq $TranslateStartedAt -or $TranslateStartedAt -isnot [datetime]) {
        $TranslateStartedAt = (Get-Date).AddDays(-1)
    }

    $all = Get-ChildItem -LiteralPath $JobDir -File -Filter "*.srt" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending

    if ($all.Count -eq 0) {
        return $null
    }

    $preferred = $all |
        Where-Object {
            $_.FullName -ne $JapaneseSrt -and
            $_.Name -match 'zh|cn|chi|chinese|translated|translation|中文'
        } |
        Select-Object -First 1

    if ($null -ne $preferred) {
        return $preferred.FullName
    }

    $newer = $all |
        Where-Object {
            $_.FullName -ne $JapaneseSrt -and
            $_.LastWriteTime -ge $TranslateStartedAt.AddMinutes(-10)
        } |
        Select-Object -First 1

    if ($null -ne $newer) {
        return $newer.FullName
    }

    return $null
}

if ([string]::IsNullOrWhiteSpace($DeepSeekApiKey)) {
    Write-JobLog "DeepSeek API Key 为空。请设置环境变量 DEEPSEEK_API_KEY，或在 config.json 的 deepSeek.apiKey 中填写。"
    exit 1
}

if ([string]::IsNullOrWhiteSpace($DeepSeekModel)) {
    $DeepSeekModel = "deepseek-v4-flash"
}

if ([string]::IsNullOrWhiteSpace($TargetLanguage)) {
    $TargetLanguage = "chinese"
}

if ([string]::IsNullOrWhiteSpace($TranslateTone)) {
    $TranslateTone = "standard"
}

if ($null -eq $MaxBatchSize) {
    $MaxBatchSize = 20
}

$translator = Get-ToolCommand -ToolName "whisperjav-translate"
$translateStartedAt = Get-Date

Write-JobProgress "[1/3] 翻译字幕 | $VideoPath"
Write-JobLog "开始后台 DeepSeek 中文翻译：$VideoPath"
Write-JobLog "输入日语 SRT：$JapaneseSrt"
Write-JobLog "工作目录：$JobDir"
Write-JobLog "DeepSeek Model: $DeepSeekModel"
Write-JobLog "Target Language: $TargetLanguage"
Write-JobLog "Translate Tone: $TranslateTone"

$translateArgs = @(
    "-i", $JapaneseSrt,
    "--provider", "deepseek",
    "--api-key", "$DeepSeekApiKey",
    "--model", $DeepSeekModel,
    "-t", $TargetLanguage,
    "--source", "japanese",
    "--tone", $TranslateTone,
    "--max-batch-size", "$MaxBatchSize"
)

$processLogId = [Guid]::NewGuid().ToString("N")
$stdout = Join-Path $ProcessLogDir "translate-$processLogId-stdout.log"
$stderr = Join-Path $ProcessLogDir "translate-$processLogId-stderr.log"
Remove-Item -LiteralPath $stdout -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $stderr -Force -ErrorAction SilentlyContinue

try {
    $translateProcess = Start-Process `
        -FilePath $translator `
        -ArgumentList (($translateArgs | ForEach-Object { Quote-Arg $_ }) -join " ") `
        -NoNewWindow `
        -PassThru `
        -RedirectStandardOutput $stdout `
        -RedirectStandardError $stderr
} catch {
    Write-JobLog "启动 DeepSeek 翻译失败：$($_.Exception.Message)"
    Write-JobLog "stdout 日志路径：$stdout"
    Write-JobLog "stderr 日志路径：$stderr"
    exit 1
}

$lastHeartbeatAt = Get-Date

while ($true) {
    $liveProcess = Get-Process -Id $translateProcess.Id -ErrorAction SilentlyContinue
    if ($null -eq $liveProcess) {
        Write-JobLog "DeepSeek 翻译子进程 PID=$($translateProcess.Id) 已不存在，停止等待并检查输出文件。"
        break
    }

    try {
        $translateProcess.Refresh()
        if ($translateProcess.HasExited) {
            break
        }
    } catch {
        $liveProcess = Get-Process -Id $translateProcess.Id -ErrorAction SilentlyContinue
        if ($null -eq $liveProcess) {
            Write-JobLog "DeepSeek 翻译子进程 PID=$($translateProcess.Id) 刷新失败且进程不存在，停止等待并检查输出文件。"
            break
        }

        Write-JobLog "DeepSeek 翻译子进程状态刷新失败，继续等待：$($_.Exception.Message)"
    }

    if (((Get-Date) - $lastHeartbeatAt).TotalSeconds -ge 60) {
        $liveLine = "[" + (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "] 进度 [DeepSeek] [1/3] 翻译运行中 | PID=$($translateProcess.Id) | 已用时 $(Format-ElapsedText -StartedAt $translateStartedAt)"
        Add-Content -LiteralPath $LogFile -Value $liveLine -Encoding UTF8
        $lastHeartbeatAt = Get-Date
    }

    Start-Sleep -Seconds 3
}

$output = @()

if (Test-Path -LiteralPath $stdout) {
    $output += Get-Content -LiteralPath $stdout -Encoding UTF8 -ErrorAction SilentlyContinue
}

if (Test-Path -LiteralPath $stderr) {
    $output += Get-Content -LiteralPath $stderr -Encoding UTF8 -ErrorAction SilentlyContinue
}

Write-TranslateOutputSummary -Lines $output

$exitCode = $translateProcess.ExitCode

if (($output -match '402 Insufficient Balance|Insufficient Balance')) {
    Write-JobLog "DeepSeek 翻译失败原因：API 余额不足，请充值或更换可用 API Key 后重试。"
}

$chineseSrt = Find-TranslatedChineseSrt -JobDir $JobDir -JapaneseSrt $JapaneseSrt -TranslateStartedAt $translateStartedAt

if ([string]::IsNullOrWhiteSpace($chineseSrt)) {
    Write-JobLog "没有找到翻译后的中文字幕 SRT，保留临时目录供排查：$JobDir"
    exit 1
}

Write-JobProgress "[1/3] 翻译完成 | $chineseSrt"

if ($null -eq $exitCode) {
    Write-JobLog "DeepSeek 翻译退出码为空，但已检测到生成的中文字幕 SRT，按成功处理：$chineseSrt"
    $exitCode = 0
}

if ($exitCode -ne 0) {
    Write-JobLog "DeepSeek 中文翻译返回非零 ExitCode=$exitCode，但已检测到中文字幕 SRT，继续复制。"
}

$target = Get-SameNameSubtitlePath -VideoPath $VideoPath
Write-JobProgress "[2/3] 写入同名字幕 | $target"

try {
    $target = Copy-FinalSubtitle -SourcePath $chineseSrt -VideoPath $VideoPath
    Write-JobLog "已生成 Jellyfin 同名中文字幕：$target"
    Write-JobProgress "[3/3] 清理临时目录"
    Remove-Item -LiteralPath $JobDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-JobLog "已清理临时目录：$JobDir"
    Write-JobProgress "[完成] 中文字幕已就绪"
    exit 0
} catch {
    Write-JobLog "复制最终中文字幕失败原因：$($_.Exception.Message)"
}

Write-JobLog "复制最终中文字幕失败，保留临时目录：$JobDir"
exit 1


