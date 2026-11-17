# Third-party components

## Windows build
- **NAudio 1.10.0** (WASAPI + Media Foundation wrappers), MIT License, Copyright (c) Mark Heath.
  https://github.com/naudio/NAudio — shipped unmodified as `NAudio.dll`.

## Linux build
- Uses the system's `parec`/`pactl` (PulseAudio / pipewire-pulse), `ffmpeg` and `notify-send`. Nothing is bundled.

## macOS build
- Uses Apple system frameworks only (CoreAudio, AVFoundation).
