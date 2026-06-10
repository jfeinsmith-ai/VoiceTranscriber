# Process-ObsTranscript-FasterWhisper-v4.ps1
# Stable production processor for OBS MKV transcription using faster-whisper + PyAV.
# Features:
# - Clean PyAV WAV extraction
# - Python 3.14 compatible RMS
# - Clamps tiny negative timestamps
# - Safe JSON merge
# - Filters common silence hallucinations
# - Always writes debug JSON
# - Optional mixed-track fallback when separated tracks produce too little text
# - Prints total processing time

<#
.SYNOPSIS
Transcribes an OBS MKV recording into an Obsidian-ready markdown transcript using faster-whisper and PyAV.

.DESCRIPTION
This script processes one MKV file at a time.

It extracts the configured OBS audio streams using PyAV.
It transcribes the mic and desktop/system tracks separately with faster-whisper.
It merges the resulting transcript segments by timestamp.
It writes a markdown transcript into the Obsidian transcript folder.

No external ffmpeg.exe is required.
PyAV provides the FFmpeg functionality through its Python package.

.DEFAULT USAGE
Transcribe the latest MKV in the OBS video folder:

powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Process-ObsTranscript-FasterWhisper.ps1"

Transcribe a specific MKV:

powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Process-ObsTranscript-FasterWhisper.ps1" -InputVideo "C:\Users\jfein\Videos\test-small.mkv"

Recommended production usage with your current OBS track layout:

powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Process-ObsTranscript-FasterWhisper.ps1" `
  -InputVideo "C:\Users\jfein\Videos\test-small.mkv" `
  -MicAudioStreamIndex 1 `
  -DesktopAudioStreamIndex 2 `
  -NoVadFilter

Debug usage, keeping WAV and JSON files:

powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Process-ObsTranscript-FasterWhisper.ps1" `
  -InputVideo "C:\Users\jfein\Videos\test-small.mkv" `
  -MicAudioStreamIndex 1 `
  -DesktopAudioStreamIndex 2 `
  -NoVadFilter `
  -KeepTempFiles

.PARAMETER InputVideo
Specific MKV file to transcribe.

If omitted, the script uses the newest .mkv file in VideoDir.

.PARAMETER VideoDir
Folder used when InputVideo is not provided.

Default:
C:\Users\jfein\Videos

.PARAMETER VaultDir
Folder where the final markdown transcript is written.

Default:
C:\Users\jfein\OneDrive\Documents\Obsidian\Personal\30 Resources\Transcripts

.PARAMETER MicAudioStreamIndex
Audio stream index for your mic track.

Current expected value:
1

.PARAMETER DesktopAudioStreamIndex
Audio stream index for desktop/system audio.

Current expected value:
2

.PARAMETER MixedAudioStreamIndex
Audio stream index for the mixed audio track.

Default:
0

Used only if the script version includes mixed-track fallback logic.

.PARAMETER Model
faster-whisper model name.

Default:
small.en

Common options:
base.en
small.en
medium.en

base.en is faster but less accurate.
small.en is a good default.
medium.en is slower but more accurate.

.PARAMETER ModelCacheDir
Optional folder for faster-whisper model downloads/cache.

Leave blank to use the default faster-whisper cache location.

.PARAMETER Device
Device used by faster-whisper.

Default:
auto

Common values:
auto
cpu
cuda

.PARAMETER ComputeType
Compute type used by faster-whisper.

Default:
int8

Recommended for CPU:
int8

.PARAMETER BeamSize
Beam size for decoding.

Default:
1

Higher values may improve accuracy but slow processing.

.PARAMETER BestOf
Best-of value for decoding.

Default:
1

Higher values may improve accuracy but slow processing.

.PARAMETER CpuThreads
CPU thread count passed to faster-whisper.

Default:
0

0 lets faster-whisper choose.

.PARAMETER NumWorkers
Worker count passed to faster-whisper.

Default:
1

.PARAMETER NoVadFilter
Disables faster-whisper VAD filtering.

Recommended:
Use this switch for your current OBS separated-track setup.

Reason:
VAD was dropping speech from isolated OBS tracks during testing.

.PARAMETER ConditionPreviousText
Enables faster-whisper previous-text conditioning.

Default:
off

Keeping this off can reduce repeated or carried-forward hallucinated text.

.PARAMETER KeepTempFiles
Keeps temporary/debug outputs.

When enabled, the script copies JSON and WAV files to DebugDir and keeps the temp working folder.

