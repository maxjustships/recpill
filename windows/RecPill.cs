// RecPill for Windows: an audio-only call recorder.
// Mixes the microphone + everything the computer plays (WASAPI loopback) into one mono .m4a (AAC via Media Foundation).
// Follows device changes while recording. Never opens an idle Bluetooth hands-free mic
// (opening it flips earbuds into "headset" mode and the stereo output goes silent).
//
//   RecPill.exe start | stop | toggle [-quiet] [--output <folder>]
//   RecPill.exe status | version
//
// Developer commands (used by the test scripts):
//   RecPill.exe diag <seconds> <outfile>      state + peak meters
//   RecPill.exe say <text> [device substring] short TTS test phrase
//   RecPill.exe setdefault <device substring> [comm|all]   switch the default device
//   RecPill.exe setvisible <device substring> <0|1>        disable/enable a device
//   RecPill.exe holdmic <device substring> <seconds>       keep a mic open like a call app would
//
// Build: windows\build.ps1 (uses the csc.exe that ships with Windows; needs NAudio.dll 1.10 from NuGet).
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32;
using NAudio.CoreAudioApi;
using NAudio.CoreAudioApi.Interfaces;
using NAudio.MediaFoundation;
using NAudio.Wave;
using RecPill;

static class App
{
    public const int RATE = 48000;
    public const string Version = "0.1.0";
    const string MutexName = "Local\\RecPill.Running";
    const string StopName = "Local\\RecPill.Stop";
    const string AppId = "RecPill.Recorder";

    public static string Root, CallsDir, TmpDir;
    static double MaxHours = 4.0;
    static bool Quiet;
    static string OutputFlag;

    [DllImport("kernel32.dll")] static extern uint SetThreadExecutionState(uint f);
    [DllImport("kernel32.dll")] static extern bool AttachConsole(int pid);

    [MTAThread]
    static int Main(string[] args)
    {
        Root = Path.GetDirectoryName(Process.GetCurrentProcess().MainModule.FileName);
        TmpDir = Path.Combine(Root, "tmp");
        Log.Sink = LogLine;
        AppDomain.CurrentDomain.UnhandledException += delegate(object o, UnhandledExceptionEventArgs e) { LogLine("UNHANDLED " + e.ExceptionObject); };

        string mode = "toggle";
        for (int i = 0; i < args.Length; i++)
        {
            string a = args[i].ToLowerInvariant().TrimStart('-', '/');
            if (a == "quiet") Quiet = true;
            else if (a == "output" && i + 1 < args.Length) OutputFlag = args[++i];
            else if (a.StartsWith("output=")) OutputFlag = args[i].Substring(args[i].IndexOf('=') + 1);
            else if (i == 0) mode = a;
        }
        try
        {
            Directory.CreateDirectory(TmpDir);
            LoadConfig();
            if (mode == "version" || mode == "v") { Say(Version); return 0; }
            if (mode == "status") return Status();
            if (mode == "help" || mode == "h" || mode == "?") { Say("RecPill " + Version + "\nUsage: RecPill.exe start | stop | toggle [-quiet] [--output <folder>] | status | version\nConfig: " + Path.Combine(Root, "config.ini")); return 0; }
            if (mode == "diag") return Tools.Diag(args.Length > 1 ? int.Parse(args[1]) : 3, args.Length > 2 ? args[2] : Path.Combine(Root, "diag.txt"));
            if (mode == "say") return Tools.Say(args.Length > 1 ? args[1] : "Recording check", args.Length > 2 ? args[2] : null);
            if (mode == "setdefault") return Tools.SetDefault(args[1], args.Length > 2 ? args[2].ToLowerInvariant() : "");
            if (mode == "setvisible") return Tools.SetVisible(args[1], args[2] == "1");
            if (mode == "holdmic") return Tools.HoldMic(args[1], int.Parse(args[2]));
            if (mode == "toggle") mode = IsRunning() ? "stop" : "start";
            if (mode == "start") return Start();
            if (mode == "stop") return Stop();
            Say("Unknown command '" + mode + "'. Try: start, stop, toggle, status.");
            return 2;
        }
        catch (Exception ex)
        {
            LogLine("FATAL " + mode + ": " + ex);
            Toast(L.T("err_title"), ex.Message, 3600);
            return 1;
        }
    }

