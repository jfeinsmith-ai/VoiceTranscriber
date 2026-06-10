# Watch-ObsTranscripts-FasterWhisper-Production.ps1
# Polls the OBS recordings folder for new MKV files, waits until each file stops growing,
# runs the faster-whisper transcript processor, then optionally runs a summarization script.
<#
.SYNOPSIS
Watches the OBS recordings folder for new MKV files, waits until each file is stable, then runs the faster-whisper transcription processor.

.DESCRIPTION
This script is intended to stay running in the background.

It polls the OBS video folder on a fixed interval.
It ignores files that already exist at startup unless -RunExistingFiles is used.
When a new .mkv appears, it waits until the file size stops changing.
Then it calls the transcript processor script.
After transcription, it can optionally launch the summarization script.

.DEFAULT USAGE
Run watcher without summarization:

powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Watch-ObsTranscripts-FasterWhisper-Production.ps1"

Run watcher with summarization:

powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Watch-ObsTranscripts-FasterWhisper-Production.ps1" -EnableSummarization

Run watcher with a larger faster-whisper model:

powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Watch-ObsTranscripts-FasterWhisper-Production.ps1" -Model medium.en

Run watcher and process existing MKV files too:

powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Watch-ObsTranscripts-FasterWhisper-Production.ps1" -RunExistingFiles

.TASK SCHEDULER EXAMPLE
Use this as the scheduled task action:

Program/script:
powershell.exe

Arguments:

-NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Watch-ObsTranscripts-FasterWhisper-Production.ps1" -EnableSummarization -Model small.en

.PARAMETER ObsFolder
Folder where OBS writes recordings.

Default:
C:\Users\jfein\Videos

.PARAMETER ProcessorScript
Path to the working faster-whisper processor script.

Default:
C:\Scripts\Process-ObsTranscript-FasterWhisper.ps1

.PARAMETER TranscriptFolder
Folder where markdown transcripts are written.

Default:
C:\Users\jfein\OneDrive\Documents\Obsidian\Personal\30 Resources\Transcripts

.PARAMETER MicAudioStreamIndex
Audio stream index for the mic track.

Default:
1

.PARAMETER DesktopAudioStreamIndex
Audio stream index for the desktop/system audio track.

Default:
2

.PARAMETER Model
faster-whisper model name passed through to the processor script.

Default:
small.en

Examples:
tiny.en
base.en
small.en
medium.en
large-v3

.PARAMETER PollIntervalSeconds
How often the watcher checks for new MKV files.

Default:
5

.PARAMETER StableChecksRequired
How many consecutive unchanged file-size checks are required before processing starts.

Default:
3

Example:
With PollIntervalSeconds 5 and StableChecksRequired 3, the file must stay unchanged for about 15 seconds.

.PARAMETER MinimumAgeSeconds
Minimum age of the MKV file since LastWriteTime before it can be treated as stable.

Default:
10

.PARAMETER UseVadFilter
Enables faster-whisper VAD filtering.

Default behavior:
VAD is OFF because -NoVadFilter is passed to the processor unless this switch is used.

Use this only if VAD is known to work well with your OBS tracks.

.PARAMETER RunExistingFiles
Processes MKV files that already exist when the watcher starts.

Default behavior:
Existing MKV files are ignored at startup.
Only newly created files are processed.

.PARAMETER EnableSummarization
Runs the summarization script after transcription finishes.

Default behavior:
Summarization is disabled.

.PARAMETER SummarizerScript
Path to the Python summarization script.

Default:
C:\Scripts\summarize_transcript.py

.PARAMETER PythonExe
Python launcher or executable used for the summarizer.

Default:
py

.NOTES
Current expected OBS audio layout:

Stream 0:
mixed audio, optional fallback/debug use

Stream 1:
mic audio

Stream 2:
desktop/system audio

The watcher reads the actual transcript path from the processor output line:

Markdown note: <path>

