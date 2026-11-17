// RecPill core: pure audio logic with no Windows or NAudio dependency, so it can be unit-tested anywhere csc runs.
//   Pcm        - raw device packets -> mono float
//   Resampler  - linear-interpolation resampler that is continuous across packets
//   Track      - per-source position on the shared timeline
//   Mixer      - sums all tracks onto one wall-clock timeline and writes s16le mono to a stream
//   Config     - tiny key=value config file parser
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Threading;

namespace RecPill
{
    public static class Pcm
    {
        /// <summary>Downmix interleaved packets to mono floats. Supports 16/24/32-bit integer and 32-bit float.</summary>
        public static void ToMono(byte[] b, int frames, int ch, int bits, bool isFloat, float[] mono)
        {
            int bytes = bits / 8, block = ch * bytes;
            if (isFloat && bits == 32)
            {
                for (int i = 0; i < frames; i++)
                {
                    float s = 0;
                    for (int c = 0; c < ch; c++) s += BitConverter.ToSingle(b, i * block + c * 4);
                    mono[i] = s / ch;
                }
                return;
            }
            if (bits != 16 && bits != 24 && bits != 32) throw new NotSupportedException("unsupported sample size " + bits);
            for (int i = 0; i < frames; i++)
            {
                float s = 0;
                for (int c = 0; c < ch; c++)
                {
                    int o = i * block + c * bytes;
                    if (bits == 16) s += BitConverter.ToInt16(b, o) / 32768f;
                    else if (bits == 24) s += (b[o] | (b[o + 1] << 8) | ((sbyte)b[o + 2] << 16)) / 8388608f;
                    else s += BitConverter.ToInt32(b, o) / 2147483648f;
                }
                mono[i] = s / ch;
            }
        }
    }

    public sealed class Resampler
    {
        readonly double step;
        double t;
        float last;
        public float[] Out = new float[0];

        public Resampler(int inRate, int outRate) { step = inRate / (double)outRate; }

        /// <summary>Resample one packet; the result is in Out[0..n). State carries over to the next packet.</summary>
        public int Process(float[] mono, int frames)
        {
            if (frames <= 0) return 0;
            int need = (int)(frames / step) + 4;
            if (Out.Length < need) Out = new float[need];
            int n = 0;
            while (t < frames - 1)
            {
                int i = (int)Math.Floor(t);
                float f = (float)(t - i);
                float a = i < 0 ? last : mono[i];
                float c2 = mono[i + 1];
                Out[n++] = a + (c2 - a) * f;
                t += step;
            }
            t -= frames;
            last = mono[frames - 1];
            return n;
        }
    }

    /// <summary>Per-source cursor on the mixer timeline.</summary>
    public sealed class Track
    {
        public long Pos;
        public bool Started;
        public int Resyncs;
    }

    /// <summary>
    /// All sources add their samples onto one wall-clock timeline; a writer thread flushes it to the stream
    /// one second behind "now". A source that goes quiet or disappears simply stops adding.
    /// </summary>
    public sealed class Mixer
    {
        readonly int rate;
        readonly int N, slack;
        readonly float[] acc;
        readonly object gate = new object();
        readonly Func<double> clock;
        readonly Stream output;
        long skipped, lastNow, flushed;
        Thread th;
        volatile bool stop;
        public volatile string Failed;

        public Mixer(Stream output, int rate, Func<double> clock)
        {
            this.output = output; this.rate = rate; this.clock = clock;
            N = rate * 8; slack = rate / 4; acc = new float[N];
        }

        public double Seconds { get { return flushed / (double)rate; } }
        long Now() { return (long)(clock() * rate) - skipped; }

        public void Start() { th = new Thread(Run); th.IsBackground = true; th.Priority = ThreadPriority.AboveNormal; th.Start(); }

