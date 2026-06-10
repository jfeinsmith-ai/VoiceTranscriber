# VoiceTranscriber

Personal OBS recording transcription pipeline for generating raw transcripts and AI summaries into an Obsidian vault.

The watcher runs continuously, detects new OBS `.mkv` recordings, waits until each video file is stable, sends it through local faster-whisper transcription, and optionally calls the OpenAI API to create a structured summary note.

## Scripts

| File | Purpose |
| --- | --- |
| `Watch-ObsTranscripts-FasterWhisper-Production.ps1` | Long-running watcher that detects new OBS recordings and launches processing. |
| `Process-ObsTranscript-FasterWhisper-v4.ps1` | Extracts OBS audio tracks, transcribes locally with faster-whisper, merges segments, and writes the transcript note. |
| `summarize_transcript.py` | Uses the OpenAI API to turn a transcript note into structured Obsidian meeting notes. |

## Default Workflow

1. OBS records `.mkv` files to `C:\Users\jfein\Videos`.
2. The watcher detects a new `.mkv` and waits until the file stops changing.
3. The processor extracts the configured mic and desktop/system audio tracks.
4. faster-whisper transcribes the audio locally.
5. A raw transcript markdown file is written to the Obsidian transcript folder.
6. If summarization is enabled, the Python summarizer creates a structured summary note in the same folder.

## Default Paths

These scripts are currently written around this local layout:

| Item | Default path |
| --- | --- |
| Script folder | `C:\Scripts` |
| OBS recordings | `C:\Users\jfein\Videos` |
| Transcript output | `C:\Users\jfein\OneDrive\Documents\Obsidian\Personal\30 Resources\Transcripts` |
| Debug output | `C:\Scripts\debug-transcript` |

Most paths can be overridden with script parameters.

## Requirements

- Windows PowerShell
- Python with these packages:
  - `faster-whisper`
  - `av`
  - `openai`
- An `OPENAI_API_KEY` environment variable for summary generation
- OBS configured to record separate audio tracks

Install Python packages:

```powershell
py -m pip install faster-whisper av openai
```

Expected OBS audio stream layout:

| Stream | Audio |
| --- | --- |
| `0` | Mixed audio |
| `1` | Mic audio |
| `2` | Desktop/system audio |

## Manual Usage

Transcribe a specific recording:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Process-ObsTranscript-FasterWhisper-v4.ps1" `
  -InputVideo "C:\Users\jfein\Videos\example.mkv" `
  -MicAudioStreamIndex 1 `
  -DesktopAudioStreamIndex 2 `
  -NoVadFilter
```

Run the watcher with summarization enabled:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Watch-ObsTranscripts-FasterWhisper-Production.ps1" -EnableSummarization
```

Run the summarizer directly:

```powershell
py "C:\Scripts\summarize_transcript.py" --input "C:\path\to\transcript.md"
```

## Summary Filenames

The summarizer asks the OpenAI model to generate a YAML `title` field beginning with `Summary - `. It then uses that generated title as the output filename.

For example:

```yaml
title: "Summary - Project Planning Review"
```

creates:

```text
Summary - Project Planning Review.md
```

If a file with that name already exists, the summarizer appends a number such as `Summary - Project Planning Review 2.md`.

Passing `--output` overrides this behavior.

## Scheduled Autostart

The watcher is intended to run automatically at Windows logon through Task Scheduler.

Create the scheduled task:

```powershell
$Action = New-ScheduledTaskAction `
  -Execute "powershell.exe" `
  -Argument '-NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Watch-ObsTranscripts-FasterWhisper-Production.ps1"'

$Trigger = New-ScheduledTaskTrigger -AtLogOn

$Settings = New-ScheduledTaskSettingsSet `
  -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries `
  -ExecutionTimeLimit (New-TimeSpan -Hours 0)

Register-ScheduledTask `
  -TaskName "OBS Faster Whisper Transcript Watcher" `
  -Action $Action `
  -Trigger $Trigger `
  -Settings $Settings `
  -Description "Watches OBS recordings and generates faster-whisper transcripts"
```

To enable summary generation from the scheduled watcher, include `-EnableSummarization` in the scheduled task argument:

```powershell
-Argument '-NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Watch-ObsTranscripts-FasterWhisper-Production.ps1" -EnableSummarization'
```

## Updating Local Scripts

After pulling changes from this repository, copy the scripts into `C:\Scripts`:

```powershell
Copy-Item ".\Process-ObsTranscript-FasterWhisper-v4.ps1" "C:\Scripts\" -Force
Copy-Item ".\Watch-ObsTranscripts-FasterWhisper-Production.ps1" "C:\Scripts\" -Force
Copy-Item ".\summarize_transcript.py" "C:\Scripts\" -Force
```

## Notes

- The processor prints `Markdown note: <path>` when transcription succeeds. The watcher depends on that line to find the transcript for summarization.
- VAD filtering is disabled by default in the watcher because it can drop speech from separated OBS tracks.
- The processor includes a mixed-track fallback if separated-track transcription produces too little usable text.
- The raw transcript and summary are designed to be Obsidian-ready markdown notes.
