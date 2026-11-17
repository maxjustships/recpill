#!/usr/bin/env python3
"""RecPill for Linux: record the microphone + everything the computer plays into one audio-only .m4a.

    recpill start | stop | toggle [--quiet] [--output DIR]
    recpill status | doctor | version

Stack: `parec` (PulseAudio / PipeWire-pulse) captures the default sink monitor and the default microphone,
a small mixer puts both on one wall-clock timeline, `ffmpeg` encodes AAC. No network, no root, no daemon.
It follows default-device changes (speakers <-> headset <-> Bluetooth) while recording.
"""
import array
import fcntl
import json
import os
import shutil
import signal
import subprocess
import sys
import threading
import time
from operator import add

VERSION = "0.1.0"
RATE = 48000
APP = "RecPill"


# --------------------------------------------------------------------------- strings
STRINGS = {
    "rec_title": ("Recording \u25cf", "\u0417\u0430\u043f\u0438\u0441\u044c \u0438\u0434\u0451\u0442 \u25cf"),
    "already": ("Already recording \u25cf", "\u0417\u0430\u043f\u0438\u0441\u044c \u0443\u0436\u0435 \u0438\u0434\u0451\u0442 \u25cf"),
    "nostart": ("Recording did NOT start", "\u0417\u0430\u043f\u0438\u0441\u044c \u041d\u0415 \u043d\u0430\u0447\u0430\u043b\u0430\u0441\u044c"),
    "nostart_body": ("Could not open any microphone or system sound.", "\u041d\u0435 \u0443\u0434\u0430\u043b\u043e\u0441\u044c \u043e\u0442\u043a\u0440\u044b\u0442\u044c \u043d\u0438 \u043c\u0438\u043a\u0440\u043e\u0444\u043e\u043d, \u043d\u0438 \u0437\u0432\u0443\u043a \u043a\u043e\u043c\u043f\u044c\u044e\u0442\u0435\u0440\u0430."),
    "saved": ("Recording saved \u25a0", "\u0417\u0430\u043f\u0438\u0441\u044c \u0441\u043e\u0445\u0440\u0430\u043d\u0435\u043d\u0430 \u25a0"),
    "auto": ("Recording stopped automatically \u25a0", "\u0417\u0430\u043f\u0438\u0441\u044c \u043e\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u0430 \u0430\u0432\u0442\u043e\u043c\u0430\u0442\u0438\u0447\u0435\u0441\u043a\u0438 \u25a0"),
    "savefail": ("Recording was not saved", "\u0417\u0430\u043f\u0438\u0441\u044c \u043d\u0435 \u0441\u043e\u0445\u0440\u0430\u043d\u0438\u043b\u0430\u0441\u044c"),
    "notrec": ("Not recording", "\u0417\u0430\u043f\u0438\u0441\u044c \u043d\u0435 \u0438\u0434\u0451\u0442"),
    "notrec_body": ("Nothing to stop.", "\u041d\u0435\u0447\u0435\u0433\u043e \u043e\u0441\u0442\u0430\u043d\u0430\u0432\u043b\u0438\u0432\u0430\u0442\u044c."),
    "recovered": (" (recovered)", " (\u0432\u043e\u0441\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u0430)"),
    "no_mic": ("no microphone", "\u043c\u0438\u043a\u0440\u043e\u0444\u043e\u043d \u043d\u0435 \u043d\u0430\u0439\u0434\u0435\u043d"),
    "no_sound": ("no system sound", "\u0437\u0432\u0443\u043a \u043a\u043e\u043c\u043f\u044c\u044e\u0442\u0435\u0440\u0430 \u043d\u0435 \u043d\u0430\u0439\u0434\u0435\u043d"),
    "h": ("h", "\u0447"), "min": ("min", "\u043c\u0438\u043d"), "s": ("s", "\u0441"),
}
_lang = None


def lang_index():
    if _lang is not None:
        return _lang
    for var in ("LC_ALL", "LC_MESSAGES", "LANG"):
        v = os.environ.get(var)
        if v:
            return 1 if v.lower().startswith("ru") else 0
    return 0


def T(key):
    return STRINGS[key][lang_index()]


def dur(seconds):
    s = int(seconds)
    h, m, sec = s // 3600, (s % 3600) // 60, s % 60
    if h:
        return "%d %s %d %s" % (h, T("h"), m, T("min"))
    if m:
        return "%d %s %d %s" % (m, T("min"), sec, T("s"))
    return "%d %s" % (sec, T("s"))