    // ---------------------------------------------------------------- config
    static void LoadConfig()
    {
        Dictionary<string, string> c = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        try { string f = Path.Combine(Root, "config.ini"); if (File.Exists(f)) c = Config.Parse(File.ReadAllText(f, Encoding.UTF8)); } catch (Exception ex) { LogLine("config: " + ex.Message); }
        string v;
        if (c.TryGetValue("language", out v)) L.Force(v);
        if (c.TryGetValue("max_hours", out v)) { double h; if (double.TryParse(v, NumberStyles.Float, CultureInfo.InvariantCulture, out h) && h > 0) MaxHours = h; }
        if (c.TryGetValue("notifications", out v) && (v == "0" || v.ToLowerInvariant() == "off" || v.ToLowerInvariant() == "false")) Quiet = true;
        string dir = OutputFlag;
        if (string.IsNullOrEmpty(dir)) dir = Environment.GetEnvironmentVariable("RECPILL_OUTPUT");
        if (string.IsNullOrEmpty(dir)) c.TryGetValue("output_dir", out dir);
        if (string.IsNullOrEmpty(dir)) dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyMusic), "RecPill");
        CallsDir = Path.GetFullPath(Environment.ExpandEnvironmentVariables(dir));
    }

    static void Say(string text)
    {
        AttachConsole(-1);
        try { Console.WriteLine(text); } catch { }
    }

    static int Status()
    {
        bool run = IsRunning();
        string last = "";
        try { string f = Path.Combine(Root, "toggle.log"); if (File.Exists(f)) { string[] l = File.ReadAllLines(f, Encoding.UTF8); if (l.Length > 0) last = l[l.Length - 1]; } } catch { }
        Say((run ? "recording" : "idle") + "\noutput: " + CallsDir + "\nlast: " + last);
        return run ? 0 : 1;
    }

    static bool IsRunning()
    {
        Mutex m;
        if (Mutex.TryOpenExisting(MutexName, out m)) { m.Dispose(); return true; }
        return false;
    }

    // ---------------------------------------------------------------- start
    static int Start()
    {
        bool created;
        Mutex mutex = new Mutex(true, MutexName, out created);
        if (!created) { Toast(L.T("already_title"), L.T("already_body"), 20); return 0; }
        EventWaitHandle stopEvent = new EventWaitHandle(false, EventResetMode.ManualReset, StopName);
        Directory.CreateDirectory(CallsDir);
        Recover();
        try { Process.GetCurrentProcess().PriorityClass = ProcessPriorityClass.AboveNormal; } catch { }

        string name = DateTime.Now.ToString("yyyy-MM-dd_HH-mm-ss");
        string pcm = Path.Combine(TmpDir, name + ".pcm");
        Stopwatch clock = Stopwatch.StartNew();
        Mixer mixer = new Mixer(new FileStream(pcm, FileMode.Create, FileAccess.Write, FileShare.Read, 1 << 16), RATE, delegate { return clock.Elapsed.TotalSeconds; });
        DeviceManager dm = new DeviceManager(mixer);
        dm.Poll();
        if (dm.Count == 0)
        {
            mixer.Finish(); TryDelete(pcm);
            LogLine("start failed: no audio device could be opened");
            Toast(L.T("nostart_title"), L.T("nostart_body"), 3600);
            mutex.ReleaseMutex();
            return 1;
        }
        mixer.Start();
        SetThreadExecutionState(0x80000001); // ES_CONTINUOUS | ES_SYSTEM_REQUIRED: no sleep mid-call
        ToggleLog("START " + name);
        LogLine("START " + name + " | " + dm.Describe() + " | output " + CallsDir);
        Toast(L.T("rec_title"), dm.Describe(), 20);

        Stopwatch sw = Stopwatch.StartNew();
        bool auto = false;
        int n = 0;
        // 100 ms ticks: every third one is a full device re-check (300 ms), the others only look at the meters of
        // idle secondary outputs so that sound starting there is picked up quickly.
        while (!stopEvent.WaitOne(100))
        {
            n++;
            try { if (n % 3 == 0) dm.Poll(); else dm.QuickPoll(); } catch (Exception ex) { LogLine("poll error: " + ex.Message); }
            if (n % 300 == 0) LogLine("levels " + dm.Levels());
            if (mixer.Failed != null) { LogLine("writer failed: " + mixer.Failed); break; }
            if (sw.Elapsed.TotalHours > MaxHours) { auto = true; break; }
        }

        // stop captures on a side thread: a dead device must not be able to hang Stop
        Thread t = new Thread(delegate() { try { dm.StopAll(); } catch { } });
        t.IsBackground = true; t.Start(); t.Join(4000);
        mixer.Finish();
        SetThreadExecutionState(0x80000000);
        LogLine("captured " + Dur(mixer.Seconds) + " | " + dm.Stats());
        long len = new FileInfo(pcm).Length;
        if (len > 200L * 1024 * 1024) Toast(L.T("saving"), name + ".m4a", 30);
        string final = Convert(pcm, name);
        if (final == null)
        {
            ToggleLog("STOP FAILED " + pcm);
            Toast(L.T("savefail_title"), L.T("savefail_body") + pcm, 3600);
        }
        else
        {
            ToggleLog("STOP " + final + " " + TimeSpan.FromSeconds((int)mixer.Seconds).ToString("c"));
            Toast(auto ? L.T("auto_title") : L.T("saved_title"), Path.GetFileName(final) + " · " + Dur(mixer.Seconds), 600);
        }
        try { mutex.ReleaseMutex(); } catch { }
        Environment.Exit(final == null ? 1 : 0); // hard exit: nothing may keep an audio device open
        return 0;
    }

    // ---------------------------------------------------------------- stop
    static int Stop()
    {
        if (!IsRunning())
        {
            string rec = Recover();
            if (rec != null) Toast(L.T("saved_title"), Path.GetFileName(rec) + L.T("recovered"), 600);
            else Toast(L.T("notrec_title"), L.T("notrec_body"), 20);
            return 0;
        }
        EventWaitHandle ev;
        if (EventWaitHandle.TryOpenExisting(StopName, out ev)) ev.Set();
        // last resort: the recorder did not exit by itself
        Stopwatch sw = Stopwatch.StartNew();
        while (IsRunning() && sw.Elapsed.TotalSeconds < 180) Thread.Sleep(250);
        if (IsRunning())
        {
            LogLine("stop: recorder did not exit in 180 s, killing it");
            int me = Process.GetCurrentProcess().Id;
            foreach (Process p in Process.GetProcessesByName("RecPill"))
                if (p.Id != me) try { p.Kill(); p.WaitForExit(5000); } catch { }
            string rec = Recover();
            if (rec != null) Toast(L.T("saved_title"), Path.GetFileName(rec) + L.T("recovered"), 600);
            else Toast(L.T("stoperr_title"), L.T("stoperr_body"), 3600);
        }
        return 0;
    }

    // Convert leftovers of a crashed/killed recorder. Returns the last recovered file.
    static string Recover()
    {
        string last = null;
        try
        {
            foreach (string pcm in Directory.GetFiles(TmpDir, "*.pcm"))
            {
                if (new FileInfo(pcm).Length < RATE * 2) { TryDelete(pcm); continue; }
                string f = Convert(pcm, Path.GetFileNameWithoutExtension(pcm));
                if (f != null) { last = f; ToggleLog("STOP " + f + " (recovered)"); LogLine("recovered " + f); }
            }
        }
        catch (Exception ex) { LogLine("recover error: " + ex.Message); }
        return last;
    }

    // raw s16le mono 48k -> <output>\<name>.m4a (Media Foundation AAC; WAV as the last resort so audio is never lost)
    static string Convert(string pcm, string name)
    {
        Directory.CreateDirectory(CallsDir);
        string tmpOut = Path.Combine(TmpDir, name + ".m4a");
        string final = Path.Combine(CallsDir, name + ".m4a");
        TryDelete(tmpOut);
        try
        {
            MediaFoundationApi.Startup();
            using (FileStream fs = File.OpenRead(pcm))
            using (RawSourceWaveStream r = new RawSourceWaveStream(fs, new WaveFormat(RATE, 16, 1)))
                MediaFoundationEncoder.EncodeToAac(r, tmpOut, 96000);
        }
        catch (Exception ex) { LogLine("media foundation error: " + ex.Message); }
        try
        {
            if (Good(tmpOut))
            {
                if (File.Exists(final)) final = Path.Combine(CallsDir, name + "_" + DateTime.Now.ToString("HHmmss") + ".m4a");
                File.Move(tmpOut, final);
                TryDelete(pcm);
                return final;
            }
            // keep the audio no matter what
            string wav = Path.Combine(CallsDir, name + ".wav");
            using (FileStream fs = File.OpenRead(pcm))
            using (RawSourceWaveStream r = new RawSourceWaveStream(fs, new WaveFormat(RATE, 16, 1)))
                WaveFileWriter.CreateWaveFile(wav, r);
            TryDelete(pcm);
            LogLine("saved as WAV instead: " + wav);
            return wav;
        }
        catch (Exception ex) { LogLine("convert failed: " + ex.Message); return null; }
    }

    static bool Good(string f) { return File.Exists(f) && new FileInfo(f).Length > 500; }

    // ---------------------------------------------------------------- helpers
    public static string Dur(double s)
    {
        TimeSpan t = TimeSpan.FromSeconds(s);
        if (t.TotalHours >= 1) return (int)t.TotalHours + " " + L.T("u_h") + " " + t.Minutes + " " + L.T("u_min");
        if (t.TotalMinutes >= 1) return t.Minutes + " " + L.T("u_min") + " " + t.Seconds + " " + L.T("u_s");
        return t.Seconds + " " + L.T("u_s");
    }

    static void TryDelete(string f) { try { if (File.Exists(f)) File.Delete(f); } catch { } }

    static readonly object logGate = new object();
    public static void LogLine(string s) { Log2(s); }
    static void Log2(string s)
    {
        try
        {
            lock (logGate)
            {
                string f = Path.Combine(Root, "recpill.log");
                if (File.Exists(f) && new FileInfo(f).Length > 2000000) File.Delete(f);
                File.AppendAllText(f, DateTime.Now.ToString("s") + " " + s + "\r\n", new UTF8Encoding(false));
            }
        }
        catch { }
    }

    // toggle.log: last line tells scripts whether a recording is running and where the last file went
    static void ToggleLog(string s)
    {
        try { File.AppendAllText(Path.Combine(Root, "toggle.log"), DateTime.Now.ToString("s") + " " + s + "\r\n", new UTF8Encoding(false)); } catch { }
    }

    static string X(string s) { return s.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace("\"", "&quot;"); }

    static string EnsureAppId()
    {
        string icon = Path.Combine(Root, "rec.png");
        if (!File.Exists(icon))
        {
            using (Bitmap bmp = new Bitmap(128, 128))
            using (Graphics g = Graphics.FromImage(bmp))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.Clear(Color.Transparent);
                using (SolidBrush b = new SolidBrush(Color.FromArgb(225, 45, 45))) g.FillEllipse(b, 16, 16, 96, 96);
                bmp.Save(icon, ImageFormat.Png);
            }
        }
        using (RegistryKey k = Registry.CurrentUser.CreateSubKey("Software\\Classes\\AppUserModelId\\" + AppId))
        {
            k.SetValue("DisplayName", "RecPill");
            k.SetValue("IconUri", icon);
            k.SetValue("IconBackgroundColor", "00000000"); // no coloured plate behind the red dot
            k.SetValue("ShowInSettings", 0, RegistryValueKind.DWord);
        }
        return icon;
    }

    // Native Windows toast (silent, auto-dismissing). Sent through a hidden PowerShell: no window.
    public static void Toast(string title, string body, int keepSeconds)
    {
        LogLine("toast: " + title + " | " + body);
        if (Quiet) return;
        try
        {
            string icon = EnsureAppId();
            string xml = "<toast duration=\"short\"><visual><binding template=\"ToastGeneric\">"
                + "<image placement=\"appLogoOverride\" src=\"" + X(new Uri(icon).AbsoluteUri) + "\"/>"
                + "<text>" + X(title) + "</text>"
                + (string.IsNullOrEmpty(body) ? "" : "<text>" + X(body) + "</text>")
                + "</binding></visual><audio silent=\"true\"/></toast>";
            string ps = "[void][Windows.UI.Notifications.ToastNotificationManager,Windows.UI.Notifications,ContentType=WindowsRuntime];"
                + "[void][Windows.Data.Xml.Dom.XmlDocument,Windows.Data.Xml.Dom.XmlDocument,ContentType=WindowsRuntime];"
                + "$x=New-Object Windows.Data.Xml.Dom.XmlDocument;$x.LoadXml('" + xml.Replace("'", "''") + "');"
                + "$t=New-Object Windows.UI.Notifications.ToastNotification $x;$t.Tag='rec';$t.Group='recpill';"
                + "$t.ExpirationTime=[DateTimeOffset]::Now.AddSeconds(" + keepSeconds + ");"
                + "[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('" + AppId + "').Show($t)";
            ProcessStartInfo psi = new ProcessStartInfo("powershell.exe",
                "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand " + System.Convert.ToBase64String(Encoding.Unicode.GetBytes(ps)));
            psi.UseShellExecute = false; psi.CreateNoWindow = true;
            Process.Start(psi);
        }
        catch (Exception ex) { LogLine("toast failed: " + ex.Message); }
    }
}

