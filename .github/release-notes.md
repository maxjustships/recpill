## RecPill v0.1.0 ●

First public release. Records your microphone + everything the computer plays into one audio-only `.m4a`, locally, with start/stop/toggle shortcuts. No bot joins your call.

**Install**

- Windows 10/11 (PowerShell, no admin): `irm https://github.com/maxjustships/recpill/releases/latest/download/install.ps1 | iex`
- Linux (PipeWire/PulseAudio): `curl -fsSL https://github.com/maxjustships/recpill/releases/latest/download/install.sh | sh`
- macOS 14.4+ (**beta**): same line as Linux.

**Status**

- Windows: working, tested on Windows 10 with real devices (speakers, USB mic, Bluetooth earbuds, switching mid-recording). Windows 11 not tried on a real machine.
- Linux: working, tested on Arch + PipeWire (default-device switching included). Plain PulseAudio and Bluetooth not tested here.
- macOS: **beta, untested on real hardware.** It is built and unit-tested by GitHub Actions, but nobody has run it on a Mac yet.

**Unsigned binaries.** Nothing here is code-signed. Windows SmartScreen may warn ("More info → Run anyway"). The installers verify the SHA-256 in `SHA256SUMS` before installing.

**Recording people needs their consent** in many places. Read the privacy note in the README.

Files: `RecPill-win-x64.zip`, `recpill-linux.tar.gz`, `recpill-macos.tar.gz` (beta), `install.ps1`, `uninstall.ps1`, `install.sh`, `SHA256SUMS`.
