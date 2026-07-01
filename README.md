# WhisperJAV-Auto

Windows automation wrapper for WhisperJAV subtitle generation:

```text
video -> WhisperJAV Ensemble transcription -> DeepSeek Chinese translation -> same-name .srt
```

## Quick Start

1. Copy `config.example.json` to `config.json`.
2. Edit `config.json` for your local paths and DeepSeek settings.
3. Double-click `开启中文字幕自动处理.bat`.
4. Use `查看中文字幕处理状态.bat` to inspect progress.
5. Use `关闭中文字幕自动处理.bat` to stop the automation.

See [使用说明.md](./使用说明.md) for full Chinese documentation.

## Privacy

`config.json`, logs, process outputs, temporary work files, and failure lists are ignored by Git. Do not commit real API keys, local media paths, logs, or generated subtitles.
