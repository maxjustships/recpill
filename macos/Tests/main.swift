// Unit tests for Core.swift. Build + run: see .github/workflows/ci.yml (swiftc Core.swift Tests/main.swift)
import Foundation

var checks = 0
var fails = 0

func ok(_ cond: Bool, _ what: String) {
    checks += 1
    if !cond { fails += 1; print("FAIL: \(what)") }
}

func near(_ a: Double, _ b: Double, _ tol: Double, _ what: String) {
    ok(abs(a - b) <= tol, "\(what) (got \(a), want \(b) ±\(tol))")
}

func sine(_ hz: Double, _ rate: Int, _ n: Int, _ amp: Double) -> [Float] {
    (0..<n).map { Float(amp * sin(2 * Double.pi * hz * Double($0) / Double(rate))) }
}

func zeroCrossings(_ f: [Float]) -> Int {
    var z = 0
    for i in 1..<f.count where (f[i - 1] < 0) != (f[i] < 0) { z += 1 }
    return z
}

func decode(_ d: Data) -> [Int16] {
    d.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
}

// --- Resampler
do {
    let s = sine(440, 44100, 44100, 0.5)
    let one = Resampler(inRate: 44100, outRate: 48000)
    let whole = one.process(s)
    near(Double(whole.count), 48000, 4, "44.1k -> 48k gives ~48000 samples for 1 s")
    near(Double(zeroCrossings(whole)), 880, 2, "440 Hz tone survives resampling")

    let chunked = Resampler(inRate: 44100, outRate: 48000)
    var joined = [Float]()
    let sizes = [441, 480, 1000, 7, 4410, 13]
    var pos = 0, k = 0
    while pos < s.count {
        let c = min(sizes[k % sizes.count], s.count - pos)
        k += 1
        joined += chunked.process(Array(s[pos..<pos + c]))
        pos += c
    }
    near(Double(joined.count), Double(whole.count), 3, "chunked output length matches one-shot")
    var maxDiff: Float = 0
    for i in 0..<(min(joined.count, whole.count) - 2) { maxDiff = max(maxDiff, abs(joined[i] - whole[i])) }
    ok(maxDiff < 0.01, "chunked output equals one-shot output (max diff \(maxDiff))")

    let down = Resampler(inRate: 96000, outRate: 48000)
    near(Double(down.process(sine(1000, 96000, 96000, 0.5)).count), 48000, 4, "96k -> 48k halves the length")
    ok(Resampler(inRate: 44100, outRate: 48000).process([]).isEmpty, "empty packet is a no-op")
}

// --- Mixer (tiny rate keeps it instant, fake clock keeps it deterministic)
func makeMixer(_ clock: @escaping () -> Double) -> (Mixer, () -> Data) {
    var out = Data()
    let m = Mixer(rate: 1000, clock: clock, write: { out.append($0) })
    return (m, { out })
}

do {
    var now = 0.0
    let (mx, out) = makeMixer({ now })
    let a = Track(), b = Track()
    now = 2.0
    mx.add(a, [Float](repeating: 0.25, count: 500))
    mx.add(b, [Float](repeating: 0.5, count: 500))
    mx.flush(margin: 0)
    let s = decode(out())
    ok(s.count == 2000, "flush writes everything up to now (\(s.count))")
    ok(s[100] == 0 && s[1499] == 0, "silence before the first packet")
    near(Double(s[1500]) / 32767, 0.75, 1e-3, "two sources are summed")
    near(Double(s[1999]) / 32767, 0.75, 1e-3, "sum holds to the end of the packet")
}

do {
    var now = 0.0
    let (mx, out) = makeMixer({ now })
    let c = Track(), d = Track()
    now = 0.1
    mx.add(c, [Float](repeating: 0.9, count: 100))
    mx.add(d, [Float](repeating: 0.9, count: 100))
    mx.flush(margin: 0)
    let s = decode(out())
    ok(s.count == 100 && s[50] == 32767, "sum over full scale is clipped to +32767")
}

do {
    var now = 0.0
    let (mx, out) = makeMixer({ now })
    let gone = Track(), stays = Track()
    now = 0.1
    mx.add(gone, [Float](repeating: 0.5, count: 100))
    mx.add(stays, [Float](repeating: 0.25, count: 100))
    now = 0.2
    mx.add(stays, [Float](repeating: 0.25, count: 100))
    mx.flush(margin: 0)
    let s = decode(out())
    near(Double(s[50]) / 32767, 0.75, 1e-3, "both sources heard while both are alive")
    near(Double(s[150]) / 32767, 0.25, 1e-3, "only the surviving source after the other left")
    ok(gone.resyncs == 0 && stays.resyncs == 0, "steady sources are not resynced")
}

do {
    var now = 0.0
    let (mx, _) = makeMixer({ now })
    let g = Track()
    now = 1.0
    mx.add(g, [Float](repeating: 0.1, count: 100))
    now = 1.05
    mx.add(g, [Float](repeating: 0.1, count: 100))
    ok(g.resyncs == 0, "small timing jitter is absorbed")
    now = 3.0
    mx.add(g, [Float](repeating: 0.1, count: 100))
    ok(g.resyncs == 1, "large drift triggers a resync")
}

do {
    var now = 0.0
    let (mx, out) = makeMixer({ now })
    now = 1.0
    mx.flush(margin: 0)
    now = 1000.0
    mx.flush(margin: 0)
    ok(out().count / 2 < 1500, "a long sleep is cut out (\(out().count / 2) samples)")
}

do {
    var now = 0.0
    let (mx, out) = makeMixer({ now })
    now = 3.0
    mx.flush(margin: 1000)
    ok(out().count / 2 == 2000, "margin of one second is kept behind 'now'")
    near(mx.seconds, 2.0, 1e-9, "seconds reports flushed audio")
}

// --- config
do {
    let c = parseConfig("\u{FEFF}# comment\r\noutput_dir = \"/tmp/my calls\"\r\nMAX_HOURS=2.5\r\n;x=1\r\nbroken\r\n")
    ok(c["output_dir"] == "/tmp/my calls", "quoted value with spaces")
    ok(c["max_hours"] == "2.5", "keys are case-insensitive")
    ok(c["x"] == nil && c["broken"] == nil, "comments and junk lines are skipped")
}

// --- downmix
do {
    let data: [Float] = [0.5, 0.25, -1, 1]
    let m = data.withUnsafeBufferPointer { downmixInterleaved($0.baseAddress!, frames: 2, channels: 2) }
    near(Double(m[0]), 0.375, 1e-6, "interleaved stereo average")
    near(Double(m[1]), 0, 1e-6, "interleaved stereo cancels")
}

print(fails == 0 ? "OK: \(checks) checks passed" : "\(fails) of \(checks) checks FAILED")
exit(fails == 0 ? 0 : 1)