        public void Add(Track s, float[] buf, int n)
        {
            lock (gate)
            {
                long target = Now() - n;
                if (!s.Started || s.Pos < target - slack || s.Pos > target + slack)
                {
                    if (s.Started) s.Resyncs++;
                    s.Pos = target; s.Started = true;
                }
                long p = s.Pos;
                int off = p < flushed ? (int)Math.Min(n, flushed - p) : 0;
                if (p + n - flushed < N)
                    for (int i = off; i < n; i++) acc[(p + i) % N] += buf[i];
                s.Pos = p + n;
            }
        }

        void Run()
        {
            int k = 0;
            while (!stop)
            {
                Thread.Sleep(200);
                try { Flush(rate); if (++k % 5 == 0) output.Flush(); }
                catch (Exception ex) { Failed = ex.Message; return; }
            }
        }

        /// <summary>Write everything older than <paramref name="margin"/> samples before "now". Public for tests.</summary>
        public void Flush(int margin)
        {
            float[] tmp;
            lock (gate)
            {
                long now = Now();
                if (now - lastNow > 5L * rate) { skipped += now - lastNow - rate / 4; now = Now(); } // machine slept: cut the gap
                lastNow = now;
                long end = now - margin;
                int count = (int)Math.Min(end - flushed, N);
                if (count <= 0) return;
                tmp = new float[count];
                for (int i = 0; i < count; i++) { int idx = (int)((flushed + i) % N); tmp[i] = acc[idx]; acc[idx] = 0f; }
                flushed += count;
            }
            byte[] b = new byte[tmp.Length * 2];
            for (int i = 0; i < tmp.Length; i++)
            {
                float v = tmp[i];
                if (v > 1f) v = 1f; else if (v < -1f) v = -1f;
                short sh = (short)(v * 32767f);
                b[2 * i] = (byte)sh; b[2 * i + 1] = (byte)(sh >> 8);
            }
            output.Write(b, 0, b.Length);
        }

        public void Finish()
        {
            stop = true;
            if (th != null) th.Join(3000);
            try { Flush(0); } catch (Exception ex) { Log.Write("final flush: " + ex.Message); }
            try { output.Flush(); output.Dispose(); } catch { }
        }
    }

    /// <summary>Minimal log hook so Core has no dependency on the app.</summary>
    public static class Log
    {
        public static Action<string> Sink = delegate { };
        public static void Write(string s) { Sink(s); }
    }

    /// <summary>key=value lines, '#' or ';' comments, case-insensitive keys, values may be quoted.</summary>
    public static class Config
    {
        public static Dictionary<string, string> Parse(string text)
        {
            Dictionary<string, string> d = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (string raw in (text ?? "").Split('\n'))
            {
                string line = raw.Trim().TrimStart('\uFEFF');
                if (line.Length == 0 || line[0] == '#' || line[0] == ';') continue;
                int eq = line.IndexOf('=');
                if (eq <= 0) continue;
                string k = line.Substring(0, eq).Trim();
                string v = line.Substring(eq + 1).Trim();
                if (v.Length >= 2 && v[0] == '"' && v[v.Length - 1] == '"') v = v.Substring(1, v.Length - 2);
                d[k] = v;
            }
            return d;
        }

        /// <summary>Set or replace one key, keeping the rest of the file (and its comments) as it is.</summary>
        public static string Set(string text, string key, string value)
        {
            List<string> lines = new List<string>((text ?? "").Replace("\r", "").Split('\n'));
            bool done = false;
            for (int i = 0; i < lines.Count; i++)
            {
                string l = lines[i].Trim();
                if (l.Length == 0 || l[0] == '#' || l[0] == ';') continue;
                int eq = l.IndexOf('=');
                if (eq > 0 && string.Equals(l.Substring(0, eq).Trim(), key, StringComparison.OrdinalIgnoreCase)) { lines[i] = key + "=" + value; done = true; break; }
            }
            if (!done)
            {
                while (lines.Count > 0 && lines[lines.Count - 1].Trim().Length == 0) lines.RemoveAt(lines.Count - 1);
                lines.Add(key + "=" + value);
            }
            return string.Join("\r\n", lines.ToArray()) + "\r\n";
        }
    }
}
