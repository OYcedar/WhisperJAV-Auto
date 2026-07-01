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
$RunScript = Join-Path $InternalDir "Run-WhisperJAV.ps1"
if (!(Test-Path -LiteralPath $RunScript)) {
    $RunScript = Join-Path $BaseDir "Run-WhisperJAV.ps1"
}
$StatusBat = Join-Path $BaseDir "查看中文字幕处理状态.bat"
$StopBat = Join-Path $BaseDir "关闭中文字幕自动处理.bat"

try {
    $Host.UI.RawUI.WindowTitle = "WhisperJAV-Auto 任务进度"
    $Host.UI.RawUI.BackgroundColor = "Black"
    $Host.UI.RawUI.ForegroundColor = "Gray"
    Clear-Host
} catch {}

function Write-PanelLine {
    param(
        [string]$Text,
        [string]$Color = "Gray"
    )

    Write-Host $Text -ForegroundColor $Color
}

Write-PanelLine "============================================================" "DarkCyan"
Write-PanelLine " WhisperJAV-Auto  中文字幕自动处理" "Cyan"
Write-PanelLine "============================================================" "DarkCyan"
Write-PanelLine " 模式      Ensemble 双 Pass 日语转录 -> DeepSeek 中文翻译" "Gray"
Write-PanelLine " 输出      视频同名 .srt，完成后清理临时目录" "Gray"
Write-PanelLine " 进度      [########--------------] 百分比 | 任务序号 | 子任务" "Cyan"
Write-PanelLine " 中断      直接关闭此进度窗口，或运行：$StopBat" "Yellow"
Write-PanelLine " 状态      可随时运行：$StatusBat" "DarkGray"
Write-PanelLine "============================================================" "DarkCyan"
Write-Host ""

& $RunScript
$exitCode = $LASTEXITCODE

Write-Host ""
Write-PanelLine "============================================================" "DarkCyan"
if ($exitCode -and $exitCode -ne 0) {
    Write-PanelLine " 任务窗口已结束，退出码：$exitCode" "Yellow"
} else {
    Write-PanelLine " 任务窗口已结束。" "Green"
}
Write-PanelLine " 可关闭此窗口，或查看 logs 目录排查详细记录。" "Gray"
Write-PanelLine "============================================================" "DarkCyan"

