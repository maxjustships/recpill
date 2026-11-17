# RecPill ●

**Record any call on your computer into one audio file. Your mic and everything you hear, mixed together, saved locally. No bot joins the call.**

RecPill is a tiny recorder for Windows, Linux and (beta) macOS. Press a shortcut, talk, press stop, and you get one `.m4a` with both sides of the conversation. It follows your headset, speakers and Bluetooth earbuds as you plug and unplug them mid-call.

- **No bot in your meeting.** Nobody sees "Recorder joined". It listens on your machine, not in the call.
- **Works with any app.** Zoom, Meet, Teams, Telegram, WhatsApp, Discord, a browser tab, a phone call routed through your PC. If you can hear it, RecPill can record it.
- **Runs locally, no network.** Audio never leaves your computer. There is no account, no telemetry, no cloud.
- **Audio only.** No screen capture, no video, small files (about 0.7 MB per minute).
- **Free and open source** (MIT).

## Install

| OS | One line |
|---|---|
| **Windows 10/11** (PowerShell, no admin) | `irm https://github.com/maxjustships/recpill/releases/latest/download/install.ps1 \| iex` |
| **Linux** (PipeWire or PulseAudio) | `curl -fsSL https://github.com/maxjustships/recpill/releases/latest/download/install.sh \| sh` |
| **macOS 14.4+** (**beta, untested on real hardware**) | `curl -fsSL https://github.com/maxjustships/recpill/releases/latest/download/install.sh \| sh` |

Every installer downloads the release archive and verifies its SHA-256 against `SHA256SUMS` before installing anything. Nothing needs admin/root; Windows installs into `%LOCALAPPDATA%\RecPill`, Linux and macOS into `~/.local`.

Uninstall: Windows `irm https://github.com/maxjustships/recpill/releases/latest/download/uninstall.ps1 | iex`, Linux/macOS `curl -fsSL https://github.com/maxjustships/recpill/releases/latest/download/install.sh | sh -s -- --uninstall`. Your recordings are never deleted.

> **The binaries are not code-signed** (signing costs money; this is a free project). Windows SmartScreen may say "unknown publisher": choose *More info → Run anyway*. On macOS the installer fetches the binary with `curl`, which does not add the quarantine flag, so Gatekeeper normally stays quiet. Read the source, it is short, or build it yourself (see below).

## Use

**Windows**: Start menu → **Start recording** / **Stop recording** / **Toggle recording** (names follow your Windows language; Russian: «Старт записи», «Стоп записи», «Запись звонка»). Pin them, or search for them from PowerToys Run / Flow Launcher. A toast shows when recording starts and when the file is saved. Add `RECPILL_DESKTOP=1` before the install command to also get Desktop shortcuts.

**Linux**: `recpill start`, `recpill stop`, `recpill toggle` from a terminal, or the *Start recording / Stop recording / Toggle recording* entries the installer adds to your app launcher. Bind `recpill toggle` to a key in your window manager (Hyprland: `bind = SUPER, R, exec, recpill toggle`). Notifications go through `notify-send`.

**macOS (beta)**: `recpill start`, `recpill stop`, `recpill toggle`. Bind them with Shortcuts.app ("Run Shell Script") or Raycast/Alfred. The first run asks for microphone and "System Audio Recording" permission; if the file has no system sound, grant it to your terminal or launcher app in *System Settings → Privacy & Security*.

Recordings are named `YYYY-MM-DD_HH-MM-SS.m4a` (AAC, mono, 48 kHz, 96 kbit/s).

| | Default folder |
|---|---|
| Windows | `%USERPROFILE%\Music\RecPill` |
| Linux | `~/Music/RecPill` |
| macOS | `~/Music/RecPill` |

Change the folder with `output_dir=` in the config file, the `RECPILL_OUTPUT` environment variable, or `--output <folder>` on `start`.

Config file (all keys optional): Windows `%LOCALAPPDATA%\RecPill\config.ini`, Linux `~/.config/recpill/config.ini`, macOS `~/Library/Application Support/RecPill/config.ini`.

```ini
output_dir=D:\Calls        # where recordings go
max_hours=4                # automatic stop, protects you from forgetting
language=auto              # auto | en | ru  (messages; auto follows the OS)
notifications=on           # off = no toasts / notifications
```

`recpill status` (Linux, macOS) or `RecPill.exe status` (Windows, prints into a terminal) says whether a recording is running. Exit code 0 = recording.

## How it works

RecPill captures two things and mixes them on one clock:

1. **System sound**: Windows WASAPI loopback, Linux the default sink's monitor (via `parec`), macOS a Core Audio process tap.
2. **Your microphone.**

**It follows your devices.** The set of devices being recorded is re-checked about three times a second (Windows), on every PulseAudio/PipeWire event (Linux) or twice a second (macOS):