This avoids guessing the final markdown filename.
#>
[CmdletBinding()]
param(
    [string]$ObsFolder = "C:\Users\jfein\Videos",

    [string]$ProcessorScript = "C:\Scripts\Process-ObsTranscript-FasterWhisper-v4.ps1",

    [string]$TranscriptFolder = "C:\Users\jfein\OneDrive\Documents\Obsidian\Personal\30 Resources\Transcripts",

    [int]$MicAudioStreamIndex = 1,

    [int]$DesktopAudioStreamIndex = 2,

    [string]$Model = "small.en",

    [int]$PollIntervalSeconds = 5,

    [int]$StableChecksRequired = 3,

    [int]$MinimumAgeSeconds = 10,

    [switch]$UseVadFilter,

    [switch]$RunExistingFiles,

    [switch]$EnableSummarization,

    [string]$SummarizerScript = "C:\Scripts\summarize_transcript.py",

    [string]$PythonExe = "py"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message)

    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$stamp] $Message"
}

function ConvertTo-TranscriptFileName {
    param([Parameter(Mandatory=$true)][string]$VideoPath)

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($VideoPath)
    $safeName = $baseName -replace ' ', '_'
    $safeName = $safeName -replace '[^\w\-]', '_'

    return ($safeName + ".md")
}

function Wait-FileStable {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [int]$ChecksRequired = 3,
        [int]$IntervalSeconds = 5,
        [int]$MinimumAgeSeconds = 10
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Status "File disappeared before processing: $Path"
        return $false
    }

    Write-Status "Waiting for file to stop changing: $Path"

    $stableCount = 0
    $lastLength = -1

    while ($true) {
        Start-Sleep -Seconds $IntervalSeconds

        if (-not (Test-Path -LiteralPath $Path)) {
            Write-Status "File disappeared while waiting: $Path"
            return $false
        }

        $item = Get-Item -LiteralPath $Path
        $ageSeconds = ((Get-Date) - $item.LastWriteTime).TotalSeconds
        $currentLength = [int64]$item.Length
        $sizeMB = [math]::Round(($currentLength / 1MB), 2)

        if (($currentLength -eq $lastLength) -and ($ageSeconds -ge $MinimumAgeSeconds)) {
            $stableCount++
            Write-Status ("Stable check {0}/{1}: {2} MB, age {3:n0}s" -f $stableCount, $ChecksRequired, $sizeMB, $ageSeconds)

            if ($stableCount -ge $ChecksRequired) {
                Write-Status "File appears stable."
                return $true
            }
        }
        else {
            $stableCount = 0
            Write-Status ("Still changing or too new: {0} MB, age {1:n0}s" -f $sizeMB, $ageSeconds)
        }

        $lastLength = $currentLength
    }
}

function Invoke-Processor {
    param([Parameter(Mandatory=$true)][string]$InputVideo)

    if (-not (Test-Path -LiteralPath $ProcessorScript)) {
        throw "Processor script not found: $ProcessorScript"
    }

    $processorArgs = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $ProcessorScript,
        "-InputVideo", $InputVideo,
        "-MicAudioStreamIndex", $MicAudioStreamIndex,
        "-DesktopAudioStreamIndex", $DesktopAudioStreamIndex,
        "-Model", $Model
    )

    if (-not $UseVadFilter) {
        $processorArgs += "-NoVadFilter"
    }

    Write-Status "Starting transcription: $InputVideo"
    Write-Status ("Processor args: Mic={0}, Desktop={1}, Model={2}, VAD={3}" -f $MicAudioStreamIndex, $DesktopAudioStreamIndex, $Model, ([bool]$UseVadFilter))

    $outputLines = New-Object System.Collections.Generic.List[string]

    & powershell.exe @processorArgs 2>&1 | ForEach-Object {
        $line = [string]$_
        $outputLines.Add($line) | Out-Null
        Write-Host $line
    }

    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        throw "Processor failed with exit code $exitCode"
    }

    Write-Status "Transcription finished."

    $markdownLine = $outputLines |
        Where-Object { $_ -match '^Markdown note:\s*(.+)$' } |
        Select-Object -Last 1

    if ($markdownLine -match '^Markdown note:\s*(.+)$') {
        $pathFromOutput = $Matches[1].Trim()

        if (Test-Path -LiteralPath $pathFromOutput) {
            return $pathFromOutput
        }

        Write-Status "Processor reported markdown path, but it was not found: $pathFromOutput"
    }

    $fallbackPath = Join-Path $TranscriptFolder (ConvertTo-TranscriptFileName -VideoPath $InputVideo)

    if (Test-Path -LiteralPath $fallbackPath) {
        Write-Status "Using fallback transcript path: $fallbackPath"
        return $fallbackPath
    }

    throw "Could not determine transcript path. Processor did not report a valid markdown file, and fallback path does not exist: $fallbackPath"
}