// ---------------------------------------------------------------- strings: English, Russian when the Windows UI language is Russian
static class L
{
    static bool? forced;
    static readonly Dictionary<string, string[]> S = new Dictionary<string, string[]>
    {
        { "err_title",     new[] { "RecPill: error", "Запись звонка: ошибка" } },
        { "already_title", new[] { "Already recording ●", "Запись уже идёт ●" } },
        { "already_body",  new[] { "Stop it with “Stop recording”", "Остановить: «Стоп записи»" } },
        { "nostart_title", new[] { "Recording did NOT start", "Запись НЕ началась" } },
        { "nostart_body",  new[] { "Could not open any microphone or system sound.", "Не удалось открыть ни микрофон, ни звук компьютера." } },
        { "rec_title",     new[] { "Recording ●", "Запись идёт ●" } },
        { "saving",        new[] { "Saving recording…", "Сохраняю запись…" } },
        { "savefail_title",new[] { "Recording was not saved", "Запись не сохранилась" } },
        { "savefail_body", new[] { "Raw audio kept: ", "Сырой звук остался: " } },
        { "auto_title",    new[] { "Recording stopped automatically ■", "Запись остановлена автоматически ■" } },
        { "saved_title",   new[] { "Recording saved ■", "Запись сохранена ■" } },
        { "recovered",     new[] { " (recovered)", " (восстановлена)" } },
        { "notrec_title",  new[] { "Not recording", "Запись не идёт" } },
        { "notrec_body",   new[] { "Nothing to stop.", "Нечего останавливать." } },
        { "stoperr_title", new[] { "Recording stopped with an error", "Запись остановлена с ошибкой" } },
        { "stoperr_body",  new[] { "File not found, see recpill.log", "Файл не найден, см. recpill.log" } },
        { "no_mic",        new[] { "No microphone found", "Микрофон не найден" } },
        { "no_sound",      new[] { "no system sound found", "звук компьютера не найден" } },
        { "u_h",           new[] { "h", "ч" } },
        { "u_min",         new[] { "min", "мин" } },
        { "u_s",           new[] { "s", "с" } },
    };

