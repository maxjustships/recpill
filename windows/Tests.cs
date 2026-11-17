// Unit tests for the pure audio logic in Core.cs. Build + run: windows\build.ps1 -Test
using System;
using System.IO;
using RecPill;

static class T
{
    static int fails, checks;

    static void Ok(bool cond, string what)
    {
        checks++;
        if (!cond) { fails++; Console.WriteLine("FAIL: " + what); }
    }

    static void Near(double a, double b, double tol, string what) { Ok(Math.Abs(a - b) <= tol, what + " (got " + a + ", want " + b + " ±" + tol + ")"); }

    static short[] Samples(byte[] b)
    {
        short[] s = new short[b.Length / 2];
        for (int i = 0; i < s.Length; i++) s[i] = BitConverter.ToInt16(b, 2 * i);
        return s;
    }

    static float[] Sine(double hz, int rate, int n, double amp)
    {
        float[] f = new float[n];
        for (int i = 0; i < n; i++) f[i] = (float)(amp * Math.Sin(2 * Math.PI * hz * i / rate));
        return f;
    }

    static int ZeroCrossings(float[] f, int n)
    {
        int z = 0;
        for (int i = 1; i < n; i++) if ((f[i - 1] < 0) != (f[i] < 0)) z++;
        return z;
    }

    static void TestResampler()
    {
        float[] sine = Sine(440, 44100, 44100, 0.5); // 1 s at 44.1 kHz
        Resampler one = new Resampler(44100, 48000);
        int n1 = one.Process(sine, sine.Length);
        Near(n1, 48000, 4, "44.1k -> 48k gives ~48000 samples for 1 s");
        float[] whole = new float[n1]; Array.Copy(one.Out, whole, n1);
        Near(ZeroCrossings(whole, n1), 880, 2, "440 Hz tone survives resampling (zero crossings)");

        // the same signal fed in odd-sized packets must come out the same: no clicks at packet borders
        Resampler chunked = new Resampler(44100, 48000);
        float[] joined = new float[n1 + 64]; int total = 0;
        int[] sizes = { 441, 480, 1000, 7, 4410, 13 };
        int pos = 0, k = 0;
        while (pos < sine.Length)
        {
            int c = Math.Min(sizes[k++ % sizes.Length], sine.Length - pos);
            float[] part = new float[c]; Array.Copy(sine, pos, part, 0, c);
            int n = chunked.Process(part, c);
            Array.Copy(chunked.Out, 0, joined, total, n); total += n; pos += c;
        }
        Near(total, n1, 3, "chunked output length matches one-shot");
        double maxDiff = 0;
        for (int i = 0; i < Math.Min(total, n1) - 2; i++) maxDiff = Math.Max(maxDiff, Math.Abs(joined[i] - whole[i]));
        Ok(maxDiff < 0.01, "chunked output equals one-shot output (max diff " + maxDiff + ")");

        Resampler down = new Resampler(96000, 48000);
        float[] hi = Sine(1000, 96000, 96000, 0.5);
        Near(down.Process(hi, hi.Length), 48000, 4, "96k -> 48k halves the length");
        Resampler empty = new Resampler(44100, 48000);
        Ok(empty.Process(new float[0], 0) == 0, "empty packet is a no-op");
    }

    static void TestPcm()
    {
        float[] m = new float[2];
        byte[] s16 = new byte[8]; // 2 frames stereo 16-bit: (16384, -16384), (32767, 32767)
        Buffer.BlockCopy(new short[] { 16384, -16384, 32767, 32767 }, 0, s16, 0, 8);
        Pcm.ToMono(s16, 2, 2, 16, false, m);
        Near(m[0], 0, 1e-6, "stereo 16-bit opposite channels average to 0");
        Near(m[1], 32767 / 32768.0, 1e-4, "stereo 16-bit full scale");

        byte[] f32 = new byte[16];
        Buffer.BlockCopy(new float[] { 0.5f, 0.25f, -1f, 1f }, 0, f32, 0, 16);
        Pcm.ToMono(f32, 2, 2, 32, true, m);
        Near(m[0], 0.375, 1e-6, "float32 stereo average");
        Near(m[1], 0, 1e-6, "float32 stereo cancels");

        byte[] s24 = { 0x00, 0x00, 0x40, 0x00, 0x00, 0xC0 }; // +0.5, -0.5 (mono, 2 frames)
        Pcm.ToMono(s24, 2, 1, 24, false, m);
        Near(m[0], 0.5, 1e-6, "24-bit positive");
        Near(m[1], -0.5, 1e-6, "24-bit negative sign extension");

        byte[] s32 = new byte[4]; Buffer.BlockCopy(new int[] { int.MinValue / 2 }, 0, s32, 0, 4);
        Pcm.ToMono(s32, 1, 1, 32, false, m);
        Near(m[0], -0.5, 1e-6, "32-bit integer");

        bool threw = false;
        try { Pcm.ToMono(new byte[8], 1, 1, 8, false, m); } catch (NotSupportedException) { threw = true; }
        Ok(threw, "8-bit is rejected");
    }