Useful for debugging:
- bad timestamps
- missing mic audio
- bad desktop audio
- noisy extracted WAV files
- incorrect JSON merge

.PARAMETER DisableMixedFallback
Disables mixed-track fallback if the script version supports it.

.PARAMETER MinimumSeparatedSegments
Minimum usable separated-track segments required before trying mixed-track fallback.

Default:
3

.PARAMETER DebugDir
Folder for debug JSON and WAV files.

Default:
C:\Scripts\debug-transcript

.PARAMETER PythonExe
Python launcher or executable.

Default:
py

.NOTES
Required Python packages:

py -m pip install faster-whisper av

Current expected OBS audio layout:

Stream 0:
mixed audio

Stream 1:
mic audio

Stream 2:
desktop/system audio

The script prints the final markdown path as:

Markdown note: <path>

The watcher depends on that line to find the transcript after processing.
#>

[CmdletBinding()]
param(
    [string]$InputVideo = "",

    [string]$VideoDir = "C:\Users\jfein\Videos",

    [string]$VaultDir = "C:\Users\jfein\OneDrive\Documents\Obsidian\Personal\30 Resources\Transcripts",

    [int]$MicAudioStreamIndex = 1,

    [int]$DesktopAudioStreamIndex = 2,

    [int]$MixedAudioStreamIndex = 0,

    [string]$Model = "small.en",

    [string]$ModelCacheDir = "",

    [string]$Device = "auto",

    [string]$ComputeType = "int8",

    [int]$BeamSize = 1,

    [int]$BestOf = 1,

    [int]$CpuThreads = 0,

    [int]$NumWorkers = 1,

    [switch]$NoVadFilter,

    [switch]$ConditionPreviousText,

    [switch]$KeepTempFiles,

    [switch]$DisableMixedFallback,

    [int]$MinimumSeparatedSegments = 3,

    [string]$DebugDir = "C:\Scripts\debug-transcript",

    [string]$PythonExe = "py"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$timer = [System.Diagnostics.Stopwatch]::StartNew()

function Write-Info {
    param([string]$Message)
    Write-Host $Message
}

function Invoke-CheckedCommand {
    param(
        [Parameter(Mandatory=$true)][string]$Exe,
        [Parameter(Mandatory=$true)][string[]]$Args
    )

    & $Exe @Args
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        throw @"
Command failed with exit code $exitCode
EXE: $Exe
ARGS: $($Args -join ' ')
"@
    }
}

function Format-TranscriptTime {
    param([double]$Seconds)

    if ($Seconds -lt 0.0) {
        $Seconds = 0.0
    }

    $totalSeconds = [math]::Floor($Seconds)
    $ts = [TimeSpan]::FromSeconds($totalSeconds)

    if ($ts.TotalHours -ge 1) {
        return "{0:00}:{1:00}:{2:00}" -f [math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds
    }

    return "{0:00}:{1:00}" -f $ts.Minutes, $ts.Seconds
}

function ConvertTo-SafeMarkdownFileName {
    param([Parameter(Mandatory=$true)][string]$VideoPath)

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($VideoPath)
    $safeName = $baseName -replace ' ', '_'
    $safeName = $safeName -replace '[^\w\-]', '_'

    return ($safeName + ".md")
}

function Get-InputVideo {
    if ($InputVideo -and (Test-Path -LiteralPath $InputVideo)) {
        return (Get-Item -LiteralPath $InputVideo).FullName
    }

    if ($InputVideo -and -not (Test-Path -LiteralPath $InputVideo)) {
        throw "InputVideo not found: $InputVideo"
    }

    if (-not (Test-Path -LiteralPath $VideoDir)) {
        throw "VideoDir not found: $VideoDir"
    }

    $latest = Get-ChildItem -LiteralPath $VideoDir -File -Filter "*.mkv" |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $latest) {
        throw "No MKV files found in $VideoDir"
    }

    return $latest.FullName
}

function Read-SegmentsFromJson {
    param([Parameter(Mandatory=$true)][string]$JsonPath)

    if (-not (Test-Path -LiteralPath $JsonPath)) {
        throw "JSON output not found: $JsonPath"
    }

    $payload = Get-Content -LiteralPath $JsonPath -Raw | ConvertFrom-Json
    $segments = @($payload.segments)

    return [PSCustomObject]@{
        Payload = $payload
        Segments = $segments
    }
}