# --------------------------------------------------------------------------- paths + config
def _xdg(var, default):
    return os.environ.get(var) or os.path.expanduser(default)


CONFIG_DIR = os.path.join(_xdg("XDG_CONFIG_HOME", "~/.config"), "recpill")
STATE_DIR = os.path.join(_xdg("XDG_STATE_HOME", "~/.local/state"), "recpill")
TMP_DIR = os.path.join(STATE_DIR, "tmp")
LOG_FILE = os.path.join(STATE_DIR, "recpill.log")
TOGGLE_LOG = os.path.join(STATE_DIR, "toggle.log")
RUN_DIR = os.path.join(os.environ["XDG_RUNTIME_DIR"], "recpill") if os.environ.get("XDG_RUNTIME_DIR") else "/tmp/recpill-%d" % os.getuid()
LOCK_FILE = os.path.join(RUN_DIR, "lock")
PID_FILE = os.path.join(RUN_DIR, "pid")
CONFIG_FILE = os.path.join(CONFIG_DIR, "config.ini")


def parse_config(text):
    """key=value lines; '#' or ';' comments; keys are case-insensitive; values may be quoted."""
    d = {}
    for raw in (text or "").splitlines():
        line = raw.strip().lstrip("\ufeff")
        if not line or line[0] in "#;" or "=" not in line:
            continue
        k, v = line.split("=", 1)
        k, v = k.strip().lower(), v.strip()
        if len(v) >= 2 and v[0] == '"' and v[-1] == '"':
            v = v[1:-1]
        if k:
            d[k] = v
    return d


def default_output_dir():
    music = None
    try:
        music = subprocess.run(["xdg-user-dir", "MUSIC"], capture_output=True, text=True, timeout=3).stdout.strip()
    except Exception:
        pass
    if not music or music == os.path.expanduser("~"):
        music = os.path.expanduser("~/Music")
    return os.path.join(music, "RecPill")


class Settings:
    def __init__(self, output_flag=None, quiet=False):
        global _lang
        cfg = {}
        try:
            with open(CONFIG_FILE, encoding="utf-8") as f:
                cfg = parse_config(f.read())
        except OSError:
            pass
        out = output_flag or os.environ.get("RECPILL_OUTPUT") or cfg.get("output_dir") or default_output_dir()
        self.output_dir = os.path.abspath(os.path.expandvars(os.path.expanduser(out)))
        try:
            self.max_hours = float(cfg.get("max_hours", "4"))
        except ValueError:
            self.max_hours = 4.0
        if self.max_hours <= 0:
            self.max_hours = 4.0
        self.quiet = quiet or cfg.get("notifications", "on").lower() in ("0", "off", "false", "no")
        l = cfg.get("language", "auto").lower()
        if l == "ru":
            _lang = 1
        elif l == "en":
            _lang = 0


def log(msg):
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        if os.path.exists(LOG_FILE) and os.path.getsize(LOG_FILE) > 2000000:
            os.remove(LOG_FILE)
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(time.strftime("%Y-%m-%dT%H:%M:%S ") + msg + "\n")
    except OSError:
        pass


def toggle_log(msg):
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(TOGGLE_LOG, "a", encoding="utf-8") as f:
            f.write(time.strftime("%Y-%m-%dT%H:%M:%S ") + msg + "\n")
    except OSError:
        pass


ICON = "audio-input-microphone"