function Invoke-Summarizer {
    param([Parameter(Mandatory=$true)][string]$TranscriptPath)

    if (-not $EnableSummarization) {
        Write-Status "Summarization disabled."
        return
    }

    if (-not (Test-Path -LiteralPath $SummarizerScript)) {
        Write-Status "Summarizer enabled, but script not found: $SummarizerScript"
        return
    }

    if (-not (Test-Path -LiteralPath $TranscriptPath)) {
        Write-Status "Summarizer skipped because transcript does not exist: $TranscriptPath"
        return
    }

    Write-Status "Starting summarization pipeline: $TranscriptPath"

    & $PythonExe $SummarizerScript --input $TranscriptPath

    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        Write-Status "Summarizer failed with exit code $exitCode"
        return
    }

    Write-Status "Summarization finished."
}

function Get-MkvFiles {
    param([string]$Folder)

    if (-not (Test-Path -LiteralPath $Folder)) {
        throw "OBS folder not found: $Folder"
    }

    return @(Get-ChildItem -LiteralPath $Folder -File -Filter "*.mkv" | Sort-Object LastWriteTime)
}

if (-not (Test-Path -LiteralPath $ObsFolder)) {
    throw "OBS folder not found: $ObsFolder"
}

if (-not (Test-Path -LiteralPath $ProcessorScript)) {
    throw "Processor script not found: $ProcessorScript"
}

if (-not (Test-Path -LiteralPath $TranscriptFolder)) {
    Write-Status "Transcript folder not found. Creating: $TranscriptFolder"
    New-Item -ItemType Directory -Force -Path $TranscriptFolder | Out-Null
}

Write-Status "Polling OBS folder: $ObsFolder"
Write-Status "Processor script: $ProcessorScript"
Write-Status "Transcript folder: $TranscriptFolder"
Write-Status "Mic stream index: $MicAudioStreamIndex"
Write-Status "Desktop stream index: $DesktopAudioStreamIndex"
Write-Status "Model: $Model"
Write-Status ("VAD filter: {0}" -f ([bool]$UseVadFilter))
Write-Status "Poll interval: $PollIntervalSeconds seconds"
Write-Status "Stable checks required: $StableChecksRequired"
Write-Status "Minimum file age: $MinimumAgeSeconds seconds"
Write-Status ("Summarization enabled: {0}" -f ([bool]$EnableSummarization))
Write-Status "Press Ctrl+C to stop."

$processed = New-Object "System.Collections.Generic.HashSet[string]"

if (-not $RunExistingFiles) {
    foreach ($existing in Get-MkvFiles -Folder $ObsFolder) {
        [void]$processed.Add($existing.FullName)
    }

    Write-Status ("Initial MKV files ignored: {0}" -f $processed.Count)
}
else {
    Write-Status "RunExistingFiles enabled. Existing MKV files may be processed."
}

while ($true) {
    try {
        $candidates = Get-MkvFiles -Folder $ObsFolder

        foreach ($candidate in $candidates) {
            $inputVideo = $candidate.FullName

            if ($processed.Contains($inputVideo)) {
                continue
            }

            Write-Status "New MKV detected: $inputVideo"

            $isStable = Wait-FileStable `
                -Path $inputVideo `
                -ChecksRequired $StableChecksRequired `
                -IntervalSeconds $PollIntervalSeconds `
                -MinimumAgeSeconds $MinimumAgeSeconds

            if (-not $isStable) {
                Write-Status "Skipping unstable or missing file: $inputVideo"
                [void]$processed.Add($inputVideo)
                continue
            }

            try {
                $transcriptPath = Invoke-Processor -InputVideo $inputVideo
                Write-Status "Transcript path: $transcriptPath"

                Invoke-Summarizer -TranscriptPath $transcriptPath
            }
            catch {
                Write-Status ("Processing error for {0}: {1}" -f $inputVideo, $_.Exception.Message)
            }
            finally {
                [void]$processed.Add($inputVideo)
            }
        }

        Start-Sleep -Seconds $PollIntervalSeconds
    }
    catch {
        Write-Status ("Watcher error: {0}" -f $_.Exception.Message)
        Start-Sleep -Seconds $PollIntervalSeconds
    }
}
