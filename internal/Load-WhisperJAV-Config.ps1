$scriptDir = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    $PSScriptRoot
}

if ([System.IO.Path]::GetFileName($scriptDir) -ieq "internal") {
    $script:BaseDir = Split-Path -Parent $scriptDir
} elseif ([string]::IsNullOrWhiteSpace($script:BaseDir)) {
    $script:BaseDir = $scriptDir
}

$ConfigJsonFile = Join-Path $script:BaseDir "config.json"
$LegacyConfigFile = Join-Path $script:BaseDir "config.ps1"
$LegacyPathsFile = Join-Path $script:BaseDir "paths.ps1"

function Resolve-ConfigPathValue {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }

    return [Environment]::ExpandEnvironmentVariables($Path)
}

function Set-IfValue {
    param(
        [string]$Name,
        [object]$Value
    )

    if ($null -ne $Value -and -not ([string]::IsNullOrWhiteSpace([string]$Value))) {
        Set-Variable -Name $Name -Scope Script -Value $Value
    }
}

if (Test-Path -LiteralPath $ConfigJsonFile) {
    $Settings = Get-Content -LiteralPath $ConfigJsonFile -Encoding UTF8 -Raw | ConvertFrom-Json

    if ($null -ne $Settings.paths) {
        Set-IfValue "BaseDir" (Resolve-ConfigPathValue $Settings.paths.baseDir)
        Set-IfValue "WorkRoot" (Resolve-ConfigPathValue $Settings.paths.workRoot)
        Set-IfValue "ManualOutputDir" (Resolve-ConfigPathValue $Settings.paths.manualOutputDir)
        Set-IfValue "NasDrivePrefix" $Settings.paths.nasDrivePrefix
        Set-IfValue "NasUncPrefix" $Settings.paths.nasUncPrefix
        Set-IfValue "WhisperJavInstallDir" (Resolve-ConfigPathValue $Settings.paths.whisperJavInstallDir)
        Set-IfValue "SystemPowerShell" (Resolve-ConfigPathValue $Settings.paths.systemPowerShell)
        Set-IfValue "WindowsTerminal" (Resolve-ConfigPathValue $Settings.paths.windowsTerminal)

        if ($null -ne $Settings.paths.videoRoots) {
            $script:VideoRoots = @($Settings.paths.videoRoots | ForEach-Object { Resolve-ConfigPathValue $_ })
        }
    }

    if ($null -ne $Settings.deepSeek) {
        $apiKey = ""
        if (-not [string]::IsNullOrWhiteSpace($Settings.deepSeek.apiKey)) {
            $apiKey = [string]$Settings.deepSeek.apiKey
        } elseif (-not [string]::IsNullOrWhiteSpace($Settings.deepSeek.apiKeyEnv)) {
            $apiKey = [Environment]::GetEnvironmentVariable([string]$Settings.deepSeek.apiKeyEnv)
        }

        Set-IfValue "DeepSeekApiKey" $apiKey
        Set-IfValue "DeepSeekModel" $Settings.deepSeek.model
        Set-IfValue "TargetLanguage" $Settings.deepSeek.targetLanguage
        Set-IfValue "TranslateTone" $Settings.deepSeek.translateTone
        if ($null -ne $Settings.deepSeek.maxBatchSize) { $script:MaxBatchSize = [int]$Settings.deepSeek.maxBatchSize }
    }

    if ($null -ne $Settings.processing) {
        if ($null -ne $Settings.processing.logRetentionDays) { $script:LogRetentionDays = [int]$Settings.processing.logRetentionDays }
        if ($null -ne $Settings.processing.maxFilesPerRun) { $script:MaxFilesPerRun = [int]$Settings.processing.maxFilesPerRun }
        if ($null -ne $Settings.processing.maxConcurrentTranslations) { $script:MaxConcurrentTranslations = [int]$Settings.processing.maxConcurrentTranslations }
        if ($null -ne $Settings.processing.minAgeMinutes) { $script:MinAgeMinutes = [int]$Settings.processing.minAgeMinutes }
    }

    if ($null -ne $Settings.transcription) {
        Set-IfValue "SourceLanguage" $Settings.transcription.sourceLanguage
        Set-IfValue "SubsLanguage" $Settings.transcription.subsLanguage
        Set-IfValue "OutputFormat" $Settings.transcription.outputFormat
        Set-IfValue "Pass1Pipeline" $Settings.transcription.pass1Pipeline
        Set-IfValue "Pass1Sensitivity" $Settings.transcription.pass1Sensitivity
        Set-IfValue "Pass1SceneDetector" $Settings.transcription.pass1SceneDetector
        Set-IfValue "Pass1SpeechEnhancer" $Settings.transcription.pass1SpeechEnhancer
        Set-IfValue "Pass1SpeechSegmenter" $Settings.transcription.pass1SpeechSegmenter
        Set-IfValue "Pass1Model" $Settings.transcription.pass1Model
        Set-IfValue "Pass2Pipeline" $Settings.transcription.pass2Pipeline
        Set-IfValue "Pass2Sensitivity" $Settings.transcription.pass2Sensitivity
        Set-IfValue "Pass2SceneDetector" $Settings.transcription.pass2SceneDetector
        Set-IfValue "Pass2SpeechEnhancer" $Settings.transcription.pass2SpeechEnhancer
        Set-IfValue "Pass2SpeechSegmenter" $Settings.transcription.pass2SpeechSegmenter
        Set-IfValue "Pass2Model" $Settings.transcription.pass2Model
        Set-IfValue "MergeStrategy" $Settings.transcription.mergeStrategy
    }
} else {
    if (Test-Path -LiteralPath $LegacyPathsFile) { . $LegacyPathsFile }
    if (Test-Path -LiteralPath $LegacyConfigFile) { . $LegacyConfigFile }
}

if ([string]::IsNullOrWhiteSpace($script:BaseDir)) { $script:BaseDir = "D:\WhisperJAV-Auto" }
if ([string]::IsNullOrWhiteSpace($script:WorkRoot)) { $script:WorkRoot = "C:\WhisperJAV-Auto\work" }
if ([string]::IsNullOrWhiteSpace($script:ManualOutputDir)) { $script:ManualOutputDir = Join-Path $script:BaseDir "manual-output" }
if ($null -eq $script:VideoRoots -or $script:VideoRoots.Count -eq 0) { $script:VideoRoots = @("X:\videos") }
if ([string]::IsNullOrWhiteSpace($script:NasDrivePrefix)) { $script:NasDrivePrefix = "X:\" }
if ([string]::IsNullOrWhiteSpace($script:NasUncPrefix)) { $script:NasUncPrefix = "\\SERVER\Share\" }
if ([string]::IsNullOrWhiteSpace($script:WhisperJavInstallDir)) { $script:WhisperJavInstallDir = "D:\whisperjav" }
if ([string]::IsNullOrWhiteSpace($script:SystemPowerShell)) { $script:SystemPowerShell = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" }
if ([string]::IsNullOrWhiteSpace($script:WindowsTerminal)) { $script:WindowsTerminal = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\wt.exe" }