def notify(settings, title, body="", seconds=4):
    log("notify: %s | %s" % (title, body))
    if settings is not None and settings.quiet:
        return
    nb = shutil.which("notify-send")
    if not nb:
        return
    icon = ICON
    for p in (os.path.expanduser("~/.local/share/icons/hicolor/128x128/apps/recpill.png"),):
        if os.path.exists(p):
            icon = p
    try:
        subprocess.Popen([nb, "-a", APP, "-i", icon, "-t", str(seconds * 1000),
                          "-h", "string:x-canonical-private-synchronous:recpill", "-h", "boolean:suppress-sound:true", title, body],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        pass


# --------------------------------------------------------------------------- mixer
class Track:
    __slots__ = ("pos", "started", "resyncs")

    def __init__(self):
        self.pos = 0
        self.started = False
        self.resyncs = 0


def _clip_to_bytes(chunk):
    """int sums -> clipped little-endian s16 bytes."""
    if chunk and (max(chunk) > 32767 or min(chunk) < -32768):
        out = array.array("h", [32767 if v > 32767 else -32768 if v < -32768 else v for v in chunk])
    else:
        out = array.array("h", chunk)
    if sys.byteorder == "big":
        out.byteswap()
    return out.tobytes()


class Mixer:
    """All sources add their samples onto one wall-clock timeline; a writer flushes it one second behind "now".
    A source that goes quiet or disappears simply stops adding."""

    def __init__(self, write, rate=RATE, clock=time.monotonic):
        self.rate = rate
        self.N = rate * 8
        self.slack = rate // 4
        self.acc = array.array("i", bytes(4 * self.N))
        self.write = write
        self.clock = clock
        self.t0 = clock()
        self.lock = threading.Lock()
        self.skipped = 0
        self.last_now = 0
        self.flushed = 0
        self.failed = None
        self._stop = threading.Event()
        self._th = None

    @property
    def seconds(self):
        return self.flushed / float(self.rate)

    def _now(self):
        return int((self.clock() - self.t0) * self.rate) - self.skipped

    def start(self):
        self._th = threading.Thread(target=self._run, daemon=True)
        self._th.start()

    def add(self, track, samples):
        """samples: array('h') of mono samples at self.rate."""
        n = len(samples)
        if n == 0:
            return
        with self.lock:
            target = self._now() - n
            if not track.started or track.pos < target - self.slack or track.pos > target + self.slack:
                if track.started:
                    track.resyncs += 1
                track.pos, track.started = target, True
            p = track.pos
            off = min(n, self.flushed - p) if p < self.flushed else 0
            if off < n and p + n - self.flushed < self.N:
                self._mix(p + off, samples[off:] if off else samples)
            track.pos = p + n

    def _mix(self, start, samples):
        N, acc = self.N, self.acc
        i = start % N
        n = len(samples)
        first = min(n, N - i)
        acc[i:i + first] = array.array("i", map(add, acc[i:i + first], samples[:first]))
        if first < n:
            rest = n - first
            acc[0:rest] = array.array("i", map(add, acc[0:rest], samples[first:]))

    def _take(self, start, count):
        N, acc = self.N, self.acc
        a = start % N
        first = min(count, N - a)
        chunk = acc[a:a + first]
        acc[a:a + first] = array.array("i", bytes(4 * first))
        if first < count:
            rest = count - first
            chunk += acc[0:rest]
            acc[0:rest] = array.array("i", bytes(4 * rest))
        return chunk

    def flush(self, margin):
        """Write everything older than `margin` samples before "now"."""
        with self.lock:
            now = self._now()
            if now - self.last_now > 5 * self.rate:  # machine slept: cut the gap
                self.skipped += now - self.last_now - self.rate // 4
                now = self._now()
            self.last_now = now
            count = min(now - margin - self.flushed, self.N)
            if count <= 0:
                return
            chunk = self._take(self.flushed, count)
            self.flushed += count
        self.write(_clip_to_bytes(chunk))

    def _run(self):
        while not self._stop.wait(0.2):
            try:
                self.flush(self.rate)
            except Exception as e:  # noqa: BLE001
                self.failed = str(e)
                return

    def finish(self):
        self._stop.set()
        if self._th:
            self._th.join(3)
        try:
            self.flush(0)
        except Exception as e:  # noqa: BLE001
            log("final flush: %s" % e)


# --------------------------------------------------------------------------- pulse helpers
def pactl(*args, timeout=4):
    env = dict(os.environ, LC_ALL="C")
    try:
        r = subprocess.run(["pactl"] + list(args), capture_output=True, text=True, timeout=timeout, env=env)
        return r.stdout.strip() if r.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        return None


def pactl_json(*args):
    out = pactl("--format=json", *args)
    try:
        return json.loads(out) if out else []
    except ValueError:
        return []


def is_bluez(name):
    return name.startswith("bluez_") or ".bluez" in name


def pick_mic(default_source, sources, bt_in_use, memo=None):
    """Choose ONE microphone. `sources`: names of all non-monitor sources.
    A Bluetooth hands-free mic is used only if a call app already has it open: opening it ourselves while idle
    flips the earbuds into headset mode and the stereo sound is gone. Returns (name or None, reason)."""
    if default_source and not default_source.endswith(".monitor"):
        if not is_bluez(default_source):
            return default_source, "default mic"
        if bt_in_use(default_source):
            return default_source, "bluetooth mic is in use by a call app"
    for s in sources:
        if is_bluez(s) and bt_in_use(s):
            return s, "bluetooth mic is in use by a call app"
    if memo and memo in sources and not is_bluez(memo):
        return memo, "default mic is an idle bluetooth mic -> last used wired mic"
    for s in sources:
        if not is_bluez(s):
            return s, "first non-bluetooth mic"
    if sources:
        return None, "only an idle bluetooth mic exists; not opening it (it would silence the earbuds)"
    return None, "no microphone found"


class Capture:
    """One `parec` process feeding one Track of the mixer."""

    def __init__(self, mixer, device, kind):
        self.mixer, self.device, self.kind = mixer, device, kind
        self.track = Track()
        self.proc = None
        self.dead = False
        self.peak = 0
        self.frames = 0
        self.last_data = time.monotonic()

    def start(self):
        self.proc = subprocess.Popen(
            ["parec", "-d", self.device, "--rate=%d" % RATE, "--channels=1", "--format=s16le",
             "--latency-msec=20", "--client-name=" + APP, "--stream-name=%s %s" % (APP, self.kind)],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        threading.Thread(target=self._run, daemon=True).start()

    def _run(self):
        fd = self.proc.stdout.fileno()
        buf = b""
        try:
            while True:
                data = os.read(fd, 8192)
                if not data:
                    break
                buf += data
                n = len(buf) // 2 * 2
                if not n:
                    continue
                samples = array.array("h")
                samples.frombytes(buf[:n])
                buf = buf[n:]
                if sys.byteorder == "big":
                    samples.byteswap()
                pk = max(max(samples), -min(samples))
                if pk > self.peak:
                    self.peak = pk
                self.frames += len(samples)
                self.last_data = time.monotonic()
                self.mixer.add(self.track, samples)
        except Exception as e:  # noqa: BLE001
            log("capture %s: %s" % (self.device, e))
        finally:
            self.dead = True

    def stop(self):
        try:
            if self.proc and self.proc.poll() is None:
                self.proc.terminate()
        except OSError:
            pass

    def db(self):
        import math
        return "-inf" if self.peak <= 0 else "%d dB" % round(20 * math.log10(self.peak / 32768.0))


class Devices:
    """Keeps the set of running captures equal to: default sink monitor + chosen microphone."""

    def __init__(self, mixer):
        self.mixer = mixer
        self.caps = {}
        self.backoff = {}
        self.descr = {}
        self.last_note = ""
        self.closed = []
        self.changed = threading.Event()
        self.memo_file = os.path.join(STATE_DIR, "last-mic.txt")

    def _describe_all(self):
        for kind in ("sinks", "sources"):
            for d in pactl_json("list", kind):
                self.descr[d.get("name")] = d.get("description") or d.get("name")

    def name(self, dev):
        if dev not in self.descr:
            self._describe_all()
        return self.descr.get(dev, dev)

    def bt_in_use(self, source_name):
        idx = {d.get("name"): d.get("index") for d in pactl_json("list", "sources")}
        want = idx.get(source_name)
        if want is None:
            return False
        for o in pactl_json("list", "source-outputs"):
            props = o.get("properties") or {}
            if o.get("source") == want and props.get("application.name") != APP:
                return True
        return False

    def wanted(self):
        sink = pactl("get-default-sink")
        src = pactl("get-default-source")
        srcs = [d.get("name") for d in pactl_json("list", "sources") if not (d.get("name") or "").endswith(".monitor")]
        memo = None
        try:
            with open(self.memo_file) as f:
                memo = f.read().strip()
        except OSError:
            pass
        mic, why = pick_mic(src, srcs, self.bt_in_use, memo)
        if mic and not is_bluez(mic):
            try:
                if memo != mic:
                    os.makedirs(STATE_DIR, exist_ok=True)
                    with open(self.memo_file, "w") as f:
                        f.write(mic)
            except OSError:
                pass
        want = {}
        if sink:
            want[sink + ".monitor"] = "output"
        if mic:
            want[mic] = "mic"
        note = "mic: %s (%s)" % (mic or "none", why)
        if note != self.last_note:
            log(note)
            self.last_note = note
        return want

    def reconcile(self):
        for dev, c in list(self.caps.items()):
            if c.dead:
                log("lost %s '%s'" % (c.kind, self.name(dev)))
                self.backoff[dev] = time.monotonic() + 2
                self.closed.append(c)
                del self.caps[dev]
        want = self.wanted()
        for dev, c in list(self.caps.items()):
            if dev not in want:
                log("close %s '%s'" % (c.kind, self.name(dev)))
                c.stop()
                self.closed.append(c)
                del self.caps[dev]
        for dev, kind in want.items():
            if dev in self.caps or time.monotonic() < self.backoff.get(dev, 0):
                continue
            c = Capture(self.mixer, dev, kind)
            try:
                c.start()
                self.caps[dev] = c
                log("open %s '%s'" % (kind, self.name(dev)))
            except OSError as e:
                self.backoff[dev] = time.monotonic() + 5
                log("cannot open %s '%s': %s" % (kind, dev, e))

    def describe(self):
        mic = [self.name(d) for d, c in self.caps.items() if c.kind == "mic"]
        out = [self.name(d).replace("Monitor of ", "") for d, c in self.caps.items() if c.kind == "output"]
        return "%s + %s" % (mic[0] if mic else T("no_mic"), ", ".join(out) if out else T("no_sound"))

    def levels(self):
        s = "; ".join("%s '%s' %s" % (c.kind, self.name(d), c.db()) for d, c in self.caps.items())
        for c in self.caps.values():
            c.peak = 0
        return s

    def stats(self):
        everything = list(self.caps.values()) + self.closed
        return "; ".join("%s '%s' frames=%d resyncs=%d" % (c.kind, self.name(c.device), c.frames, c.track.resyncs) for c in everything)

    def stop_all(self):
        for c in self.caps.values():
            c.stop()
        for c in self.caps.values():
            try:
                c.proc.wait(timeout=2)
            except Exception:  # noqa: BLE001
                try:
                    c.proc.kill()
                except OSError:
                    pass
        self.closed.extend(self.caps.values())
        self.caps = {}

    def watch(self):
        """`pactl subscribe` wakes the main loop the moment defaults or devices change."""
        def run():
            while True:
                try:
                    p = subprocess.Popen(["pactl", "subscribe"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                         text=True, env=dict(os.environ, LC_ALL="C"))
                    for line in p.stdout:
                        if " on server" in line or " on sink #" in line or " on source #" in line or " on source-output #" in line:
                            self.changed.set()
                    p.wait()
                except OSError:
                    pass
                time.sleep(2)
        threading.Thread(target=run, daemon=True).start()


# --------------------------------------------------------------------------- encoding
def ffmpeg_bin():
    return shutil.which("ffmpeg")


def good(path):
    return os.path.exists(path) and os.path.getsize(path) > 500


def finalize(mka, name, settings):
    """Remux the crash-safe Matroska file into the final .m4a. Falls back to keeping the .mka."""
    os.makedirs(settings.output_dir, exist_ok=True)
    final = os.path.join(settings.output_dir, name + ".m4a")
    if os.path.exists(final):
        final = os.path.join(settings.output_dir, "%s_%s.m4a" % (name, time.strftime("%H%M%S")))
    tmp_out = os.path.join(TMP_DIR, name + ".m4a")
    r = subprocess.run([ffmpeg_bin() or "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", mka, "-c", "copy",
                        "-movflags", "+faststart", tmp_out], capture_output=True, text=True)
    if r.returncode == 0 and good(tmp_out):
        shutil.move(tmp_out, final)
        os.remove(mka)
        return final
    log("remux failed: %s" % r.stderr.strip())
    keep = os.path.join(settings.output_dir, name + ".mka")
    try:
        shutil.move(mka, keep)
        return keep
    except OSError as e:
        log("could not keep %s: %s" % (mka, e))
        return None


def recover(settings):
    last = None
    try:
        for f in sorted(os.listdir(TMP_DIR)):
            if not f.endswith(".mka"):
                continue
            p = os.path.join(TMP_DIR, f)
            if os.path.getsize(p) < 4000:
                os.remove(p)
                continue
            out = finalize(p, f[:-4], settings)
            if out:
                last = out
                toggle_log("STOP %s (recovered)" % out)
                log("recovered %s" % out)
    except OSError as e:
        log("recover error: %s" % e)
    return last


# --------------------------------------------------------------------------- the recorder process
def is_running():
    os.makedirs(RUN_DIR, exist_ok=True)
    fd = os.open(LOCK_FILE, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(fd, fcntl.LOCK_UN)
        return False
    except OSError:
        return True
    finally:
        os.close(fd)


def run_recorder(settings):
    """The long-running part (started detached by `start`). Holds the lock for its whole life."""
    os.makedirs(RUN_DIR, exist_ok=True)
    os.makedirs(TMP_DIR, exist_ok=True)
    lock_fd = os.open(LOCK_FILE, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        notify(settings, T("already"))
        return 0
    if not ffmpeg_bin() or not shutil.which("parec") or not shutil.which("pactl"):
        notify(settings, T("nostart"), "ffmpeg, parec and pactl are required (run: recpill doctor)")
        return 1
    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *a: stop.set())
    signal.signal(signal.SIGINT, lambda *a: stop.set())
    recover(settings)

    name = time.strftime("%Y-%m-%d_%H-%M-%S")
    mka = os.path.join(TMP_DIR, name + ".mka")
    enc = subprocess.Popen([ffmpeg_bin(), "-hide_banner", "-loglevel", "error", "-y", "-f", "s16le", "-ar", str(RATE),
                            "-ac", "1", "-i", "pipe:0", "-c:a", "aac", "-b:a", "96k", mka],
                           stdin=subprocess.PIPE, stderr=subprocess.PIPE)

    def write(b):
        enc.stdin.write(b)
        enc.stdin.flush()

    mixer = Mixer(write)
    dev = Devices(mixer)
    dev.reconcile()
    if not dev.caps:
        log("start failed: no audio device could be opened")
        notify(settings, T("nostart"), T("nostart_body"), 8)
        enc.kill()
        return 1
    mixer.start()
    dev.watch()
    inhibit = None
    if shutil.which("systemd-inhibit"):
        try:
            inhibit = subprocess.Popen(["systemd-inhibit", "--what=sleep", "--who=" + APP, "--why=Recording a call",
                                        "--mode=block", "sleep", "infinity"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError:
            pass
    with open(PID_FILE, "w") as f:
        f.write(str(os.getpid()))
    toggle_log("START " + name)
    log("START %s | %s | output %s" % (name, dev.describe(), settings.output_dir))
    notify(settings, T("rec_title"), dev.describe(), 6)

    t0 = time.monotonic()
    auto = False
    n = 0
    while not stop.is_set():
        woke = dev.changed.wait(1.0)
        if stop.is_set():
            break
        if woke:
            time.sleep(0.15)  # default changes arrive in bursts
            dev.changed.clear()
        n += 1
        try:
            if woke or n % 2 == 0:
                dev.reconcile()
        except Exception as e:  # noqa: BLE001
            log("reconcile error: %s" % e)
        if n % 30 == 0:
            log("levels " + dev.levels())
        if mixer.failed:
            log("writer failed: %s" % mixer.failed)
            break
        if enc.poll() is not None:
            log("encoder exited: %s" % enc.stderr.read().decode(errors="replace"))
            break
        if time.monotonic() - t0 > settings.max_hours * 3600:
            auto = True
            break

    dev.stop_all()
    mixer.finish()
    try:
        enc.stdin.close()
    except OSError:
        pass
    try:
        enc.wait(timeout=60)
    except subprocess.TimeoutExpired:
        enc.kill()
    if inhibit:
        inhibit.terminate()
    log("captured %s | %s" % (dur(mixer.seconds), dev.stats()))
    final = finalize(mka, name, settings) if good(mka) else None
    if final:
        toggle_log("STOP %s %s" % (final, time.strftime("%H:%M:%S", time.gmtime(int(mixer.seconds)))))
        notify(settings, T("auto") if auto else T("saved"), "%s \u00b7 %s" % (os.path.basename(final), dur(mixer.seconds)), 8)
    else:
        toggle_log("STOP FAILED " + mka)
        notify(settings, T("savefail"), mka, 20)
    try:
        os.remove(PID_FILE)
    except OSError:
        pass
    return 0 if final else 1


# --------------------------------------------------------------------------- commands
def cmd_start(settings, passthrough):
    if is_running():
        notify(settings, T("already"), "", 4)
        print(T("already"))
        return 0
    os.makedirs(STATE_DIR, exist_ok=True)
    os.makedirs(RUN_DIR, exist_ok=True)
    try:
        os.remove(PID_FILE)  # stale file from a crashed run
    except OSError:
        pass
    logf = open(LOG_FILE, "a")
    child = subprocess.Popen([sys.executable, os.path.abspath(__file__), "_run"] + passthrough,
                             stdin=subprocess.DEVNULL, stdout=logf, stderr=logf, start_new_session=True)
    for _ in range(80):  # up to 8 s for the recorder to come up
        time.sleep(0.1)
        if child.poll() is not None:
            print(T("nostart"), file=sys.stderr)
            return child.returncode or 1
        if os.path.exists(PID_FILE) and is_running():
            print(T("rec_title") + " -> " + settings.output_dir)
            return 0
    return 0


def cmd_stop(settings):
    if not is_running():
        rec = recover(settings)
        if rec:
            notify(settings, T("saved"), os.path.basename(rec) + T("recovered"), 8)
            print(rec)
        else:
            notify(settings, T("notrec"), T("notrec_body"), 3)
            print(T("notrec"))
        return 0
    pid = None
    try:
        with open(PID_FILE) as f:
            pid = int(f.read().strip())
        os.kill(pid, signal.SIGTERM)
    except (OSError, ValueError) as e:
        log("stop: cannot signal recorder: %s" % e)
    t0 = time.monotonic()
    while is_running() and time.monotonic() - t0 < 180:
        time.sleep(0.25)
    if is_running():
        log("stop: recorder did not exit in 180 s, killing it")
        try:
            if pid:
                os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
        time.sleep(0.5)
        rec = recover(settings)
        notify(settings, T("saved") if rec else T("savefail"), os.path.basename(rec) if rec else "see " + LOG_FILE, 8)
    else:
        print("stopped")
    return 0


def cmd_status(settings):
    run = is_running()
    last = ""
    try:
        with open(TOGGLE_LOG, encoding="utf-8") as f:
            lines = f.read().splitlines()
            last = lines[-1] if lines else ""
    except OSError:
        pass
    print("recording" if run else "idle")
    print("output: " + settings.output_dir)
    print("last: " + last)
    return 0 if run else 1


def cmd_doctor(settings):
    ok = True
    for tool, why in (("parec", "capture (package pulseaudio-utils / libpulse)"), ("pactl", "device lookup (same package)"),
                      ("ffmpeg", "AAC encoding"), ("notify-send", "notifications (libnotify) - optional"),
                      ("systemd-inhibit", "keeps the laptop awake while recording - optional")):
        p = shutil.which(tool)
        print("%-16s %s" % (tool, p or "MISSING - " + why))
        if not p and "optional" not in why:
            ok = False
    print("sink:   ", pactl("get-default-sink"))
    print("source: ", pactl("get-default-source"))
    print("server: ", (pactl("info") or "").split("Server Name:")[-1].split("\n")[0].strip())
    print("output: ", settings.output_dir)
    return 0 if ok else 1


def main(argv):
    args = argv[1:]
    quiet = False
    output = None
    passthrough = []
    rest = []
    i = 0
    while i < len(args):
        a = args[i]
        if a in ("--quiet", "-quiet", "-q"):
            quiet = True
            passthrough.append("--quiet")
        elif a in ("--output", "-o") and i + 1 < len(args):
            output = args[i + 1]
            passthrough += ["--output", output]
            i += 1
        elif a.startswith("--output="):
            output = a.split("=", 1)[1]
            passthrough.append(a)
        else:
            rest.append(a)
        i += 1
    mode = rest[0] if rest else "toggle"
    settings = Settings(output, quiet)
    if mode in ("version", "--version", "-v"):
        print("RecPill %s" % VERSION)
        return 0
    if mode in ("help", "--help", "-h"):
        print(__doc__)
        return 0
    if mode == "status":
        return cmd_status(settings)
    if mode == "doctor":
        return cmd_doctor(settings)
    if mode == "_run":
        return run_recorder(settings)
    if mode == "toggle":
        mode = "stop" if is_running() else "start"
    if mode == "start":
        return cmd_start(settings, passthrough)
    if mode == "stop":
        return cmd_stop(settings)
    print("Unknown command '%s'. Try: start, stop, toggle, status, doctor." % mode, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
