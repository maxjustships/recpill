// RecPill core: pure audio logic with no CoreAudio dependency, so it can be unit-tested anywhere Swift runs.
//   Resampler - linear-interpolation resampler that is continuous across packets
//   Track     - per-source cursor on the shared timeline
//   Mixer     - sums all tracks onto one wall-clock timeline and writes s16le mono through a callback
//   parseConfig - key=value config file parser
import Foundation

public final class Resampler {
    private let step: Double
    private var t: Double = 0
    private var last: Float = 0

    public init(inRate: Double, outRate: Double) { step = inRate / outRate }

    /// Resample one packet; interpolation state carries over to the next packet.
    public func process(_ mono: [Float]) -> [Float] {
        let frames = mono.count
        if frames == 0 { return [] }
        var out = [Float]()
        out.reserveCapacity(Int(Double(frames) / step) + 4)
        while t < Double(frames - 1) {
            let i = Int(t.rounded(.down))
            let f = Float(t - Double(i))
            let a: Float = i < 0 ? last : mono[i]
            let c = mono[i + 1]
            out.append(a + (c - a) * f)
            t += step
        }
        t -= Double(frames)
        last = mono[frames - 1]
        return out
    }
}

public final class Track {
    public var pos: Int = 0
    public var started = false
    public var resyncs = 0
    public init() {}
}

public final class Mixer {
    private let rate: Int
    private let n: Int
    private let slack: Int
    private var acc: [Float]
    private let lock = NSLock()
    private let clock: () -> Double
    private let write: (Data) -> Void
    private var skipped = 0
    private var lastNow = 0
    public private(set) var flushed = 0
    private var timer: DispatchSourceTimer?

    public init(rate: Int, clock: @escaping () -> Double, write: @escaping (Data) -> Void) {
        self.rate = rate
        self.n = rate * 8
        self.slack = rate / 4
        self.acc = [Float](repeating: 0, count: rate * 8)
        self.clock = clock
        self.write = write
    }

    public var seconds: Double { Double(flushed) / Double(rate) }

    private func now() -> Int { Int(clock() * Double(rate)) - skipped }

    public func start() {
        let q = DispatchQueue(label: "recpill.mixer", qos: .userInitiated)
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 0.2, repeating: 0.2)
        t.setEventHandler { [weak self] in self?.flush(margin: self?.rate ?? 0) }
        t.resume()
        timer = t
    }

    public func add(_ track: Track, _ samples: [Float]) {
        let count = samples.count
        if count == 0 { return }
        lock.lock()
        defer { lock.unlock() }
        let target = now() - count
        if !track.started || track.pos < target - slack || track.pos > target + slack {
            if track.started { track.resyncs += 1 }
            track.pos = target
            track.started = true
        }
        let p = track.pos
        let off = p < flushed ? min(count, flushed - p) : 0
        if p + count - flushed < n {
            var i = off
            while i < count {
                var idx = (p + i) % n
                if idx < 0 { idx += n }
                acc[idx] += samples[i]
                i += 1
            }
        }
        track.pos = p + count
    }

    /// Write everything older than `margin` samples before "now". Public for tests.
    public func flush(margin: Int) {
        lock.lock()
        var cur = now()
        if cur - lastNow > 5 * rate {  // machine slept: cut the gap
            skipped += cur - lastNow - rate / 4
            cur = now()
        }
        lastNow = cur
        let end = cur - margin
        let count = min(end - flushed, n)
        if count <= 0 { lock.unlock(); return }
        var out = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            let idx = (flushed + i) % n
            var v = acc[idx]
            acc[idx] = 0
            if v > 1 { v = 1 } else if v < -1 { v = -1 }
            out[i] = Int16(v * 32767)
        }
        flushed += count
        lock.unlock()
        let data = out.withUnsafeBufferPointer { Data(buffer: $0) }
        write(data)
    }

    public func finish() {
        timer?.cancel()
        timer = nil
        flush(margin: 0)
    }
}

/// key=value lines, '#' or ';' comments, case-insensitive keys, values may be quoted.
public func parseConfig(_ text: String) -> [String: String] {
    var d = [String: String]()
    for raw in text.components(separatedBy: "\n") {
        var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("\u{FEFF}") { line.removeFirst() }
        if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
        guard let eq = line.firstIndex(of: "=") else { continue }
        let k = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces).lowercased()
        var v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if v.count >= 2 && v.hasPrefix("\"") && v.hasSuffix("\"") { v = String(v.dropFirst().dropLast()) }
        if !k.isEmpty { d[k] = v }
    }
    return d
}

/// Mono float samples from an interleaved or planar float32 packet.
public func downmixInterleaved(_ p: UnsafePointer<Float>, frames: Int, channels: Int) -> [Float] {
    var out = [Float](repeating: 0, count: frames)
    if channels <= 0 { return out }
    for i in 0..<frames {
        var s: Float = 0
        for c in 0..<channels { s += p[i * channels + c] }
        out[i] = s / Float(channels)
    }
    return out
}