function Test-IsBadHallucination {
    param([string]$Text)

    if (-not $Text) {
        return $true
    }

    $clean = $Text.Trim().ToLowerInvariant()
    $clean = $clean -replace '[\.\,\!\?\s]+$', ''

    if ($clean.Length -eq 0) {
        return $true
    }

    $bad = @(
        "thank you",
        "thanks for watching",
        "you",
        ".",
        "uh",
        "um"
    )

    return ($bad -contains $clean)
}

function Normalize-Segment {
    param([Parameter(Mandatory=$true)]$Segment)

    $startSeconds = [double]$Segment.StartSeconds
    $endSeconds = [double]$Segment.EndSeconds

    if ($startSeconds -lt 0.0) {
        $startSeconds = 0.0
    }

    if ($endSeconds -lt 0.0) {
        $endSeconds = 0.0
    }

    return [PSCustomObject]@{
        Source       = [string]$Segment.Source
        StartSeconds = $startSeconds
        EndSeconds   = $endSeconds
        Text         = ([string]$Segment.Text).Trim()
    }
}

function Run-TranscriptionWorker {
    param(
        [Parameter(Mandatory=$true)][string]$SourceLabel,
        [Parameter(Mandatory=$true)][int]$AudioStreamIndex,
        [Parameter(Mandatory=$true)][string]$VideoPath,
        [Parameter(Mandatory=$true)][string]$WorkerPath,
        [Parameter(Mandatory=$true)][string]$OutputJson,
        [Parameter(Mandatory=$true)][string]$OutputWav
    )

    $args = @(
        $WorkerPath,
        "--input-video", $VideoPath,
        "--audio-stream-index", ([string]$AudioStreamIndex),
        "--model", $Model,
        "--device", $Device,
        "--compute-type", $ComputeType,
        "--beam-size", ([string]$BeamSize),
        "--best-of", ([string]$BestOf),
        "--cpu-threads", ([string]$CpuThreads),
        "--num-workers", ([string]$NumWorkers),
        "--source-label", $SourceLabel,
        "--output-json", $OutputJson,
        "--wav-path", $OutputWav
    )

    if ($ModelCacheDir) {
        $args += @("--model-cache-dir", $ModelCacheDir)
    }

    if (-not $NoVadFilter) {
        $args += "--vad-filter"
    }

    if ($ConditionPreviousText) {
        $args += "--condition-previous-text"
    }

    if ($KeepTempFiles) {
        $args += "--keep-wav"
    }

    Write-Info "Transcribing $SourceLabel track with faster-whisper..."

    Invoke-CheckedCommand -Exe $PythonExe -Args $args

    $result = Read-SegmentsFromJson -JsonPath $OutputJson
    $payload = $result.Payload
    $segmentCount = @($payload.segments).Count

    $offset = 0.0
    if ($null -ne $payload.stream_start_offset) {
        $offset = [double]$payload.stream_start_offset
    }

    Write-Info ("{0} track WAV duration: {1:n1}s, RMS audio level: {2}, stream offset: {3:n3}s, transcript segments: {4}" -f `
        $SourceLabel,
        [double]$payload.wav_duration,
        [int]$payload.wav_rms,
        $offset,
        $segmentCount)

    if ($segmentCount -eq 0) {
        Write-Info "WARNING: No transcript segments found for $SourceLabel."
    }

    return $result
}

$workerCode = @'
import argparse
import json
import os
import sys
import tempfile
import wave
import struct

import av
from faster_whisper import WhisperModel


def get_audio_stream(input_video, audio_stream_index):
    container = av.open(input_video)
    audio_streams = [s for s in container.streams if s.type == "audio"]

    if audio_stream_index < 0 or audio_stream_index >= len(audio_streams):
        container.close()
        raise RuntimeError(
            f"Audio stream index {audio_stream_index} not found. "
            f"Found {len(audio_streams)} audio stream(s)."
        )

    stream = audio_streams[audio_stream_index]
    return container, stream


def get_audio_stream_start_offset(input_video, audio_stream_index):
    container, stream = get_audio_stream(input_video, audio_stream_index)

    offset = 0.0
    if stream.start_time is not None and stream.time_base is not None:
        offset = float(stream.start_time * stream.time_base)

    container.close()

    if offset < 0.0:
        offset = 0.0

    return offset


def decode_audio_stream_to_wav(input_video, audio_stream_index, output_wav):
    container, stream = get_audio_stream(input_video, audio_stream_index)

    resampler = av.AudioResampler(format="s16", layout="mono", rate=16000)

    with wave.open(output_wav, "wb") as wav_file:
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2)
        wav_file.setframerate(16000)

        for packet in container.demux(stream):
            try:
                frames = packet.decode()
            except Exception:
                continue

            for frame in frames:
                converted_frames = resampler.resample(frame)

                if converted_frames is None:
                    continue

                if not isinstance(converted_frames, list):
                    converted_frames = [converted_frames]

                for converted in converted_frames:
                    samples = converted.to_ndarray()
                    samples = samples.reshape(-1)

                    if str(samples.dtype) != "int16":
                        samples = samples.astype("int16")

                    wav_file.writeframes(samples.tobytes())

    container.close()


def fmt_time(seconds):
    if seconds is None:
        seconds = 0.0

    if seconds < 0.0:
        seconds = 0.0

    total_ms = int(round(seconds * 1000))
    hours = total_ms // 3600000
    rem = total_ms % 3600000
    minutes = rem // 60000
    rem = rem % 60000
    secs = rem // 1000
    millis = rem % 1000

    return f"{hours:02d}:{minutes:02d}:{secs:02d}.{millis:03d}"


def get_wav_stats(wav_path):
    with wave.open(wav_path, "rb") as wf:
        frame_count = wf.getnframes()
        rate = wf.getframerate()
        sampwidth = wf.getsampwidth()
        frames = wf.readframes(frame_count)
        duration = frame_count / float(rate) if rate else 0.0

    if not frames or sampwidth != 2:
        return duration, 0

    sample_count = len(frames) // 2
    if sample_count == 0:
        return duration, 0

    total = 0
    for (sample,) in struct.iter_unpack("<h", frames[:sample_count * 2]):
        total += sample * sample

    rms = int((total / sample_count) ** 0.5)
    return duration, rms


def main():
    parser = argparse.ArgumentParser()

    parser.add_argument("--input-video", required=True)
    parser.add_argument("--audio-stream-index", type=int, required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--model-cache-dir", default="")
    parser.add_argument("--device", default="auto")
    parser.add_argument("--compute-type", default="int8")
    parser.add_argument("--beam-size", type=int, default=1)
    parser.add_argument("--best-of", type=int, default=1)
    parser.add_argument("--cpu-threads", type=int, default=0)
    parser.add_argument("--num-workers", type=int, default=1)
    parser.add_argument("--vad-filter", action="store_true")
    parser.add_argument("--condition-previous-text", action="store_true")
    parser.add_argument("--source-label", required=True)
    parser.add_argument("--output-json", required=True)
    parser.add_argument("--keep-wav", action="store_true")
    parser.add_argument("--wav-path", default="")

    args = parser.parse_args()

    if args.wav_path:
        wav_path = args.wav_path
    else:
        fd, wav_path = tempfile.mkstemp(prefix="obs-track-", suffix=".wav")
        os.close(fd)

    try:
        stream_start_offset = get_audio_stream_start_offset(
            args.input_video,
            args.audio_stream_index
        )

        decode_audio_stream_to_wav(
            args.input_video,
            args.audio_stream_index,
            wav_path
        )

        wav_duration, wav_rms = get_wav_stats(wav_path)

        model_kwargs = {
            "device": args.device,
            "compute_type": args.compute_type,
            "cpu_threads": args.cpu_threads,
            "num_workers": args.num_workers,
        }

        if args.model_cache_dir:
            model_kwargs["download_root"] = args.model_cache_dir

        model = WhisperModel(args.model, **model_kwargs)

        segments, info = model.transcribe(
            wav_path,
            language="en",
            task="transcribe",
            beam_size=args.beam_size,
            best_of=args.best_of,
            vad_filter=args.vad_filter,
            vad_parameters={
                "min_silence_duration_ms": 500,
                "speech_pad_ms": 200,
            },
            condition_on_previous_text=args.condition_previous_text,
            word_timestamps=False,
            temperature=0.0,
        )

        out_segments = []

        for seg in segments:
            text = (seg.text or "").strip()
            if not text:
                continue

            start_seconds = float(seg.start or 0.0) + stream_start_offset
            end_seconds = float(seg.end or 0.0) + stream_start_offset

            if start_seconds < 0.0:
                start_seconds = 0.0

            if end_seconds < 0.0:
                end_seconds = 0.0

            out_segments.append({
                "Source": args.source_label,
                "StartText": fmt_time(start_seconds),
                "EndText": fmt_time(end_seconds),
                "StartSeconds": start_seconds,
                "EndSeconds": end_seconds,
                "Text": text,
                "AvgLogProb": getattr(seg, "avg_logprob", None),
                "NoSpeechProb": getattr(seg, "no_speech_prob", None),
                "CompressionRatio": getattr(seg, "compression_ratio", None),
            })

        payload = {
            "language": getattr(info, "language", "en"),
            "language_probability": getattr(info, "language_probability", None),
            "duration": getattr(info, "duration", None),
            "wav_duration": wav_duration,
            "wav_rms": wav_rms,
            "stream_start_offset": stream_start_offset,
            "segment_count": len(out_segments),
            "segments": out_segments,
        }

        with open(args.output_json, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False, indent=2)

    finally:
        if (not args.keep_wav) and wav_path and os.path.exists(wav_path):
            try:
                os.remove(wav_path)
            except OSError:
                pass


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise
'@

try {
    $pythonVersion = & $PythonExe --version 2>&1
    Write-Info "Using Python: $pythonVersion"

    & $PythonExe -c "import faster_whisper, av; print('faster-whisper and PyAV are available')"
    if ($LASTEXITCODE -ne 0) {
        throw "Required Python modules are missing. Install with: py -m pip install faster-whisper av"
    }

    $videoPath = Get-InputVideo

    if (-not (Test-Path -LiteralPath $VaultDir)) {
        New-Item -ItemType Directory -Force -Path $VaultDir | Out-Null
    }

    if (-not (Test-Path -LiteralPath $DebugDir)) {
        New-Item -ItemType Directory -Force -Path $DebugDir | Out-Null
    }

    $workDir = Join-Path ([System.IO.Path]::GetTempPath()) ("obs-transcript-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $workDir | Out-Null

    $workerPath = Join-Path $workDir "faster_whisper_obs_worker.py"
    Set-Content -LiteralPath $workerPath -Value $workerCode -Encoding UTF8

    $micJson = Join-Path $workDir "segments-Me.json"
    $desktopJson = Join-Path $workDir "segments-Them.json"
    $mixedJson = Join-Path $workDir "segments-Mixed.json"

    $micWav = Join-Path $workDir "audio-Me.wav"
    $desktopWav = Join-Path $workDir "audio-Them.wav"
    $mixedWav = Join-Path $workDir "audio-Mixed.wav"

    $outputMd = Join-Path $VaultDir (ConvertTo-SafeMarkdownFileName -VideoPath $videoPath)

    Write-Info "Processing: $videoPath"
    Write-Info "Model: $Model"
    Write-Info "Device: $Device"
    Write-Info "Compute type: $ComputeType"
    Write-Info ("VAD filter: {0}" -f (-not $NoVadFilter))
    Write-Info "Mic audio stream index: $MicAudioStreamIndex"
    Write-Info "Desktop audio stream index: $DesktopAudioStreamIndex"
    Write-Info "Mixed fallback stream index: $MixedAudioStreamIndex"
    Write-Info "Work dir: $workDir"

    $micResult = Run-TranscriptionWorker `
        -SourceLabel "Me" `
        -AudioStreamIndex $MicAudioStreamIndex `
        -VideoPath $videoPath `
        -WorkerPath $workerPath `
        -OutputJson $micJson `
        -OutputWav $micWav

    $desktopResult = Run-TranscriptionWorker `
        -SourceLabel "Them" `
        -AudioStreamIndex $DesktopAudioStreamIndex `
        -VideoPath $videoPath `
        -WorkerPath $workerPath `
        -OutputJson $desktopJson `
        -OutputWav $desktopWav

    Copy-Item -LiteralPath $micJson -Destination (Join-Path $DebugDir "segments-Me.json") -Force
    Copy-Item -LiteralPath $desktopJson -Destination (Join-Path $DebugDir "segments-Them.json") -Force

    if ($KeepTempFiles) {
        if (Test-Path -LiteralPath $micWav) {
            Copy-Item -LiteralPath $micWav -Destination (Join-Path $DebugDir "audio-Me.wav") -Force
        }

        if (Test-Path -LiteralPath $desktopWav) {
            Copy-Item -LiteralPath $desktopWav -Destination (Join-Path $DebugDir "audio-Them.wav") -Force
        }
    }

    $rawSegments = @()
    $rawSegments += @($micResult.Segments)
    $rawSegments += @($desktopResult.Segments)

    $allSegments = @(
        $rawSegments |
        Where-Object { $_ -and $_.Text -and $_.Text.Trim().Length -gt 0 } |
        ForEach-Object { Normalize-Segment -Segment $_ } |
        Where-Object { -not (Test-IsBadHallucination -Text $_.Text) } |
        Sort-Object StartSeconds, Source
    )

    $usedMixedFallback = $false

    if ((-not $DisableMixedFallback) -and (@($allSegments).Count -lt $MinimumSeparatedSegments)) {
        Write-Info ("Separated tracks produced only {0} usable segments. Trying mixed-track fallback." -f @($allSegments).Count)

        $mixedResult = Run-TranscriptionWorker `
            -SourceLabel "Mixed" `
            -AudioStreamIndex $MixedAudioStreamIndex `
            -VideoPath $videoPath `
            -WorkerPath $workerPath `
            -OutputJson $mixedJson `
            -OutputWav $mixedWav

        Copy-Item -LiteralPath $mixedJson -Destination (Join-Path $DebugDir "segments-Mixed.json") -Force

        if ($KeepTempFiles -and (Test-Path -LiteralPath $mixedWav)) {
            Copy-Item -LiteralPath $mixedWav -Destination (Join-Path $DebugDir "audio-Mixed.wav") -Force
        }

        $mixedSegments = @(
            @($mixedResult.Segments) |
            Where-Object { $_ -and $_.Text -and $_.Text.Trim().Length -gt 0 } |
            ForEach-Object { Normalize-Segment -Segment $_ } |
            Where-Object { -not (Test-IsBadHallucination -Text $_.Text) } |
            Sort-Object StartSeconds, Source
        )

        if (@($mixedSegments).Count -gt @($allSegments).Count) {
            $allSegments = $mixedSegments
            $usedMixedFallback = $true
            Write-Info ("Using mixed-track fallback with {0} usable segments." -f @($allSegments).Count)
        }
        else {
            Write-Info "Mixed-track fallback did not improve segment count."
        }
    }

    Write-Info ("Mic raw segments: {0}" -f @($micResult.Segments).Count)
    Write-Info ("Desktop raw segments: {0}" -f @($desktopResult.Segments).Count)
    Write-Info ("Usable final segments: {0}" -f @($allSegments).Count)

    $videoName = [System.IO.Path]::GetFileName($videoPath)
    $title = [System.IO.Path]::GetFileNameWithoutExtension($videoPath)
    $dateText = Get-Date -Format "yyyy-MM-dd"
    $modifiedText = Get-Date -Format "yyyy-MM-ddTHH:mm:sszzz"

    $mdLines = New-Object System.Collections.Generic.List[string]

    [void]$mdLines.Add("---")
    [void]$mdLines.Add("tags:")
    [void]$mdLines.Add("  - transcript")
    [void]$mdLines.Add("  - obs")
    [void]$mdLines.Add("  - faster-whisper")
    [void]$mdLines.Add("date: $dateText")
    [void]$mdLines.Add("source_video: $videoName")
    [void]$mdLines.Add("modified: $modifiedText")
    [void]$mdLines.Add("mixed_fallback_used: $usedMixedFallback")
    [void]$mdLines.Add("---")
    [void]$mdLines.Add("")
    [void]$mdLines.Add("# $title")
    [void]$mdLines.Add("")
    [void]$mdLines.Add("## Transcript")
    [void]$mdLines.Add("")

    foreach ($seg in $allSegments) {
        $timestamp = Format-TranscriptTime -Seconds ([double]$seg.StartSeconds)
        $source = [string]$seg.Source

        if ($usedMixedFallback) {
            $source = "Transcript"
        }

        $line = "[{0}] **{1}:** {2}" -f $timestamp, $source, $seg.Text
        [void]$mdLines.Add($line)
        [void]$mdLines.Add("")
    }

    Set-Content -LiteralPath $outputMd -Value $mdLines -Encoding UTF8

    Write-Info "Debug JSON copied to: $DebugDir"

    if ($KeepTempFiles) {
        Write-Info "Debug WAV files copied to: $DebugDir"
        Write-Info "Temp files kept at: $workDir"
    }
    else {
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    $timer.Stop()

    Write-Info ""
    Write-Info "Done."
    Write-Info "Markdown note: $outputMd"
    Write-Info ("Total processing time: {0:hh\:mm\:ss}" -f $timer.Elapsed)
}
catch {
    $timer.Stop()
    Write-Info ""
    Write-Info "ERROR:"
    Write-Info $_.Exception.Message
    Write-Info ("Total processing time before error: {0:hh\:mm\:ss}" -f $timer.Elapsed)
    exit 1
}
