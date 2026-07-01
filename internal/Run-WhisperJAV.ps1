$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$env:PYTHONIOENCODING = "utf-8"

# ============================================================
# WhisperJAV-Auto：只生成中文字幕版
# 日语视频 -> 临时日语SRT -> DeepSeek中文翻译 -> 视频同名.srt
# ============================================================

$ScriptDir = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { $PSScriptRoot }
$BaseDir = if ([System.IO.Path]::GetFileName($ScriptDir) -ieq "internal") { Split-Path -Parent $ScriptDir } else { $ScriptDir }
$InternalDir = Join-Path $BaseDir "internal"
$ConfigLoader = Join-Path $InternalDir "Load-WhisperJAV-Config.ps1"
if (!(Test-Path -LiteralPath $ConfigLoader)) {
    $ConfigLoader = Join-Path $BaseDir "Load-WhisperJAV-Config.ps1"
}
. $ConfigLoader

$LogDir = Join-Path $BaseDir "logs"

$EnableFlag = Join-Path $BaseDir "enabled.flag"
$GlobalLockFile = Join-Path $BaseDir "whisperjav-auto.lock"
$MainPidFile = Join-Path $BaseDir "main-pid.txt"
$CurrentPidFile = Join-Path $BaseDir "current-pid.txt"
$TranslationPidFile = Join-Path $BaseDir "translation-pids.txt"
$CurrentTaskFile = Join-Path $BaseDir "current-task.json"
$LastTaskFile = Join-Path $BaseDir "last-task.json"
$TranslateWorkerScript = Join-Path $InternalDir "Translate-WhisperJAV-Job.ps1"
if (!(Test-Path -LiteralPath $TranslateWorkerScript)) {
    $TranslateWorkerScript = Join-Path $BaseDir "Translate-WhisperJAV-Job.ps1"
}
$FailedVideoFile = Join-Path $BaseDir "failed-videos.txt"

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null
New-Item -ItemType Directory -Force -Path $ManualOutputDir | Out-Null

