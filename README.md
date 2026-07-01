# WhisperJAV-Auto

Windows automation wrapper for WhisperJAV subtitle generation:

```text
video -> WhisperJAV Ensemble transcription -> DeepSeek Chinese translation -> same-name .srt
```

This project is only an automation wrapper. The underlying transcription tool is WhisperJAV:

https://github.com/meizhong986/WhisperJAV

## Quick Start

1. Install and verify WhisperJAV first.
2. Copy `config.example.json` to `config.json`.
3. Edit `config.json` for your local video paths, work directory, WhisperJAV install directory, and DeepSeek settings.
4. Run `internal\Status-WhisperJAV-Auto.ps1` once to confirm the config can be loaded.
5. Double-click `开启中文字幕自动处理.bat`.
6. Use `查看中文字幕处理状态.bat` to inspect progress.
7. Use `关闭中文字幕自动处理.bat` to stop the automation.

See [使用说明.md](./使用说明.md) for full Chinese documentation.

## Privacy

`config.json`, logs, process outputs, temporary work files, and failure lists are ignored by Git. Do not commit real API keys, local media paths, logs, or generated subtitles.