- The **default output** is always recorded. Switch from speakers to headphones mid-call and the recording follows.
- On Windows, **other outputs are picked up as soon as sound plays on them** and dropped again when idle (so a call app that plays on a non-default device is not missed).
- A device that vanishes (unplugged, disabled, Bluetooth dropped) just stops contributing; the recording continues and re-opens it if it comes back.
- Sources are summed on a wall-clock timeline, so a source that goes quiet never stretches or shifts the audio.

**The Bluetooth hands-free trick.** A Bluetooth headset has two modes: stereo (A2DP, good sound, no mic) and hands-free (HFP, mono phone quality, with mic). Merely *opening* the headset's microphone flips it into hands-free mode, and your music/video suddenly sounds like a phone call, or goes silent. So RecPill **never opens a Bluetooth microphone on its own**. It opens it only when another app (your call app) already has it open, which means the headset is already in call mode. Otherwise it records your default non-Bluetooth microphone (or the last wired/built-in mic it used). Result: recording never degrades the sound of your earbuds.

**Crash-safe.** While recording, audio is written to disk continuously (raw PCM on Windows/macOS, Matroska on Linux). If the app is killed or the machine loses power, the next `start`/`stop` recovers it into a normal `.m4a`. It stops by itself after `max_hours` and keeps the computer awake while recording.

## Limitations (read before relying on it)

- **Tell people you record.** See the privacy note below.
- **Windows**: tested on Windows 10 with real devices (Bluetooth earbuds, USB mic, speakers). Windows 11 should behave the same but has not been tried on a real machine by the author. DRM-protected video may play silently into the loopback.
- **Linux**: tested on PipeWire with `pipewire-pulse` (Arch). Plain PulseAudio uses the same `parec`/`pactl` interface but was not tried. Bluetooth handling on Linux relies on WirePlumber not switching profiles for the default (non-Bluetooth) mic: reasoned, not tested with Bluetooth hardware.
- **macOS: BETA, untested on real hardware.** It is built by GitHub Actions on `macos-latest` (compiles and passes the unit tests there) but nobody has run it on a Mac with audio yet. Needs macOS 14.4+ for system audio. Expect rough edges; bug reports are welcome.
- Output is **one mixed mono track**: you cannot separate "me" from "them" afterwards.
- Volume and mute: on Linux a muted or zero-volume sink is still recorded (checked on PipeWire); you capture what apps play, not what your EQ does afterwards. Not checked on other platforms.
- A system with several microphones records **one** at a time (the default one).
- No pause button, no Wayland/X11 global shortcut of its own (bind the command in your desktop environment).
- Windows 7/8 and 32-bit systems are not supported.

## Privacy and consent

RecPill records only when you press start, saves only to a folder on your computer and makes no network connections. That is the whole data story.

**Recording other people is regulated.** In many places you need everyone's consent, and some require it from all parties. Ask ("do you mind if I record this for my notes?") and respect a no. You are responsible for following the law where you and the other party are. This software is provided as is, without warranty (see `LICENSE`).

## RecPill Cloud (coming soon)

The recorder stays free and open source. A paid add-on is planned for people who want more than local files: cloud sync across devices, automatic upload to your own endpoint (S3/webhook), and transcripts. It is opt-in and the local app will never require it.

**[Join the waitlist → recpill.pages.dev](https://recpill.pages.dev)**

## Roadmap

- Android: mic/speakerphone mode only — Android 10+ blocks capturing the other side of VoIP/phone calls.
- Separate "me" / "them" tracks (optional stereo).
- A tray/menu-bar button with a visible red ● while recording.
- Signed builds once there is a budget for it.

## Build from source and test

| | Needs | Build | Unit tests |
|---|---|---|---|
| Windows | Windows 10/11, the .NET Framework `csc.exe` that ships with Windows | `powershell -File windows\build.ps1 -Zip` | `powershell -File windows\build.ps1 -Test` |
| Linux | Python 3.8+, `parec`/`pactl`, `ffmpeg`, `notify-send` | nothing to build (`linux/recpill.py`) | `python3 -m unittest discover -v linux/tests` |
| macOS | Xcode command line tools, macOS 14.4+ SDK | see `.github/workflows/build.yml` | `swiftc macos/Core.swift macos/Tests/main.swift -o t && ./t` |

Why these stacks: **Windows** is a single small C# file on NAudio (WASAPI loopback + Media Foundation AAC), which runs on the .NET Framework already on every Windows 10/11 and needs no ffmpeg and no installer runtime. **Linux** is one Python file over `parec` + `ffmpeg`: the same two commands work on PipeWire and PulseAudio, the packaging is `cp`, and the mixing logic stays unit-testable. **macOS** is one Swift file on Core Audio taps because that is the only no-extra-driver route to system audio.

The mixing, resampling and device-choice logic is covered by unit tests on all three platforms, and CI runs them on every push.

## License

MIT, see [LICENSE](LICENSE). Third-party components: [THIRD-PARTY.md](THIRD-PARTY.md).