    static void TestMixer()
    {
        const int R = 1000; // tiny rate: tests stay instant
        double now = 0;
        MemoryStream ms = new MemoryStream();
        Mixer mx = new Mixer(ms, R, delegate { return now; });
        Track a = new Track(), b = new Track();
        float[] qa = new float[500], qb = new float[500];
        for (int i = 0; i < 500; i++) { qa[i] = 0.25f; qb[i] = 0.5f; }
        now = 2.0;
        mx.Add(a, qa, 500); mx.Add(b, qb, 500);
        mx.Flush(0);
        short[] s = Samples(ms.ToArray());
        Ok(s.Length == 2000, "flush writes everything up to now (" + s.Length + " samples)");
        Ok(s[100] == 0 && s[1499] == 0, "silence before the first packet");
        Near(s[1500] / 32767.0, 0.75, 1e-3, "two sources are summed");
        Near(s[1999] / 32767.0, 0.75, 1e-3, "sum holds to the end of the packet");

        // clipping: sum above full scale is clamped, not wrapped
        ms = new MemoryStream(); now = 0;
        mx = new Mixer(ms, R, delegate { return now; });
        Track c = new Track(), d = new Track();
        float[] big = new float[100]; for (int i = 0; i < 100; i++) big[i] = 0.9f;
        now = 0.1;
        mx.Add(c, big, 100); mx.Add(d, big, 100); mx.Flush(0);
        s = Samples(ms.ToArray());
        Ok(s.Length == 100 && s[50] == 32767, "sum over full scale is clipped to +32767");

        // one source going away does not disturb the rest: only the other one is heard afterwards
        ms = new MemoryStream(); now = 0;
        mx = new Mixer(ms, R, delegate { return now; });
        Track e = new Track(), f = new Track();
        float[] half = new float[100]; for (int i = 0; i < 100; i++) half[i] = 0.5f;
        float[] q = new float[100]; for (int i = 0; i < 100; i++) q[i] = 0.25f;
        now = 0.1; mx.Add(e, half, 100); mx.Add(f, q, 100);
        now = 0.2; mx.Add(f, q, 100); // e is gone
        mx.Flush(0);
        s = Samples(ms.ToArray());
        Near(s[50] / 32767.0, 0.75, 1e-3, "both sources heard while both are alive");
        Near(s[150] / 32767.0, 0.25, 1e-3, "only the surviving source after the other left");
        Ok(e.Resyncs == 0 && f.Resyncs == 0, "steady sources are not resynced");

        // a source whose clock jumps (device reconfigured) is resynced onto "now" instead of drifting
        ms = new MemoryStream(); now = 0;
        mx = new Mixer(ms, R, delegate { return now; });
        Track g = new Track();
        now = 1.0; mx.Add(g, q, 100);
        now = 1.0 + 0.05; mx.Add(g, q, 100); // 50 ms later but only 100 ms of audio delivered: within slack, no resync
        Ok(g.Resyncs == 0, "small timing jitter is absorbed");
        now = 3.0; mx.Add(g, q, 100);
        Ok(g.Resyncs == 1, "large drift triggers a resync");

        // the machine sleeps for a long time: the gap is cut, not recorded as hours of silence
        ms = new MemoryStream(); now = 0;
        mx = new Mixer(ms, R, delegate { return now; });
        now = 1.0; mx.Flush(0);
        now = 1000.0; mx.Flush(0);
        Ok(ms.Length / 2 < 1500, "a long sleep is cut out (" + ms.Length / 2 + " samples)");

        // writes are never ahead of the margin
        ms = new MemoryStream(); now = 0;
        mx = new Mixer(ms, R, delegate { return now; });
        now = 3.0; mx.Flush(R);
        Ok(ms.Length / 2 == 2000, "margin of one second is kept behind 'now'");
        Near(mx.Seconds, 2.0, 1e-9, "Seconds reports flushed audio");
    }

    static void TestConfig()
    {
        var c = Config.Parse("\uFEFF# comment\r\noutput_dir = \"D:\\My Calls\"\r\nmax_hours=2.5\r\n;x=1\r\nbroken\r\n");
        Ok(c["output_dir"] == "D:\\My Calls", "quoted value with spaces");
        Ok(c["MAX_HOURS"] == "2.5", "keys are case-insensitive");
        Ok(!c.ContainsKey("x") && !c.ContainsKey("broken"), "comments and junk lines are skipped");
        string t = Config.Set("# my config\r\noutput_dir=C:\\a\r\n", "OUTPUT_DIR", "C:\\b");
        Ok(t.Contains("# my config") && t.Contains("OUTPUT_DIR=C:\\b") && !t.Contains("C:\\a"), "Set replaces a key and keeps comments");
        t = Config.Set("", "language", "ru");
        Ok(Config.Parse(t)["language"] == "ru", "Set adds a key to an empty file");
    }

    static int Main()
    {
        TestResampler(); TestPcm(); TestMixer(); TestConfig();
        Console.WriteLine(fails == 0 ? "OK: " + checks + " checks passed" : fails + " of " + checks + " checks FAILED");
        return fails == 0 ? 0 : 1;
    }
}