$LogFile = Join-Path $LogDir ("run-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".log")

if ([string]::IsNullOrWhiteSpace($DeepSeekApiKey)) {
    Write-Host "DeepSeek API Key 为空。请设置环境变量 DEEPSEEK_API_KEY，或在 config.json 的 deepSeek.apiKey 中填写。"
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

if ($null -eq $LogRetentionDays) {
    $LogRetentionDays = 30
}

$Roots = @($VideoRoots)

# ============================================================
# WhisperJAV 转录参数：Ensemble 双 Pass 质量优先版
# 对应 GUI：
# Pass1: Fidelity / Balanced / Auditok / None / TEN VAD / Large V2
# Pass2: Balanced / Aggressive / Silero / None / Silero v6.2 / Large V2
# Merge: Pass1 + Fill From Pass2
# Finish each file: ON
# ============================================================

if ([string]::IsNullOrWhiteSpace($SourceLanguage)) { $SourceLanguage = "japanese" }
if ([string]::IsNullOrWhiteSpace($SubsLanguage)) { $SubsLanguage = "native" }
if ([string]::IsNullOrWhiteSpace($OutputFormat)) { $OutputFormat = "srt" }

if ([string]::IsNullOrWhiteSpace($Pass1Pipeline)) { $Pass1Pipeline = "fidelity" }
if ([string]::IsNullOrWhiteSpace($Pass1Sensitivity)) { $Pass1Sensitivity = "balanced" }
if ([string]::IsNullOrWhiteSpace($Pass1SceneDetector)) { $Pass1SceneDetector = "auditok" }
if ([string]::IsNullOrWhiteSpace($Pass1SpeechEnhancer)) { $Pass1SpeechEnhancer = "none" }
if ([string]::IsNullOrWhiteSpace($Pass1SpeechSegmenter)) { $Pass1SpeechSegmenter = "ten" }
if ([string]::IsNullOrWhiteSpace($Pass1Model)) { $Pass1Model = "large-v2" }

if ([string]::IsNullOrWhiteSpace($Pass2Pipeline)) { $Pass2Pipeline = "balanced" }
if ([string]::IsNullOrWhiteSpace($Pass2Sensitivity)) { $Pass2Sensitivity = "aggressive" }
if ([string]::IsNullOrWhiteSpace($Pass2SceneDetector)) { $Pass2SceneDetector = "silero" }
if ([string]::IsNullOrWhiteSpace($Pass2SpeechEnhancer)) { $Pass2SpeechEnhancer = "none" }
if ([string]::IsNullOrWhiteSpace($Pass2SpeechSegmenter)) { $Pass2SpeechSegmenter = "silero-v6.2" }
if ([string]::IsNullOrWhiteSpace($Pass2Model)) { $Pass2Model = "large-v2" }

if ([string]::IsNullOrWhiteSpace($MergeStrategy)) { $MergeStrategy = "pass1_primary" }

# 每次启动最多处理几个视频。0 表示不限制，持续处理到当前队列清空。
# 转录仍然串行，翻译可和下一部转录并发；关闭任务窗口即可中断。
if ($null -eq $MaxFilesPerRun) { $MaxFilesPerRun = 0 }

# 后台 DeepSeek 翻译并发数。先保持 1，避免 API 速率/费用波动。
if ($null -eq $MaxConcurrentTranslations) { $MaxConcurrentTranslations = 1 }

# 避免处理正在下载/复制中的视频
if ($null -eq $MinAgeMinutes) { $MinAgeMinutes = 30 }

$VideoExts = @(
    ".mp4",
    ".mkv",
    ".avi",
    ".mov",
    ".m4v",
    ".wmv",
    ".flv",
    ".ts"
)

$SubtitleExts = @(
    ".srt",
    ".ass",
    ".ssa",
    ".vtt",
    ".sub",
    ".idx",
    ".sup"
)

function Write-Log {
    param([string]$Message)

    Clear-LiveProgress

    $line = "[" + (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "] " + $Message

    $color = "Gray"
    if ($Message -match '失败|异常|缺少|为空|error|Traceback|aborting') {
        $color = "Red"
    } elseif ($Message -match '警告|跳过|关闭|停止|lock|WARNING') {
        $color = "Yellow"
    } elseif ($Message -match '已生成|处理完成|已清理|步骤结束|Finished') {
        $color = "Green"
    } elseif ($Message -match '开始步骤|开始处理|扫描目录|扫描到|本轮待处理|^进度') {
        $color = "Cyan"
    } elseif ($Message -match 'PID|命令|DeepSeek Model|Target Language|Translate Tone|Max Batch Size|Path check') {
        $color = "DarkCyan"
    } elseif ($Message -match '^=====') {
        $color = "White"
    }

    Write-Host $line -ForegroundColor $color
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
}

$script:LiveProgressActive = $false
$script:LiveProgressTop = $null
$script:LastLiveProgressCore = ""

function Clear-LiveProgress {
    if (-not $script:LiveProgressActive) {
        return
    }

    try {
        $width = [Math]::Max(40, [Console]::WindowWidth - 1)
        if ($null -ne $script:LiveProgressTop) {
            [Console]::SetCursorPosition(0, $script:LiveProgressTop)
        }
        [Console]::Write((" " * $width))
        if ($null -ne $script:LiveProgressTop) {
            [Console]::SetCursorPosition(0, $script:LiveProgressTop)
        }
    } catch {
        Write-Host ""
    }

    $script:LiveProgressActive = $false
    $script:LiveProgressTop = $null
}

function Write-LiveProgress {
    param([string]$Message)

    $script:LastLiveProgressCore = $Message
    $line = "[" + (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "] " + $Message

    try {
        $width = [Math]::Max(40, [Console]::WindowWidth - 1)

        if ($line.Length -gt $width) {
            $line = $line.Substring(0, [Math]::Max(0, $width - 3)) + "..."
        }

        if (-not $script:LiveProgressActive -or $null -eq $script:LiveProgressTop) {
            $script:LiveProgressTop = [Console]::CursorTop
        }

        [Console]::SetCursorPosition(0, $script:LiveProgressTop)
        [Console]::Write($line.PadRight($width))
        [Console]::SetCursorPosition(0, $script:LiveProgressTop)
        $script:LiveProgressActive = $true
    } catch {
        if ($Message -ne $script:LastLiveProgressCore) {
            Write-Host $line
        }
    }
}

function Format-ShortText {
    param(
        [string]$Text,
        [int]$MaxLength = 54
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }

    if ($Text.Length -le $MaxLength) {
        return $Text
    }

    return ($Text.Substring(0, [Math]::Max(0, $MaxLength - 3)) + "...")
}

function New-ProgressBar {
    param(
        [int]$Current,
        [int]$Total,
        [int]$Width = 22
    )

    if ($Total -le 0) {
        $Total = 1
    }

    if ($Current -lt 0) {
        $Current = 0
    }

    if ($Current -gt $Total) {
        $Current = $Total
    }

    $filled = [int][Math]::Floor(($Current / [double]$Total) * $Width)
    $empty = $Width - $filled
    $percent = [int][Math]::Floor(($Current / [double]$Total) * 100)

    return "[{0}{1}] {2,3}%" -f ("#" * $filled), ("-" * $empty), $percent
}

function Format-ElapsedText {
    param([datetime]$StartedAt)

    $elapsed = (Get-Date) - $StartedAt
    return "{0:00}:{1:00}:{2:00}" -f [int]$elapsed.TotalHours, $elapsed.Minutes, $elapsed.Seconds
}

function Get-LastProcessProgressLine {
    param([string]$OutputFile)

    if (!(Test-Path -LiteralPath $OutputFile)) {
        return ""
    }

    $lines = Get-Content -LiteralPath $OutputFile -Tail 60 -ErrorAction SilentlyContinue
    $line = $lines |
        Where-Object {
            $_ -match 'Transcribing:|Pass 1|Pass 2|Step [0-9]|Combining|Post-processing|Merge complete|Completed:'
        } |
        Select-Object -Last 1

    if ([string]::IsNullOrWhiteSpace($line)) {
        return ""
    }

    $clean = $line -replace '\s+', ' '

    if ($clean -match 'Transcribing:\s*\[[^\]]+\]\s*(\d+)/(\d+)\s*\[(\d+(?:\.\d+)?)%\]') {
        return ("真实进度 {0}% | {1}/{2}" -f $Matches[3], $Matches[1], $Matches[2])
    }

    if ($clean -match 'Step 1:\s*Transforming audio') {
        return "阶段进度 1/6 约 8% | 正在提取/转换音频"
    }

    if ($clean -match 'Step 2:\s*Detecting audio scenes|scene detection') {
        return "阶段进度 2/6 约 18% | 正在检测音频场景"
    }

    if ($clean -match 'Step 3:\s*Preparing audio') {
        return "阶段进度 3/6 约 30% | 正在准备 ASR 音频"
    }

    if ($clean -match 'Step 4:\s*Transcribing') {
        return "阶段进度 4/6 约 40% | 正在准备逐段转录"
    }

    if ($clean -match 'Step 5:\s*Combining|Combining scene transcriptions') {
        return "阶段进度 5/6 约 92% | 正在合并场景转录"
    }

    if ($clean -match 'Step 6:\s*Post-processing|Post-processing subtitles') {
        return "阶段进度 6/6 约 96% | 正在后处理字幕"
    }

    if ($clean -match 'Merge complete') {
        return "阶段进度 约 99% | 字幕合并完成"
    }

    if ($clean -match 'Completed:') {
        return "阶段进度 100% | 日语 SRT 已生成"
    }

    return Format-ShortText -Text $clean -MaxLength 92
}

function Test-ImportantProcessOutputLine {
    param([string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return $false
    }

    return ($Line -match 'ERROR|WARNING|Traceback|Exception|Insufficient Balance|No valid media|Completed:|ENSEMBLE PROCESSING SUMMARY|Total files:|Completed:|Failed:|Merge complete|TRANSLATION COMPLETE|Successfully translated|Output:|Complete:')
}

function Write-ProcessOutputSummary {
    param(
        [string]$Name,
        [object[]]$Lines,
        [int]$MaxImportantLines = 80
    )

    if ($null -eq $Lines -or $Lines.Count -eq 0) {
        return
    }

    $important = @($Lines | Where-Object { Test-ImportantProcessOutputLine $_ })

    if ($important.Count -eq 0) {
        Write-Log "$Name 输出摘要：$($Lines.Count) 行，无错误/警告/完成摘要。完整输出见 current-$($Name.ToLower()).log。"
        return
    }

    Write-Log "$Name 输出摘要：$($Lines.Count) 行，关键行 $($important.Count) 行。"

    $important |
        Select-Object -Last $MaxImportantLines |
        ForEach-Object { Write-Log $_ }
}

function Remove-OldLogs {
    if ($LogRetentionDays -le 0) {
        return
    }

    $cutoff = (Get-Date).AddDays(-[int]$LogRetentionDays)

    Get-ChildItem -LiteralPath $LogDir -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.LastWriteTime -lt $cutoff -and
            $_.Name -match '^(run|translate)-.*\.log$'
        } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Sync-TranslationPidFile {
    if (!(Test-Path -LiteralPath $TranslationPidFile)) {
        return
    }

    $activePids = @(Get-Content -LiteralPath $TranslationPidFile -ErrorAction SilentlyContinue |
        Where-Object { $_ -match '^\d+$' } |
        ForEach-Object { [int]$_ } |
        Sort-Object -Unique |
        Where-Object { $null -ne (Get-Process -Id $_ -ErrorAction SilentlyContinue) })

    if ($activePids.Count -gt 0) {
        Set-Content -LiteralPath $TranslationPidFile -Value $activePids -Encoding ASCII
    } else {
        Remove-Item -LiteralPath $TranslationPidFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-FailedVideoPaths {
    if (!(Test-Path -LiteralPath $FailedVideoFile)) {
        return @()
    }

    return @(Get-Content -LiteralPath $FailedVideoFile -Encoding UTF8 -ErrorAction SilentlyContinue |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object {
            $parts = $_ -split "`t", 3
            if ($parts.Count -ge 2) {
                $parts[1]
            }
        } |
        Sort-Object -Unique)
}

function Convert-ComparableVideoPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    $normalized = $Path.Trim() -replace '/', '\'
    $drivePattern = "^" + [regex]::Escape($NasDrivePrefix)
    $normalized = $normalized -replace $drivePattern, $NasUncPrefix
    return $normalized.ToLowerInvariant()
}

function Test-IsFailedVideo {
    param([System.IO.FileInfo]$Video)

    $videoPath = Convert-ComparableVideoPath -Path $Video.FullName
    $failedPaths = @(Get-FailedVideoPaths | ForEach-Object { Convert-ComparableVideoPath -Path $_ })
    return ($failedPaths -contains $videoPath)
}

function Add-FailedVideo {
    param(
        [string]$VideoPath,
        [string]$Reason
    )

    if ([string]::IsNullOrWhiteSpace($VideoPath)) {
        return
    }

    $videoPathKey = Convert-ComparableVideoPath -Path $VideoPath
    $existing = @(Get-FailedVideoPaths | ForEach-Object { Convert-ComparableVideoPath -Path $_ })
    if ($existing -contains $videoPathKey) {
        return
    }

    $line = "{0}`t{1}`t{2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $VideoPath, ($Reason -replace "`r|`n|`t", " ")
    Add-Content -LiteralPath $FailedVideoFile -Value $line -Encoding UTF8
    Write-Log "已加入失败跳过清单：$VideoPath；原因：$Reason"
}

function Test-UnrecoverableMediaError {
    param([object[]]$Lines)

    if ($null -eq $Lines -or $Lines.Count -eq 0) {
        return $false
    }

    return (($Lines -join "`n") -match 'Failed to extract audio|moov atom not found|Invalid data found when processing input|No valid media files found|Invalid argument')
}

function Write-SubTaskProgress {
    param(
        [int]$QueueIndex,
        [int]$QueueTotal,
        [int]$SubTaskIndex,
        [int]$SubTaskTotal,
        [string]$SubTaskName,
        [string]$VideoPath
    )

    $videoName = ""

    if (-not [string]::IsNullOrWhiteSpace($VideoPath)) {
        $videoName = [System.IO.Path]::GetFileName($VideoPath)
    }

    $totalUnits = [Math]::Max(1, $QueueTotal * $SubTaskTotal)
    $currentUnit = (($QueueIndex - 1) * $SubTaskTotal) + $SubTaskIndex
    $bar = New-ProgressBar -Current $currentUnit -Total $totalUnits
    $shortName = Format-ShortText -Text $videoName

    if ([string]::IsNullOrWhiteSpace($videoName)) {
        Write-Log ("进度 {0} | 任务 {1}/{2} | 子任务 {3}/{4} | {5}" -f $bar, $QueueIndex, $QueueTotal, $SubTaskIndex, $SubTaskTotal, $SubTaskName)
    }
    else {
        Write-Log ("进度 {0} | 任务 {1}/{2} | 子任务 {3}/{4} | {5} | {6}" -f $bar, $QueueIndex, $QueueTotal, $SubTaskIndex, $SubTaskTotal, $SubTaskName, $shortName)
    }
}

function Set-TaskState {
    param(
        [string]$Status,
        [string]$StepName,
        [string]$VideoPath,
        [string]$JobDir,
        [object]$ProcessId,
        [string]$CommandLine
    )

    $state = [ordered]@{
        updatedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        status = $Status
        step = $StepName
        mainPid = $PID
        processId = $ProcessId
        videoPath = $VideoPath
        jobDir = $JobDir
        commandLine = $CommandLine
        logFile = $LogFile
    }

    $state |
        ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath $CurrentTaskFile -Encoding UTF8

    $state |
        ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath $LastTaskFile -Encoding UTF8
}

function Get-SafeName {
    param([string]$Text)

    $safe = $Text -replace '[\\/:*?"<>|]', '_'
    if ($safe.Length -gt 80) {
        $safe = $safe.Substring(0, 80)
    }
    return $safe
}

function Copy-VideoToLocalWorkDir {
    param(
        [System.IO.FileInfo]$Video,
        [string]$JobDir
    )

    $target = Join-Path $JobDir $Video.Name

    if (Test-Path -LiteralPath $target) {
        $existing = Get-Item -LiteralPath $target -ErrorAction SilentlyContinue
        if ($null -ne $existing -and $existing.Length -eq $Video.Length) {
            Write-Log "复用本地视频副本：$target"
            return $target
        }

        Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
    }

    $root = [System.IO.Path]::GetPathRoot($JobDir)
    $driveName = $root.TrimEnd("\").TrimEnd(":")
    $drive = Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue
    $requiredFree = $Video.Length + 5GB

    if ($null -ne $drive -and $drive.Free -lt $requiredFree) {
        throw "D 盘剩余空间不足，无法复制本地转录副本。需要约 $([math]::Round($requiredFree / 1GB, 1)) GB，可用 $([math]::Round($drive.Free / 1GB, 1)) GB。"
    }

    Write-Log "复制视频到本地临时文件，避免 NAS/SMB 读取错误：$target"
    Copy-Item -LiteralPath $Video.FullName -Destination $target -Force -ErrorAction Stop

    $copied = Get-Item -LiteralPath $target -ErrorAction Stop
    if ($copied.Length -ne $Video.Length) {
        throw "本地视频副本大小不一致：源 $($Video.Length) bytes，副本 $($copied.Length) bytes。"
    }

    return $target
}

function Get-SameNameSubtitlePath {
    param([System.IO.FileInfo]$Video)

    $dir = $Video.DirectoryName
    $base = [System.IO.Path]::GetFileNameWithoutExtension($Video.Name)
    return Join-Path $dir "$base.srt"
}

function Test-HasFinalChineseSubtitle {
    param([System.IO.FileInfo]$Video)

    $target = Get-SameNameSubtitlePath -Video $Video
    return Test-Path -LiteralPath $target
}

function Test-SubtitleOutputWritable {
    param([System.IO.FileInfo]$Video)

    if ($null -eq $script:SubtitleOutputWritableCache) {
        $script:SubtitleOutputWritableCache = @{}
    }

    $dir = $Video.DirectoryName
    $cacheKey = $dir.ToLowerInvariant()

    if ($script:SubtitleOutputWritableCache.ContainsKey($cacheKey)) {
        return $script:SubtitleOutputWritableCache[$cacheKey]
    }

    if (!(Test-Path -LiteralPath $dir)) {
        Write-Log "目标字幕目录不可访问，跳过：$dir"
        $script:SubtitleOutputWritableCache[$cacheKey] = $false
        return $false
    }

    $probe = Join-Path $dir (".whisperjav-write-test-" + ([Guid]::NewGuid().ToString("N")) + ".tmp")

    try {
        [System.IO.File]::WriteAllText($probe, "test", [System.Text.UTF8Encoding]::new($false))
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        $script:SubtitleOutputWritableCache[$cacheKey] = $true
        return $true
    } catch {
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        Write-Log "目标字幕目录不可写，跳过：$dir；$($_.Exception.Message)"
        $script:SubtitleOutputWritableCache[$cacheKey] = $false
        return $false
    }
}

function Test-HasExternalSubtitle {
    param([System.IO.FileInfo]$Video)

    $dir = $Video.DirectoryName
    $base = [System.IO.Path]::GetFileNameWithoutExtension($Video.Name)
    $escapedBase = [regex]::Escape($base)
    $escapedExts = ($SubtitleExts | ForEach-Object { [regex]::Escape($_.TrimStart(".")) }) -join "|"
    $pattern = "^$escapedBase(\..+)?\.($escapedExts)$"

    $subtitle = Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match $pattern
        } |
        Select-Object -First 1

    return ($null -ne $subtitle)
}

function Test-HasEmbeddedSubtitle {
    param([System.IO.FileInfo]$Video)

    if ($Video.Extension.ToLower() -ne ".mkv") {
        return $false
    }

    $ffprobe = Get-ToolCommand -ToolName "ffprobe"

    try {
        $output = & $ffprobe `
            -v error `
            -select_streams s `
            -show_entries stream=index `
            -of csv=p=0 `
            $Video.FullName 2>$null

        return (-not [string]::IsNullOrWhiteSpace(($output -join "")))
    } catch {
        Write-Log "检查内嵌字幕失败，按无内嵌字幕处理：$($Video.FullName)；$($_.Exception.Message)"
        return $false
    }
}

function Test-SkipByFileName {
    param([System.IO.FileInfo]$Video)

    $base = [System.IO.Path]::GetFileNameWithoutExtension($Video.Name)

    # 跳过已带中文字幕标记的文件：
    # ABF-159-C.mp4 / ABF-159-c.mp4
    # CAWD-590-C_GG5.mp4 / HMN-372-C_GG5.mp4
    # NSFS-400ch.mp4 / NSFS-400CH.mp4
    # PowerShell 的 -match 默认不区分大小写。
    return ($base -match '(-c($|[\s._\-\[\]\(\)])|[0-9]ch$)')
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

function Quote-Arg {
    param([string]$Text)

    if ($Text -match '[\s"]') {
        return '"' + ($Text -replace '"', '\"') + '"'
    }

    return $Text
}

function Invoke-ProcessWithSwitch {
    param(
        [string]$FileName,
        [string[]]$ArgsList,
        [string]$StepName,
        [string]$VideoPath,
        [string]$JobDir
    )

    $stdout = Join-Path $BaseDir "current-stdout.log"
    $stderr = Join-Path $BaseDir "current-stderr.log"

    Remove-Item -LiteralPath $stdout -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stderr -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $CurrentPidFile -Force -ErrorAction SilentlyContinue
    $script:LastProcessHadUnrecoverableMediaError = $false

    $argsString = ($ArgsList | ForEach-Object { Quote-Arg $_ }) -join " "
    $safeArgsString = $argsString -replace '(--api-key\s+)(?:"[^"]+"|\S+)', '$1"***"'

    Write-Log "开始步骤：$StepName"
    Write-Log "命令：$FileName $safeArgsString"
    Set-TaskState -Status "starting" -StepName $StepName -VideoPath $VideoPath -JobDir $JobDir -ProcessId $null -CommandLine "$FileName $safeArgsString"

    $process = Start-Process `
        -FilePath $FileName `
        -ArgumentList $argsString `
        -NoNewWindow `
        -PassThru `
        -RedirectStandardOutput $stdout `
        -RedirectStandardError $stderr

    Set-Content -LiteralPath $CurrentPidFile -Value $process.Id -Encoding ASCII
    Set-TaskState -Status "running" -StepName $StepName -VideoPath $VideoPath -JobDir $JobDir -ProcessId $process.Id -CommandLine "$FileName $safeArgsString"
    Write-Log "$StepName PID: $($process.Id)"

    $processStartedAt = Get-Date
    $lastTaskHeartbeatAt = Get-Date

    while ($true) {
        if (!(Test-Path -LiteralPath $EnableFlag)) {
            Write-Log "检测到手动关闭开关，正在停止当前进程..."
            Set-TaskState -Status "stopping" -StepName $StepName -VideoPath $VideoPath -JobDir $JobDir -ProcessId $process.Id -CommandLine "$FileName $safeArgsString"
            try {
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            } catch {}

            Remove-Item -LiteralPath $CurrentPidFile -Force -ErrorAction SilentlyContinue
            Set-TaskState -Status "interrupted" -StepName $StepName -VideoPath $VideoPath -JobDir $JobDir -ProcessId $process.Id -CommandLine "$FileName $safeArgsString"
            return 999
        }

        $liveProcess = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
        if ($null -eq $liveProcess) {
            Write-Log "$StepName 子进程 PID=$($process.Id) 已不存在，停止等待并检查输出文件。"
            break
        }

        $hasExited = $false
        try {
            $process.Refresh()
            $hasExited = $process.HasExited
        } catch {
            $liveProcess = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
            if ($null -eq $liveProcess) {
                Write-Log "$StepName 子进程 PID=$($process.Id) 刷新失败且进程不存在，停止等待并检查输出文件。"
                break
            }

            Write-Log "$StepName 子进程状态刷新失败，继续等待：$($_.Exception.Message)"
        }

        if ($hasExited) {
            break
        }

        $elapsedText = Format-ElapsedText -StartedAt $processStartedAt
        $progressLine = Get-LastProcessProgressLine -OutputFile $stdout

        if ([string]::IsNullOrWhiteSpace($progressLine)) {
            Write-LiveProgress "进度 [$StepName] 运行中 | PID=$($process.Id) | 已用时 $elapsedText"
        }
        else {
            Write-LiveProgress "进度 [$StepName] 运行中 | 已用时 $elapsedText | $progressLine"
        }

        if (((Get-Date) - $lastTaskHeartbeatAt).TotalSeconds -ge 30) {
            $heartbeatStepName = $StepName
            if (-not [string]::IsNullOrWhiteSpace($progressLine)) {
                $heartbeatStepName = "$StepName - $progressLine"
            }

            Set-TaskState -Status "running" -StepName $heartbeatStepName -VideoPath $VideoPath -JobDir $JobDir -ProcessId $process.Id -CommandLine "$FileName $safeArgsString"
            Sync-TranslationPidFile
            $lastTaskHeartbeatAt = Get-Date
        }

        Start-Sleep -Seconds 3
    }

    if (Test-Path -LiteralPath $stdout) {
        $stdoutLines = Get-Content -LiteralPath $stdout -Encoding UTF8 -ErrorAction SilentlyContinue
        Write-ProcessOutputSummary -Name "stdout" -Lines $stdoutLines
    } else {
        $stdoutLines = @()
    }

    if (Test-Path -LiteralPath $stderr) {
        $stderrLines = Get-Content -LiteralPath $stderr -Encoding UTF8 -ErrorAction SilentlyContinue
        Write-ProcessOutputSummary -Name "stderr" -Lines $stderrLines
    } else {
        $stderrLines = @()
    }

    $script:LastProcessHadUnrecoverableMediaError = Test-UnrecoverableMediaError -Lines ($stdoutLines + $stderrLines)

    Remove-Item -LiteralPath $CurrentPidFile -Force -ErrorAction SilentlyContinue

    $exitCode = $process.ExitCode

    if ($null -eq $exitCode -and $StepName -eq "日语转录") {
        $generatedSrt = Get-ChildItem -LiteralPath $JobDir -File -Filter "*.srt" -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Length -gt 0 -and
                $_.LastWriteTime -ge (Get-Date).AddHours(-24)
            } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1

        if ($null -ne $generatedSrt) {
            Write-Log "日语转录退出码为空，但已检测到生成的 SRT，按成功处理：$($generatedSrt.FullName)"
            $exitCode = 0
        }
    }

    if ($StepName -eq "DeepSeek 中文翻译" -and (($stdoutLines + $stderrLines) -match '402 Insufficient Balance|Insufficient Balance')) {
        Write-Log "DeepSeek 翻译失败原因：API 余额不足，请充值或更换可用 API Key 后重试。"
    }

    if ($null -eq $exitCode -and $StepName -eq "DeepSeek 中文翻译") {
        $generatedChineseSrt = Get-ChildItem -LiteralPath $JobDir -File -Filter "*.srt" -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Length -gt 0 -and
                $_.Name -match 'zh|cn|chi|chinese|translated|translation|中文'
            } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1

        if ($null -ne $generatedChineseSrt) {
            Write-Log "DeepSeek 翻译退出码为空，但已检测到生成的中文字幕 SRT，按成功处理：$($generatedChineseSrt.FullName)"
            $exitCode = 0
        }
    }

    Write-Log "步骤结束：$StepName，ExitCode=$exitCode"
    Set-TaskState -Status "step_finished" -StepName $StepName -VideoPath $VideoPath -JobDir $JobDir -ProcessId $process.Id -CommandLine "$FileName $safeArgsString"
    return $exitCode
}

function Find-GeneratedJapaneseSrt {
    param(
        [string]$JobDir,
        [datetime]$StartedAt
    )

    $candidates = Get-ChildItem -LiteralPath $JobDir -File -Filter "*.srt" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.LastWriteTime -ge $StartedAt.AddMinutes(-10)
        } |
        Sort-Object LastWriteTime -Descending

    if ($candidates.Count -eq 0) {
        return $null
    }

    return $candidates[0].FullName
}

function Find-ReusableJapaneseSrt {
    param([string]$SafeBase)

    $candidates = Get-ChildItem -LiteralPath $WorkRoot -Directory -Filter "$SafeBase-*" -ErrorAction SilentlyContinue |
        ForEach-Object {
            Get-ChildItem -LiteralPath $_.FullName -File -Filter "*.srt" -ErrorAction SilentlyContinue
        } |
        Where-Object {
            $_.Length -gt 0 -and
            $_.Name -match '(\.ja\.merged\.whisperjav|\.ja\.pass1|\.ja\.whisperjav|\.ja\.)' -and
            $_.Name -notmatch 'zh|cn|chi|chinese|translated|translation|中文'
        } |
        Sort-Object LastWriteTime -Descending

    if ($candidates.Count -eq 0) {
        return $null
    }

    return $candidates[0].FullName
}

function Find-ReusableChineseSrt {
    param([string]$SafeBase)

    $candidates = Get-ChildItem -LiteralPath $WorkRoot -Directory -Filter "$SafeBase-*" -ErrorAction SilentlyContinue |
        ForEach-Object {
            Get-ChildItem -LiteralPath $_.FullName -File -Filter "*.srt" -ErrorAction SilentlyContinue
        } |
        Where-Object {
            $_.Length -gt 0 -and
            $_.Name -match 'zh|cn|chi|chinese|translated|translation|中文'
        } |
        Sort-Object LastWriteTime -Descending

    if ($candidates.Count -eq 0) {
        return $null
    }

    return $candidates[0].FullName
}

function Find-TranslatedChineseSrt {
    param(
        [string]$JobDir,
        [string]$JapaneseSrt,
        [datetime]$TranslateStartedAt
    )

    $all = Get-ChildItem -LiteralPath $JobDir -File -Filter "*.srt" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending

    if ($all.Count -eq 0) {
        return $null
    }

    # 优先找明显是中文/翻译结果的文件名
    $preferred = $all |
        Where-Object {
            $_.FullName -ne $JapaneseSrt -and
            (
                $_.Name -match 'zh|cn|chi|chinese|translated|translation|中文'
            )
        } |
        Select-Object -First 1

    if ($null -ne $preferred) {
        return $preferred.FullName
    }

    # 再找翻译开始后生成/修改的非原始日语SRT
    $newer = $all |
        Where-Object {
            $_.FullName -ne $JapaneseSrt -and
            $_.LastWriteTime -ge $TranslateStartedAt.AddMinutes(-10)
        } |
        Select-Object -First 1

    if ($null -ne $newer) {
        return $newer.FullName
    }

    # 有些版本可能直接改写输入文件；最后才接受原文件
    $input = Get-Item -LiteralPath $JapaneseSrt -ErrorAction SilentlyContinue
    if ($null -ne $input -and $input.LastWriteTime -ge $TranslateStartedAt.AddMinutes(-10)) {
        return $input.FullName
    }

    return $null
}

function Copy-FinalChineseSubtitle {
    param(
        [string]$ChineseSrt,
        [System.IO.FileInfo]$Video
    )

    $target = Get-SameNameSubtitlePath -Video $Video

    try {
        Copy-Item -LiteralPath $ChineseSrt -Destination $target -Force -ErrorAction Stop
    } catch {
        Write-Log "复制最终中文字幕失败原因：$($_.Exception.Message)"
        $safeName = Get-SafeName -Text ([System.IO.Path]::GetFileNameWithoutExtension($Video.Name))
        $fallback = Join-Path $ManualOutputDir "$safeName.srt"

        try {
            Copy-Item -LiteralPath $ChineseSrt -Destination $fallback -Force -ErrorAction Stop
            Write-Log "目标目录不可写，已保留中文字幕到本地人工输出目录：$fallback"
        } catch {
            Write-Log "保留中文字幕到本地人工输出目录也失败：$($_.Exception.Message)"
        }

        return $false
    }

    if (Test-Path -LiteralPath $target) {
        Write-Log "已生成 Jellyfin 同名中文字幕：$target"
        return $true
    }

    return $false
}

function Update-TranslationProcesses {
    param([System.Collections.ArrayList]$Processes)

    for ($i = $Processes.Count - 1; $i -ge 0; $i--) {
        $item = $Processes[$i]
        $process = $item.Process
        $process.Refresh()

        if ($process.HasExited) {
            $exitCode = $process.ExitCode
            $target = Get-SameNameSubtitlePath -Video ([System.IO.FileInfo]::new($item.VideoPath))

            if ($null -eq $exitCode -and (Test-Path -LiteralPath $target)) {
                $exitCode = 0
            }

            if ($exitCode -eq 0) {
                Write-Log "后台翻译成功：PID=$($process.Id)，Video=$($item.VideoPath)"
                Write-Log "进度 [DeepSeek] 翻译完成 | $(Format-ShortText -Text ([System.IO.Path]::GetFileName($item.VideoPath)))"
            } else {
                Write-Log "后台翻译结束：PID=$($process.Id)，ExitCode=$exitCode，Video=$($item.VideoPath)"
            }

            [void]$Processes.RemoveAt($i)
        }
    }

    $activePids = @($Processes | ForEach-Object { $_.Process.Id })

    if ($activePids.Count -gt 0) {
        Set-Content -LiteralPath $TranslationPidFile -Value $activePids -Encoding ASCII
    } else {
        Remove-Item -LiteralPath $TranslationPidFile -Force -ErrorAction SilentlyContinue
    }
}

function Wait-ForTranslationSlot {
    param([System.Collections.ArrayList]$Processes)

    while ($Processes.Count -ge $MaxConcurrentTranslations) {
        if (!(Test-Path -LiteralPath $EnableFlag)) {
            Write-Log "开关已关闭，停止等待后台翻译。"
            break
        }

        Update-TranslationProcesses -Processes $Processes

        if ($Processes.Count -ge $MaxConcurrentTranslations) {
            Write-LiveProgress "进度 [DeepSeek] 后台翻译并发已满，等待空位..."
            Start-Sleep -Seconds 3
        }
    }
}

function Start-BackgroundTranslation {
    param(
        [System.Collections.ArrayList]$Processes,
        [string]$JapaneseSrt,
        [string]$VideoPath,
        [string]$JobDir
    )

    Wait-ForTranslationSlot -Processes $Processes

    $args = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$TranslateWorkerScript`"",
        "-BaseDir", "`"$BaseDir`"",
        "-JapaneseSrt", "`"$JapaneseSrt`"",
        "-VideoPath", "`"$VideoPath`"",
        "-JobDir", "`"$JobDir`""
    )

    $process = Start-Process `
        -FilePath $SystemPowerShell `
        -ArgumentList ($args -join " ") `
        -NoNewWindow `
        -PassThru

    Add-Content -LiteralPath $TranslationPidFile -Value $process.Id -Encoding ASCII

    [void]$Processes.Add([pscustomobject]@{
        Process = $process
        VideoPath = $VideoPath
        JapaneseSrt = $JapaneseSrt
        JobDir = $JobDir
    })

    Write-Log "已启动后台 DeepSeek 翻译：PID=$($process.Id)，Video=$VideoPath"
}

function Wait-AllTranslations {
    param([System.Collections.ArrayList]$Processes)

    while ($Processes.Count -gt 0) {
        Update-TranslationProcesses -Processes $Processes

        if ($Processes.Count -gt 0) {
            Write-LiveProgress "进度 [DeepSeek] 等待后台翻译完成 | 剩余数量：$($Processes.Count)"
            Start-Sleep -Seconds 3
        }
    }
}

# ============================================================
# 开关检查
# ============================================================

if (!(Test-Path -LiteralPath $EnableFlag)) {
    Write-Log "开关为 OFF，退出。"
    exit 0
}

# ============================================================
# 防重复运行
# ============================================================

if (Test-Path -LiteralPath $GlobalLockFile) {
    $lockAge = (Get-Date) - (Get-Item -LiteralPath $GlobalLockFile).LastWriteTime
    $mainProcessAlive = $false

    if (Test-Path -LiteralPath $MainPidFile) {
        $mainPidText = Get-Content -LiteralPath $MainPidFile -ErrorAction SilentlyContinue | Select-Object -First 1

        if ($mainPidText) {
            try {
                $mainProcessAlive = $null -ne (Get-Process -Id ([int]$mainPidText) -ErrorAction SilentlyContinue)
            } catch {
                $mainProcessAlive = $false
            }
        }
    }

    if ($lockAge.TotalHours -lt 18 -and $mainProcessAlive) {
        Write-Log "已有任务正在运行，退出。本次不重复启动。"
        exit 0
    } else {
        if ($mainProcessAlive) {
            Write-Log "发现超过 18 小时的旧 lock，自动清理。"
        } else {
            Write-Log "发现残留 lock，但主进程不存在，自动清理。"
        }

        Remove-Item -LiteralPath $GlobalLockFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $MainPidFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $CurrentPidFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $CurrentTaskFile -Force -ErrorAction SilentlyContinue
    }
}

New-Item -ItemType File -Force -Path $GlobalLockFile | Out-Null
Set-Content -LiteralPath $MainPidFile -Value $PID -Encoding ASCII
Set-TaskState -Status "running" -StepName "扫描队列" -VideoPath "" -JobDir "" -ProcessId $null -CommandLine "Run-WhisperJAV.ps1"

try {
    Write-Log "===== WhisperJAV 中文字幕自动处理开始 ====="
    Remove-OldLogs
    Write-Log "提示：关闭此任务窗口会中断当前转录/翻译进程。"
    Write-Log "流水线并发：转录串行，DeepSeek 翻译后台并发数=$MaxConcurrentTranslations"
    Write-Log "DeepSeek Model: $DeepSeekModel"
    Write-Log "Target Language: $TargetLanguage"
    Write-Log "Translate Tone: $TranslateTone"
    Write-Log "Max Batch Size: $MaxBatchSize"

    foreach ($root in $Roots) {
        $ok = Test-Path -LiteralPath $root
        Write-Log "Path check: $root => $ok"
    }

    $Videos = @()

    foreach ($root in $Roots) {
        if (!(Test-Path -LiteralPath $root)) {
            Write-Log "路径不可访问，跳过：$root"
            continue
        }

        Write-Log "扫描目录：$root"

        $found = Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object {
                $VideoExts -contains $_.Extension.ToLower() -and
                $_.LastWriteTime -lt (Get-Date).AddMinutes(-$MinAgeMinutes)
            }

        $Videos += $found
    }

    Write-Log "扫描到视频数量：$($Videos.Count)"

    $SkippedByName = $Videos | Where-Object {
        Test-SkipByFileName $_
    }

    Write-Log "按文件名规则跳过视频数量：$($SkippedByName.Count)"

    $SkippedByExternalSubtitle = $Videos | Where-Object {
        (-not (Test-SkipByFileName $_)) -and
        (Test-HasExternalSubtitle $_)
    }

    Write-Log "按外部字幕规则跳过视频数量：$($SkippedByExternalSubtitle.Count)"

    $SkippedByEmbeddedSubtitle = $Videos | Where-Object {
        (-not (Test-SkipByFileName $_)) -and
        (-not (Test-HasExternalSubtitle $_)) -and
        (Test-HasEmbeddedSubtitle $_)
    }

    Write-Log "按 MKV 内嵌字幕规则跳过视频数量：$($SkippedByEmbeddedSubtitle.Count)"

    $SkippedByPreviousFailure = $Videos | Where-Object {
        (-not (Test-SkipByFileName $_)) -and
        (-not (Test-HasExternalSubtitle $_)) -and
        (-not (Test-HasEmbeddedSubtitle $_)) -and
        (Test-IsFailedVideo $_)
    }

    Write-Log "按失败清单跳过视频数量：$($SkippedByPreviousFailure.Count)"

    $SkippedByUnwritableOutput = $Videos | Where-Object {
        (-not (Test-SkipByFileName $_)) -and
        (-not (Test-HasExternalSubtitle $_)) -and
        (-not (Test-HasEmbeddedSubtitle $_)) -and
        (-not (Test-IsFailedVideo $_)) -and
        (-not (Test-HasFinalChineseSubtitle $_)) -and
        (-not (Test-SubtitleOutputWritable $_))
    }

    Write-Log "目标目录当前不可写视频数量：$($SkippedByUnwritableOutput.Count)"

    $EligibleVideos = @($Videos |
        Sort-Object LastWriteTime |
        Where-Object {
            (-not (Test-SkipByFileName $_)) -and
            (-not (Test-HasExternalSubtitle $_)) -and
            (-not (Test-HasEmbeddedSubtitle $_)) -and
            (-not (Test-IsFailedVideo $_)) -and
            (-not (Test-HasFinalChineseSubtitle $_))
        })

    Write-Log "过滤后可处理视频数量：$($EligibleVideos.Count)"

    if ($MaxFilesPerRun -gt 0) {
        $Queue = @($EligibleVideos | Select-Object -First $MaxFilesPerRun)
        Write-Log "本次启动处理上限：$MaxFilesPerRun"
    }
    else {
        $Queue = $EligibleVideos
        Write-Log "本次启动处理上限：不限制"
    }

    if ($Queue.Count -eq 0) {
        Write-Log "没有发现需要处理的视频。"
        Write-Log "===== Finished ====="
        exit 0
    }

    Write-Log "本轮待处理数量：$($Queue.Count)"

    $translationProcesses = [System.Collections.ArrayList]::new()
    $queueTotal = $Queue.Count
    $queueIndex = 0

    foreach ($video in $Queue) {
        if (!(Test-Path -LiteralPath $EnableFlag)) {
            Write-Log "开关已关闭，停止后续队列。"
            break
        }

        $queueIndex++
        $videoPath = $video.FullName
        $videoBase = [System.IO.Path]::GetFileNameWithoutExtension($video.Name)
        $safeBase = Get-SafeName -Text $videoBase
        $jobId = (Get-Date -Format "yyyyMMdd-HHmmss") + "_" + ([Guid]::NewGuid().ToString("N").Substring(0, 8))
        $jobDir = Join-Path $WorkRoot "$safeBase-$jobId"
        $localVideoPath = $null
        $reusableChineseSrt = Find-ReusableChineseSrt -SafeBase $safeBase
        $reusableJapaneseSrt = Find-ReusableJapaneseSrt -SafeBase $safeBase

        if (-not [string]::IsNullOrWhiteSpace($reusableChineseSrt)) {
            $jobDir = Split-Path -Parent $reusableChineseSrt
        }
        elseif (-not [string]::IsNullOrWhiteSpace($reusableJapaneseSrt)) {
            $jobDir = Split-Path -Parent $reusableJapaneseSrt
        }

        New-Item -ItemType Directory -Force -Path $jobDir | Out-Null

        $videoLockFile = "$videoPath.whisperjav.lock"

        if (Test-Path -LiteralPath $videoLockFile) {
            Write-Log "发现残留视频 lock，自动清理后继续处理：$videoLockFile"
            Remove-Item -LiteralPath $videoLockFile -Force -ErrorAction SilentlyContinue
        }

        Set-Content -LiteralPath $videoLockFile -Encoding UTF8 -Value @(
            "pid=$PID",
            "createdAt=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
            "video=$videoPath",
            "log=$LogFile"
        )

        try {
            Write-SubTaskProgress -QueueIndex $queueIndex -QueueTotal $queueTotal -SubTaskIndex 1 -SubTaskTotal 3 -SubTaskName "准备处理" -VideoPath $videoPath
            Write-Log "开始处理视频：$videoPath"
            Write-Log "临时工作目录：$jobDir"
            Set-TaskState -Status "running" -StepName "准备处理视频" -VideoPath $videoPath -JobDir $jobDir -ProcessId $null -CommandLine ""

            if (-not [string]::IsNullOrWhiteSpace($reusableChineseSrt)) {
                Write-SubTaskProgress -QueueIndex $queueIndex -QueueTotal $queueTotal -SubTaskIndex 3 -SubTaskTotal 3 -SubTaskName "复用已有中文字幕" -VideoPath $videoPath
                Write-Log "发现已生成但未写回的中文字幕，直接复用：$reusableChineseSrt"

                $ok = Copy-FinalChineseSubtitle -ChineseSrt $reusableChineseSrt -Video $video
                if ($ok) {
                    Remove-Item -LiteralPath $jobDir -Recurse -Force -ErrorAction SilentlyContinue
                    Write-Log "已清理临时目录：$jobDir"
                }
                else {
                    Write-Log "复用已有中文字幕失败，保留临时目录：$jobDir"
                }

                Remove-Item -LiteralPath $videoLockFile -Force -ErrorAction SilentlyContinue
                continue
            }

            # ------------------------------
            # 第一步：生成临时日语 SRT
            # ------------------------------

            $transcribeStartedAt = Get-Date
            $japaneseSrt = $null

            if (-not [string]::IsNullOrWhiteSpace($reusableJapaneseSrt)) {
                $japaneseSrt = $reusableJapaneseSrt
                Write-SubTaskProgress -QueueIndex $queueIndex -QueueTotal $queueTotal -SubTaskIndex 1 -SubTaskTotal 3 -SubTaskName "复用已有日语 SRT" -VideoPath $videoPath
                Write-Log "发现可复用日语 SRT，跳过重新转录：$japaneseSrt"
            } else {
                Write-SubTaskProgress -QueueIndex $queueIndex -QueueTotal $queueTotal -SubTaskIndex 1 -SubTaskTotal 3 -SubTaskName "日语转录" -VideoPath $videoPath
                $whisperjav = Get-ToolCommand -ToolName "whisperjav"
                $localVideoPath = Copy-VideoToLocalWorkDir -Video $video -JobDir $jobDir

                $transcribeArgs = @(
                    $localVideoPath,

                    "--ensemble",
                    "--ensemble-serial",

                    "--language", $SourceLanguage,
                    "--subs-language", $SubsLanguage,

                    "--pass1-pipeline", $Pass1Pipeline,
                    "--pass1-sensitivity", $Pass1Sensitivity,
                    "--pass1-scene-detector", $Pass1SceneDetector,
                    "--pass1-speech-enhancer", $Pass1SpeechEnhancer,
                    "--pass1-speech-segmenter", $Pass1SpeechSegmenter,
                    "--pass1-model", $Pass1Model,

                    "--pass2-pipeline", $Pass2Pipeline,
                    "--pass2-sensitivity", $Pass2Sensitivity,
                    "--pass2-scene-detector", $Pass2SceneDetector,
                    "--pass2-speech-enhancer", $Pass2SpeechEnhancer,
                    "--pass2-speech-segmenter", $Pass2SpeechSegmenter,
                    "--pass2-model", $Pass2Model,

                    "--merge-strategy", $MergeStrategy,

                    "--output-format", $OutputFormat,
                    "--output-dir", $jobDir
                )

                $exitCode = Invoke-ProcessWithSwitch `
                    -FileName $whisperjav `
                    -ArgsList $transcribeArgs `
                    -StepName "日语转录" `
                    -VideoPath $videoPath `
                    -JobDir $jobDir

                if ($exitCode -eq 999) {
                    Write-Log "任务被手动关闭，停止当前视频。"
                    break
                }

                if ($exitCode -ne 0) {
                    if ($script:LastProcessHadUnrecoverableMediaError) {
                        Add-FailedVideo -VideoPath $videoPath -Reason "ffmpeg 无法读取/抽取音频，可能文件损坏、未下载完整或路径不可访问。"
                    }

                    Write-Log "日语转录失败，跳过：$videoPath"
                    continue
                }

                $japaneseSrt = Find-GeneratedJapaneseSrt -JobDir $jobDir -StartedAt $transcribeStartedAt
            }

            if ([string]::IsNullOrWhiteSpace($japaneseSrt)) {
                Write-Log "没有找到临时日语 SRT，跳过：$videoPath"
                continue
            }

            Write-SubTaskProgress -QueueIndex $queueIndex -QueueTotal $queueTotal -SubTaskIndex 1 -SubTaskTotal 3 -SubTaskName "日语转录完成" -VideoPath $videoPath
            Write-Log "临时日语 SRT：$japaneseSrt"

            # ------------------------------
            # 第二步：后台 DeepSeek 翻译成中文
            # ------------------------------

            Write-SubTaskProgress -QueueIndex $queueIndex -QueueTotal $queueTotal -SubTaskIndex 2 -SubTaskTotal 3 -SubTaskName "启动 DeepSeek 翻译" -VideoPath $videoPath
            Start-BackgroundTranslation `
                -Processes $translationProcesses `
                -JapaneseSrt $japaneseSrt `
                -VideoPath $videoPath `
                -JobDir $jobDir

            Set-TaskState -Status "translation_started" -StepName "后台翻译已启动" -VideoPath $videoPath -JobDir $jobDir -ProcessId $null -CommandLine ""
            Write-SubTaskProgress -QueueIndex $queueIndex -QueueTotal $queueTotal -SubTaskIndex 3 -SubTaskTotal 3 -SubTaskName "后台翻译运行中，继续转录下一部" -VideoPath $videoPath
        }
        catch {
            Write-Log "异常：$($_.Exception.Message)"
            Write-Log "保留临时目录供排查：$jobDir"
        }
        finally {
            if (-not [string]::IsNullOrWhiteSpace($localVideoPath)) {
                Remove-Item -LiteralPath $localVideoPath -Force -ErrorAction SilentlyContinue
            }

            Remove-Item -LiteralPath $videoLockFile -Force -ErrorAction SilentlyContinue
        }
    }

    Wait-AllTranslations -Processes $translationProcesses

    Set-TaskState -Status "finished" -StepName "本轮结束" -VideoPath "" -JobDir "" -ProcessId $null -CommandLine ""
    Write-Log "===== Finished ====="
}
finally {
    Remove-Item -LiteralPath $GlobalLockFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $MainPidFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $CurrentPidFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $TranslationPidFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $CurrentTaskFile -Force -ErrorAction SilentlyContinue
}