    public static void Force(string v)
    {
        v = (v ?? "").ToLowerInvariant();
        if (v == "ru") forced = true; else if (v == "en") forced = false;
    }

    public static string T(string key)
    {
        bool ru = forced.HasValue ? forced.Value : CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "ru";
        string[] v;
        return S.TryGetValue(key, out v) ? v[ru ? 1 : 0] : key;
    }
}

// ---------------------------------------------------------------- one capture stream
class Source
{
    public string Id, Name;
    public bool Loopback;
    public volatile bool Dead;
    public string DeadReason;
    public readonly Track Track = new Track();
    public float Peak, PeakAll; public long Frames;
    public DateTime LastData = DateTime.UtcNow;
    public string Format = "";
    readonly Mixer mixer;
    AudioClient client; AudioCaptureClient cc; Thread th; volatile bool stopReq;
    int ch, bits, rate, block; bool isFloat;
    Resampler rs;
    byte[] raw = new byte[0];
    float[] mono = new float[0];

    public Source(Mixer m) { mixer = m; }

    // Own capture loop (shared mode, so other apps keep the device). Every failure, including the device
    // disappearing mid-call, ends in Dead=true and never in an unhandled exception.
    public void Open(MMDevice d)
    {
        client = d.AudioClient;
        WaveFormat wf = client.MixFormat;
        Init(wf);
        Format = wf.SampleRate + " Hz " + wf.Channels + " ch";
        client.Initialize(AudioClientShareMode.Shared, Loopback ? AudioClientStreamFlags.Loopback : AudioClientStreamFlags.None, 200 * 10000L, 0, wf, Guid.Empty);
        cc = client.AudioCaptureClient;
        client.Start();
        th = new Thread(Run); th.IsBackground = true; th.Priority = ThreadPriority.AboveNormal; th.Start();
    }

    void Run()
    {
        try
        {
            while (!stopReq)
            {
                Thread.Sleep(20);
                int pkt = cc.GetNextPacketSize();
                while (pkt != 0 && !stopReq)
                {
                    int frames; AudioClientBufferFlags flags;
                    IntPtr ptr = cc.GetBuffer(out frames, out flags);
                    int bytes = frames * block;
                    if (raw.Length < bytes) raw = new byte[bytes];
                    if ((flags & AudioClientBufferFlags.Silent) != 0) Array.Clear(raw, 0, bytes);
                    else Marshal.Copy(ptr, raw, 0, bytes);
                    cc.ReleaseBuffer(frames);
                    OnData(raw, bytes);
                    pkt = cc.GetNextPacketSize();
                }
            }
        }
        catch (Exception ex) { DeadReason = ex.Message; }
        finally
        {
            try { client.Stop(); } catch { }
            try { client.Dispose(); } catch { }
            if (!stopReq && DeadReason == null) DeadReason = "stopped";
            Dead = true;
        }
    }

    public void Close(int waitMs)
    {
        stopReq = true;
        try { if (th != null && waitMs > 0) th.Join(waitMs); } catch { }
    }

    void Init(WaveFormat wf)
    {
        ch = wf.Channels; bits = wf.BitsPerSample; rate = wf.SampleRate; block = wf.BlockAlign;
        isFloat = wf.Encoding == WaveFormatEncoding.IeeeFloat;
        WaveFormatExtensible ext = wf as WaveFormatExtensible;
        if (ext != null) isFloat = ext.SubFormat == new Guid("00000003-0000-0010-8000-00aa00389b71");
        if (!isFloat && bits != 16 && bits != 24 && bits != 32) throw new Exception("unsupported format " + wf);
        if (rate != App.RATE) rs = new Resampler(rate, App.RATE);
    }

    void OnData(byte[] b, int byteCount)
    {
        int frames = byteCount / block;
        if (frames <= 0) return;
        if (mono.Length < frames) mono = new float[frames];
        Pcm.ToMono(b, frames, ch, bits, isFloat, mono);
        float pk = 0;
        for (int i = 0; i < frames; i++) { float a = mono[i]; if (a < 0) a = -a; if (a > pk) pk = a; }
        if (pk > Peak) Peak = pk;
        if (pk > PeakAll) PeakAll = pk;
        Frames += frames;
        LastData = DateTime.UtcNow;

        float[] o2; int n;
        if (rs == null) { o2 = mono; n = frames; }
        else { n = rs.Process(mono, frames); o2 = rs.Out; }
        if (n > 0) mixer.Add(Track, o2, n);
    }
}

// ---------------------------------------------------------------- which devices to record, re-checked 3x a second
class DeviceManager
{
    static readonly PropertyKey EnumKey = new PropertyKey(new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), 24);
    readonly Mixer mixer;
    readonly MMDeviceEnumerator en = new MMDeviceEnumerator();
    readonly Dictionary<string, Source> sources = new Dictionary<string, Source>();
    readonly Dictionary<string, DateTime> backoff = new Dictionary<string, DateTime>();
    readonly Dictionary<string, string> enumCache = new Dictionary<string, string>();
    readonly List<MMDevice> candidates = new List<MMDevice>(); // idle real outputs whose meters QuickPoll watches
    readonly int myPid = Process.GetCurrentProcess().Id;
    readonly string micMemo = Path.Combine(App.Root, "last-mic.txt");
    string lastNote = "";

    public DeviceManager(Mixer m) { mixer = m; }
    public int Count { get { lock (sources) return sources.Count; } }

    string EnumName(MMDevice d)
    {
        string v;
        if (enumCache.TryGetValue(d.ID, out v)) return v;
        try { v = (d.Properties[EnumKey].Value as string) ?? ""; } catch { v = ""; }
        enumCache[d.ID] = v;
        return v;
    }
    bool IsBt(MMDevice d) { string e = EnumName(d); return e.StartsWith("BTH", StringComparison.OrdinalIgnoreCase) || d.FriendlyName.IndexOf("Hands-Free", StringComparison.OrdinalIgnoreCase) >= 0; }
    bool IsVirtual(MMDevice d) { return string.Equals(EnumName(d), "ROOT", StringComparison.OrdinalIgnoreCase); }

    MMDevice Default(DataFlow f, Role r)
    {
        try { return en.GetDefaultAudioEndpoint(f, r); } catch { return null; }
    }

    bool InUseByOthers(MMDevice d)
    {
        try
        {
            AudioSessionManager m = d.AudioSessionManager;
            m.RefreshSessions();
            SessionCollection ss = m.Sessions;
            for (int i = 0; i < ss.Count; i++)
            {
                AudioSessionControl s = ss[i];
                if (s.State == AudioSessionState.AudioSessionStateActive && s.GetProcessID != (uint)myPid) return true;
            }
        }
        catch { }
        return false;
    }

    // One microphone at a time. A Bluetooth hands-free mic is used only when a call app already has it open.
    MMDevice PickMic(List<MMDevice> active, out string why)
    {
        foreach (MMDevice d in active) if (IsBt(d) && InUseByOthers(d)) { why = "bluetooth mic is in use by a call app"; return d; }
        MMDevice def = Default(DataFlow.Capture, Role.Console);
        if (def != null && !IsBt(def))
        {
            try { if (!File.Exists(micMemo) || File.ReadAllText(micMemo) != def.ID) File.WriteAllText(micMemo, def.ID); } catch { }
            why = "default mic"; return def;
        }
        string memo = null;
        try { if (File.Exists(micMemo)) memo = File.ReadAllText(micMemo).Trim(); } catch { }
        foreach (MMDevice d in active) if (d.ID == memo && !IsBt(d)) { why = "default mic is an idle bluetooth mic -> last used wired mic"; return d; }
        MMDevice com = Default(DataFlow.Capture, Role.Communications);
        if (com != null && !IsBt(com)) { why = "communications mic"; return com; }
        foreach (MMDevice d in active) if (!IsBt(d) && !IsVirtual(d)) { why = "first wired mic"; return d; }
        foreach (MMDevice d in active) if (!IsBt(d)) { why = "first non-bluetooth mic"; return d; }
        why = active.Count == 0 ? "no microphone found" : "only an idle bluetooth mic exists; not opening it (it would silence the earbuds)";
        return null;
    }

    // cheap check between full polls: sound just started on an idle secondary output -> open it now
    public void QuickPoll()
    {
        foreach (MMDevice d in candidates.ToArray())
        {
            lock (sources) if (sources.ContainsKey(d.ID)) continue;
            DateTime until;
            if (backoff.TryGetValue(d.ID, out until) && DateTime.UtcNow < until) continue;
            float p = 0;
            try { p = d.AudioMeterInformation.MasterPeakValue; } catch { }
            if (p > 0.0005f) Open(d, true);
        }
    }

    public void Poll()
    {
        // drop dead streams (device unplugged / reconfigured); they are re-opened below if still wanted
        List<Source> dead = new List<Source>();
        lock (sources)
        {
            foreach (Source s in sources.Values) if (s.Dead) dead.Add(s);
            foreach (Source s in dead) sources.Remove(s.Id);
        }
        foreach (Source s in dead) { App.LogLine("lost " + Kind(s) + " '" + s.Name + "': " + s.DeadReason); backoff[s.Id] = DateTime.UtcNow.AddSeconds(2); Close(s); }

        Dictionary<string, MMDevice> want = new Dictionary<string, MMDevice>();
        Dictionary<string, bool> wantLoop = new Dictionary<string, bool>();

        // system sound: the default output always; any other real output as soon as something plays on it
        MMDevice defR = Default(DataFlow.Render, Role.Console);
        string defId = defR != null ? defR.ID : null;
        candidates.Clear();
        foreach (MMDevice d in en.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active))
        {
            Source have; bool has;
            lock (sources) has = sources.TryGetValue(d.ID, out have);
            bool take;
            if (d.ID == defId) take = true;
            else if (has) take = (DateTime.UtcNow - have.LastData).TotalSeconds < (IsBt(d) ? 3 : 20); // release idle secondary outputs (a Bluetooth one at once)
            else
            {
                take = false;
                if (!IsVirtual(d))
                {
                    candidates.Add(d);
                    try { take = d.AudioMeterInformation.MasterPeakValue > 0.0005f; } catch { }
                }
            }
            if (take) { want[d.ID] = d; wantLoop[d.ID] = true; }
        }

        List<MMDevice> caps = new List<MMDevice>();
        foreach (MMDevice d in en.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active)) caps.Add(d);
        string why;
        MMDevice mic = PickMic(caps, out why);
        if (mic != null) { want[mic.ID] = mic; wantLoop[mic.ID] = false; }
        string note = "mic: " + (mic != null ? mic.FriendlyName : "none") + " (" + why + ")";
        if (note != lastNote) { App.LogLine(note); lastNote = note; }

        List<Source> drop = new List<Source>();
        lock (sources)
        {
            foreach (Source s in sources.Values) if (!want.ContainsKey(s.Id)) drop.Add(s);
            foreach (Source s in drop) sources.Remove(s.Id);
        }
        foreach (Source s in drop) { App.LogLine("close " + Kind(s) + " '" + s.Name + "'"); Close(s); }

        foreach (KeyValuePair<string, MMDevice> kv in want)
        {
            lock (sources) if (sources.ContainsKey(kv.Key)) continue;
            DateTime until;
            if (backoff.TryGetValue(kv.Key, out until) && DateTime.UtcNow < until) continue;
            Open(kv.Value, wantLoop[kv.Key]);
        }
    }

    void Open(MMDevice d, bool loopback)
    {
        Source s = new Source(mixer);
        s.Id = d.ID; s.Name = d.FriendlyName; s.Loopback = loopback;
        try
        {
            s.Open(d);
            lock (sources) sources[s.Id] = s;
            App.LogLine("open " + Kind(s) + " '" + s.Name + "' " + s.Format);
        }
        catch (Exception ex)
        {
            backoff[d.ID] = DateTime.UtcNow.AddSeconds(5);
            App.LogLine("cannot open " + Kind(s) + " '" + s.Name + "': " + ex.Message);
            s.Close(0);
        }
    }

    static string Kind(Source s) { return s.Loopback ? "output" : "mic"; }

    readonly List<Source> closed = new List<Source>();
    void Close(Source s)
    {
        lock (closed) closed.Add(s);
        s.Close(0);
    }

    public void StopAll()
    {
        List<Source> all;
        lock (sources) { all = new List<Source>(sources.Values); sources.Clear(); }
        foreach (Source s in all) { lock (closed) closed.Add(s); s.Close(0); }
        foreach (Source s in all) s.Close(1500);
    }

    static string Db(float p) { return p <= 0 ? "-inf" : Math.Round(20 * Math.Log10(p)).ToString() + " dB"; }

    public string Describe()
    {
        string mic = null; List<string> outs = new List<string>();
        lock (sources) foreach (Source s in sources.Values) { if (s.Loopback) outs.Add(s.Name); else mic = s.Name; }
        return (mic ?? L.T("no_mic")) + " + " + (outs.Count > 0 ? string.Join(", ", outs.ToArray()) : L.T("no_sound"));
    }

    public string Levels()
    {
        StringBuilder sb = new StringBuilder();
        lock (sources) foreach (Source s in sources.Values) { sb.Append(Kind(s) + " '" + s.Name + "' " + Db(s.Peak) + "; "); s.Peak = 0; }
        return sb.ToString();
    }

    public string Stats()
    {
        StringBuilder sb = new StringBuilder();
        lock (closed) foreach (Source s in closed)
            sb.Append(Kind(s) + " '" + s.Name + "' frames=" + s.Frames + " peak=" + Db(s.PeakAll) + " resyncs=" + s.Track.Resyncs + "; ");
        return sb.ToString();
    }
}

// ---------------------------------------------------------------- troubleshooting / test tools
[ComImport, Guid("f8679f50-850a-41cf-9c72-430f290290c8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IPolicyConfig
{
    [PreserveSig] int GetMixFormat(); [PreserveSig] int GetDeviceFormat(); [PreserveSig] int ResetDeviceFormat(); [PreserveSig] int SetDeviceFormat();
    [PreserveSig] int GetProcessingPeriod(); [PreserveSig] int SetProcessingPeriod(); [PreserveSig] int GetShareMode(); [PreserveSig] int SetShareMode();
    [PreserveSig] int GetPropertyValue(); [PreserveSig] int SetPropertyValue();
    [PreserveSig] int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string deviceId, int role);
    [PreserveSig] int SetEndpointVisibility([MarshalAs(UnmanagedType.LPWStr)] string deviceId, [MarshalAs(UnmanagedType.Bool)] bool visible);
}
[ComImport, Guid("870af99c-171d-4f9e-af0d-e63df40c2bc9")]
class PolicyConfigClient { }

static class Tools
{
    // holdmic <name substring> <seconds>: keep a mic open like a call app would (to test the Bluetooth-mic rule)
    public static int HoldMic(string name, int seconds)
    {
        foreach (MMDevice d in new MMDeviceEnumerator().EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active))
        {
            if (d.FriendlyName.IndexOf(name, StringComparison.OrdinalIgnoreCase) < 0) continue;
            AudioClient c = d.AudioClient;
            c.Initialize(AudioClientShareMode.Shared, AudioClientStreamFlags.None, 200 * 10000L, 0, c.MixFormat, Guid.Empty);
            AudioCaptureClient cc = c.AudioCaptureClient;
            c.Start();
            App.LogLine("holdmic '" + d.FriendlyName + "' " + seconds + " s");
            Stopwatch sw = Stopwatch.StartNew();
            while (sw.Elapsed.TotalSeconds < seconds)
            {
                Thread.Sleep(20);
                while (cc.GetNextPacketSize() != 0) { int f; AudioClientBufferFlags fl; cc.GetBuffer(out f, out fl); cc.ReleaseBuffer(f); }
            }
            c.Stop(); c.Dispose();
            return 0;
        }
        return 3;
    }

    // setvisible <name or id substring> <0|1>: same as Disable/Enable in the Sound panel (simulates a device vanishing)
    public static int SetVisible(string name, bool visible)
    {
        foreach (MMDevice d in new MMDeviceEnumerator().EnumerateAudioEndPoints(DataFlow.All, DeviceState.Active | DeviceState.Disabled))
        {
            if (d.FriendlyName.IndexOf(name, StringComparison.OrdinalIgnoreCase) < 0 && d.ID.IndexOf(name, StringComparison.OrdinalIgnoreCase) < 0) continue;
            int hr = ((IPolicyConfig)new PolicyConfigClient()).SetEndpointVisibility(d.ID, visible);
            App.LogLine("setvisible '" + d.FriendlyName + "' " + visible + " hr=" + hr);
            return hr == 0 ? 0 : 4;
        }
        return 3;
    }

    // setdefault <friendly name or id substring> [comm|all]: make a device the default (what the Sound panel does)
    public static int SetDefault(string name, string roles)
    {
        foreach (MMDevice d in new MMDeviceEnumerator().EnumerateAudioEndPoints(DataFlow.All, DeviceState.Active))
        {
            if (d.FriendlyName.IndexOf(name, StringComparison.OrdinalIgnoreCase) < 0 && d.ID.IndexOf(name, StringComparison.OrdinalIgnoreCase) < 0) continue;
            IPolicyConfig pc = (IPolicyConfig)new PolicyConfigClient();
            int hr = 0;
            if (roles != "comm") { hr |= pc.SetDefaultEndpoint(d.ID, 0); hr |= pc.SetDefaultEndpoint(d.ID, 1); }
            if (roles == "comm" || roles == "all") hr |= pc.SetDefaultEndpoint(d.ID, 2);
            App.LogLine("setdefault '" + d.FriendlyName + "' roles=" + roles + " hr=" + hr);
            return hr == 0 ? 0 : 4;
        }
        return 3;
    }

    public static int Diag(int seconds, string outFile)
    {
        MMDeviceEnumerator en = new MMDeviceEnumerator();
        StringBuilder sb = new StringBuilder();
        List<MMDevice> devs = new List<MMDevice>();
        foreach (MMDevice d in en.EnumerateAudioEndPoints(DataFlow.All, DeviceState.Active)) devs.Add(d);
        float[] peak = new float[devs.Count];
        Stopwatch sw = Stopwatch.StartNew();
        while (sw.Elapsed.TotalSeconds < seconds)
        {
            for (int i = 0; i < devs.Count; i++) { try { float p = devs[i].AudioMeterInformation.MasterPeakValue; if (p > peak[i]) peak[i] = p; } catch { } }
            Thread.Sleep(40);
        }
        foreach (DataFlow f in new DataFlow[] { DataFlow.Render, DataFlow.Capture })
            foreach (Role r in new Role[] { Role.Console, Role.Communications })
            {
                string n = "none";
                try { n = en.GetDefaultAudioEndpoint(f, r).FriendlyName; } catch { }
                sb.AppendLine("default " + f + " " + r + ": " + n);
            }
        for (int i = 0; i < devs.Count; i++)
        {
            MMDevice d = devs[i];
            string extra = "";
            try { extra = "vol=" + Math.Round(d.AudioEndpointVolume.MasterVolumeLevelScalar, 2) + " mute=" + d.AudioEndpointVolume.Mute; } catch { }
            int sess = 0; string pids = "";
            try
            {
                d.AudioSessionManager.RefreshSessions();
                SessionCollection ss = d.AudioSessionManager.Sessions;
                for (int j = 0; j < ss.Count; j++) if (ss[j].State == AudioSessionState.AudioSessionStateActive) { sess++; pids += ss[j].GetProcessID + " "; }
            }
            catch { }
            sb.AppendLine(d.DataFlow + " | " + d.FriendlyName + " | " + extra + " | maxPeak=" + peak[i].ToString("0.0000") + " | activeSessions=" + sess + " pids=" + pids.Trim());
        }
        foreach (Process p in Process.GetProcessesByName("RecPill")) sb.AppendLine("process RecPill pid=" + p.Id + (p.Id == Process.GetCurrentProcess().Id ? " (this diag)" : ""));
        File.WriteAllText(outFile, sb.ToString(), new UTF8Encoding(false));
        return 0;
    }

    public static int Say(string text, string device)
    {
        using (System.Speech.Synthesis.SpeechSynthesizer sp = new System.Speech.Synthesis.SpeechSynthesizer())
        {
            bool cyr = false;
            foreach (char ch in text) if (ch >= '\u0400' && ch <= '\u04FF') { cyr = true; break; }
            string want = cyr ? "ru" : "en";
            foreach (System.Speech.Synthesis.InstalledVoice v in sp.GetInstalledVoices())
                if (v.Enabled && v.VoiceInfo.Culture.Name.StartsWith(want)) { sp.SelectVoice(v.VoiceInfo.Name); break; }
            if (device == null) { sp.SetOutputToDefaultAudioDevice(); sp.Speak(text); return 0; }
            MemoryStream ms = new MemoryStream();
            sp.SetOutputToWaveStream(ms);
            sp.Speak(text);
            sp.SetOutputToNull();
            ms.Position = 0;
            MMDevice target = null;
            foreach (MMDevice d in new MMDeviceEnumerator().EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active))
                if (d.FriendlyName.IndexOf(device, StringComparison.OrdinalIgnoreCase) >= 0) { target = d; break; }
            if (target == null) return 3;
            using (WaveFileReader r = new WaveFileReader(ms))
            using (WasapiOut o = new WasapiOut(target, AudioClientShareMode.Shared, false, 100))
            {
                o.Init(r); o.Play();
                while (o.PlaybackState == PlaybackState.Playing) Thread.Sleep(50);
            }
        }
        return 0;
    }
}
