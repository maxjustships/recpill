// RecPill for macOS (BETA, untested on real hardware): records the microphone + system audio into one .m4a.
//
//   recpill start | stop | toggle [--quiet] [--output DIR]
//   recpill status | version
//
// System audio: Core Audio process tap (macOS 14.4+, "System Audio Recording" permission).
// Microphone: AVAudioEngine on the default input. A Bluetooth hands-free mic is only opened when another app
// already has it open (opening it idle flips the earbuds to headset mode and silences stereo).
import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

let appName = "RecPill"
let version = "0.1.0"
let sampleRate = 48000

// MARK: - paths, config, strings
let fm = FileManager.default
let supportDir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RecPill")
let tmpDir = supportDir.appendingPathComponent("tmp")
let logURL = supportDir.appendingPathComponent("recpill.log")
let toggleLogURL = supportDir.appendingPathComponent("toggle.log")
let pidURL = supportDir.appendingPathComponent("run.pid")
let lockPath = supportDir.appendingPathComponent("run.lock").path
let configURL = supportDir.appendingPathComponent("config.ini")

var quiet = false
var outputFlag: String? = nil
var russian: Bool = (Locale.preferredLanguages.first ?? "en").hasPrefix("ru")
var keepAlive: [Any] = []

func tr(_ en: String, _ ru: String) -> String { russian ? ru : en }

func stamp() -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    return f.string(from: Date())
}

func appendLine(_ url: URL, _ s: String) {
    try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
    let line = stamp() + " " + s + "\n"
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile()
        h.write(line.data(using: .utf8)!)
        try? h.close()
    } else {
        try? line.write(to: url, atomically: false, encoding: .utf8)
    }
}

func log(_ s: String) { appendLine(logURL, s) }

func notify(_ title: String, _ body: String = "") {
    log("notify: \(title) | \(body)")
    if quiet { return }
    func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\""]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
}

struct Settings {
    var outputDir: URL
    var maxHours: Double
}

func loadSettings() -> Settings {
    var cfg = [String: String]()
    if let t = try? String(contentsOf: configURL, encoding: .utf8) { cfg = parseConfig(t) }
    if !quiet, let n = cfg["notifications"]?.lowercased(), ["0", "off", "false", "no"].contains(n) { quiet = true }
    if let l = cfg["language"]?.lowercased() { if l == "ru" { russian = true } else if l == "en" { russian = false } }
    var dir = outputFlag ?? ProcessInfo.processInfo.environment["RECPILL_OUTPUT"] ?? cfg["output_dir"] ?? ""
    if dir.isEmpty { dir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Music/RecPill").path }
    dir = (dir as NSString).expandingTildeInPath
    let hours = Double(cfg["max_hours"] ?? "4") ?? 4
    return Settings(outputDir: URL(fileURLWithPath: dir), maxHours: hours > 0 ? hours : 4)
}

func durText(_ seconds: Double) -> String {
    let s = Int(seconds)
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    if h > 0 { return "\(h) \(tr("h", "ч")) \(m) \(tr("min", "мин"))" }
    if m > 0 { return "\(m) \(tr("min", "мин")) \(sec) \(tr("s", "с"))" }
    return "\(sec) \(tr("s", "с"))"
}

// MARK: - Core Audio helpers
func addr(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func defaultDevice(input: Bool) -> AudioObjectID? {
    var a = addr(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice)
    var id = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id)
    return (st == noErr && id != kAudioObjectUnknown) ? id : nil
}

func deviceString(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var a = addr(selector)
    var s: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    let st = withUnsafeMutablePointer(to: &s) { AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0) }
    return st == noErr ? (s as String) : nil
}

func deviceUID(_ id: AudioObjectID) -> String? { deviceString(id, kAudioDevicePropertyDeviceUID) }
func deviceName(_ id: AudioObjectID) -> String { deviceString(id, kAudioObjectPropertyName) ?? "device \(id)" }

func transportType(_ id: AudioObjectID) -> UInt32 {
    var a = addr(kAudioDevicePropertyTransportType)
    var t: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    _ = AudioObjectGetPropertyData(id, &a, 0, nil, &size, &t)
    return t
}

func isBluetooth(_ id: AudioObjectID) -> Bool {
    let t = transportType(id)
    return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
}

func runningSomewhere(_ id: AudioObjectID) -> Bool {
    var a = addr(kAudioDevicePropertyDeviceIsRunningSomewhere)
    var r: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    _ = AudioObjectGetPropertyData(id, &a, 0, nil, &size, &r)
    return r != 0
}

func allDevices() -> [AudioObjectID] {
    var a = addr(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func hasInput(_ id: AudioObjectID) -> Bool {
    var a = addr(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
    var size: UInt32 = 0
    return AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr && size > 0
}

/// One microphone. Bluetooth hands-free only when another app already has it open.
func pickMic() -> (AudioObjectID?, String) {
    guard let def = defaultDevice(input: true) else { return (nil, "no default input") }
    if !isBluetooth(def) { return (def, "default mic") }
    if runningSomewhere(def) { return (def, "bluetooth mic is in use by a call app") }
    for d in allDevices() where hasInput(d) && !isBluetooth(d) && transportType(d) == kAudioDeviceTransportTypeBuiltIn {
        return (d, "default mic is an idle bluetooth mic -> built-in mic")
    }
    for d in allDevices() where hasInput(d) && !isBluetooth(d) { return (d, "default mic is an idle bluetooth mic -> first wired mic") }
    return (nil, "only an idle bluetooth mic exists; not opening it (it would silence the earbuds)")
}

// MARK: - capture sources
final class Mic {
    private var engine: AVAudioEngine?
    private let mixer: Mixer
    private let track = Track()
    private var resampler: Resampler?
    private(set) var deviceID: AudioObjectID?
    var name = ""

    init(mixer: Mixer) { self.mixer = mixer }

    func start(device: AudioObjectID) throws {
        stop()
        let e = AVAudioEngine()
        let input = e.inputNode
        try input.auAudioUnit.setDeviceID(device)
        let fmt = input.outputFormat(forBus: 0)
        if fmt.sampleRate <= 0 || fmt.channelCount == 0 {
            throw NSError(domain: appName, code: 1, userInfo: [NSLocalizedDescriptionKey: "input has no valid format"])
        }
        resampler = Int(fmt.sampleRate) == sampleRate ? nil : Resampler(inRate: fmt.sampleRate, outRate: Double(sampleRate))
        input.installTap(onBus: 0, bufferSize: 2048, format: fmt) { [weak self] buf, _ in self?.handle(buf) }
        e.prepare()
        try e.start()
        engine = e
        deviceID = device
        name = deviceName(device)
    }

    private func handle(_ buf: AVAudioPCMBuffer) {
        guard let ch = buf.floatChannelData else { return }
        let frames = Int(buf.frameLength)
        let channels = Int(buf.format.channelCount)
        if frames == 0 || channels == 0 { return }
        var mono = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            var s: Float = 0
            for c in 0..<channels { s += ch[c][i] }
            mono[i] = s / Float(channels)
        }
        let out = resampler != nil ? resampler!.process(mono) : mono
        mixer.add(track, out)
    }

    func stop() {
        if let e = engine {
            e.inputNode.removeTap(onBus: 0)
            e.stop()
        }
        engine = nil
        deviceID = nil
    }
}

/// System audio through a Core Audio process tap + a private aggregate device (macOS 14.2+; 14.4+ recommended).
@available(macOS 14.2, *)
final class SystemTap {
    private let mixer: Mixer
    private let track = Track()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var resampler: Resampler?
    private var rate = 48000.0
    private var planar = false
    private let queue = DispatchQueue(label: "recpill.tap", qos: .userInteractive)
    private(set) var outputUID = ""
    var name = ""

    init(mixer: Mixer) { self.mixer = mixer }

    private func fail(_ msg: String, _ st: OSStatus) -> NSError {
        stop()
        return NSError(domain: appName, code: Int(st), userInfo: [NSLocalizedDescriptionKey: "\(msg) (OSStatus \(st))"])
    }

    func start(outputDevice: AudioObjectID) throws {
        stop()
        guard let uid = deviceUID(outputDevice) else {
            throw NSError(domain: appName, code: 2, userInfo: [NSLocalizedDescriptionKey: "no output device UID"])
        }
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        var tid = AudioObjectID(kAudioObjectUnknown)
        var st = AudioHardwareCreateProcessTap(desc, &tid)
        if st != noErr { throw fail("cannot create system audio tap", st) }
        tapID = tid

        var fa = addr(kAudioTapPropertyFormat)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        st = AudioObjectGetPropertyData(tapID, &fa, 0, nil, &size, &asbd)
        if st == noErr {
            rate = asbd.mSampleRate
            planar = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        }
        resampler = Int(rate) == sampleRate ? nil : Resampler(inRate: rate, outRate: Double(sampleRate))

        let tapUUID = desc.uuid.uuidString
        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "RecPill-\(tapUUID)",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tapUUID]],
        ]
        var aid = AudioObjectID(kAudioObjectUnknown)
        st = AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aid)
        if st != noErr { throw fail("cannot create aggregate device", st) }
        aggID = aid

        st = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, queue) { [weak self] _, inData, _, _, _ in
            self?.handle(inData)
        }
        if st != noErr { throw fail("cannot create IO proc", st) }
        st = AudioDeviceStart(aggID, procID)
        if st != noErr { throw fail("cannot start tap", st) }
        outputUID = uid
        name = deviceName(outputDevice)
    }

    private func handle(_ data: UnsafePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: data))
        var mono = [Float]()
        if planar {
            var frames = 0
            for b in list { frames = max(frames, Int(b.mDataByteSize) / 4) }
            if frames == 0 || list.count == 0 { return }
            mono = [Float](repeating: 0, count: frames)
            for b in list {
                guard let p = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let n = min(frames, Int(b.mDataByteSize) / 4)
                for i in 0..<n { mono[i] += p[i] }
            }
            let k = Float(list.count)
            for i in 0..<frames { mono[i] /= k }
        } else {
            guard let b = list.first, let p = b.mData?.assumingMemoryBound(to: Float.self) else { return }
            let ch = max(1, Int(b.mNumberChannels))
            let frames = Int(b.mDataByteSize) / (4 * ch)
            if frames == 0 { return }
            mono = downmixInterleaved(UnsafePointer(p), frames: frames, channels: ch)
        }
        let out = resampler != nil ? resampler!.process(mono) : mono
        mixer.add(track, out)
    }

    func stop() {
        if let p = procID, aggID != kAudioObjectUnknown {
            AudioDeviceStop(aggID, p)
            AudioDeviceDestroyIOProcID(aggID, p)
        }
        procID = nil
        if aggID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggID) }
        aggID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        outputUID = ""
    }
}

// MARK: - encoding: raw s16le mono 48k -> .m4a (AAC)
func convert(pcm: URL, to dest: URL) -> Bool {
    do {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96000,
        ]
        let outFile = try AVAudioFile(forWriting: dest, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let fmt = outFile.processingFormat
        let input = try FileHandle(forReadingFrom: pcm)
        let chunkFrames = sampleRate  // 1 s
        while true {
            let data = input.readData(ofLength: chunkFrames * 2)
            if data.isEmpty { break }
            let frames = data.count / 2
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames)) else { return false }
            buf.frameLength = AVAudioFrameCount(frames)
            let dst = buf.floatChannelData![0]
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let src = raw.bindMemory(to: Int16.self)
                for i in 0..<frames { dst[i] = Float(src[i]) / 32768.0 }
            }
            try outFile.write(from: buf)
        }
        try? input.close()
        return true
    } catch {
        log("convert failed: \(error)")
        return false
    }
}

func fileSize(_ url: URL) -> Int {
    let attrs = try? fm.attributesOfItem(atPath: url.path)
    return (attrs?[.size] as? Int) ?? 0
}

func finalize(pcm: URL, name: String, settings: Settings) -> URL? {
    try? fm.createDirectory(at: settings.outputDir, withIntermediateDirectories: true)
    var final = settings.outputDir.appendingPathComponent(name + ".m4a")
    if fm.fileExists(atPath: final.path) {
        final = settings.outputDir.appendingPathComponent(name + "_" + String(Int(Date().timeIntervalSince1970) % 100000) + ".m4a")
    }
    if convert(pcm: pcm, to: final) && fileSize(final) > 500 {
        try? fm.removeItem(at: pcm)
        return final
    }
    try? fm.removeItem(at: final)
    log("keeping raw audio: \(pcm.path)")
    return nil
}

func recoverLeftovers(settings: Settings) -> URL? {
    var last: URL? = nil
    let files = (try? fm.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: nil)) ?? []
    for f in files.sorted(by: { $0.path < $1.path }) where f.pathExtension == "pcm" {
        if fileSize(f) < sampleRate * 2 { try? fm.removeItem(at: f); continue }
        if let out = finalize(pcm: f, name: f.deletingPathExtension().lastPathComponent, settings: settings) {
            last = out
            appendLine(toggleLogURL, "STOP \(out.path) (recovered)")
        }
    }
    return last
}

// MARK: - run state
func isRunning() -> Bool {
    try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
    let fd = open(lockPath, O_RDWR | O_CREAT, 0o600)
    if fd < 0 { return false }
    defer { close(fd) }
    if flock(fd, LOCK_EX | LOCK_NB) == 0 {
        flock(fd, LOCK_UN)
        return false
    }
    return true
}

var lockFD: Int32 = -1

func runRecorder(settings: Settings) -> Int32 {
    signal(SIGHUP, SIG_IGN)
    try? fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    lockFD = open(lockPath, O_RDWR | O_CREAT, 0o600)
    if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
        notify(tr("Already recording ●", "Запись уже идёт ●"))
        return 0
    }
    if #available(macOS 14.2, *) {
        return runRecorderModern(settings: settings)
    }
    notify(tr("Recording did NOT start", "Запись НЕ началась"), tr("macOS 14.4 or newer is required for system audio.", "Для записи звука системы нужна macOS 14.4 или новее."))
    return 1
}

@available(macOS 14.2, *)
func runRecorderModern(settings: Settings) -> Int32 {
    _ = recoverLeftovers(settings: settings)

    let sem = DispatchSemaphore(value: 0)
    AVCaptureDevice.requestAccess(for: .audio) { _ in sem.signal() }
    sem.wait()

    let nameFmt = DateFormatter()
    nameFmt.locale = Locale(identifier: "en_US_POSIX")
    nameFmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    let name = nameFmt.string(from: Date())
    let pcmURL = tmpDir.appendingPathComponent(name + ".pcm")
    fm.createFile(atPath: pcmURL.path, contents: nil)
    guard let pcmHandle = try? FileHandle(forWritingTo: pcmURL) else {
        notify(tr("Recording did NOT start", "Запись НЕ началась"), "cannot write \(pcmURL.path)")
        return 1
    }
    let t0 = ProcessInfo.processInfo.systemUptime
    let mixer = Mixer(rate: sampleRate, clock: { ProcessInfo.processInfo.systemUptime - t0 }, write: { pcmHandle.write($0) })
    let mic = Mic(mixer: mixer)
    let tap = SystemTap(mixer: mixer)
    var lastNote = ""
    var lastOut: AudioObjectID? = nil

    func reconcile() {
        // system sound follows the default output device
        if let out = defaultDevice(input: false) {
            if tap.outputUID.isEmpty || deviceUID(out) != tap.outputUID {
                do {
                    try tap.start(outputDevice: out)
                    log("open output '\(tap.name)'")
                } catch {
                    if lastOut != out { log("cannot open system audio: \(error.localizedDescription)") }
                }
                lastOut = out
            }
        }
        let (dev, why) = pickMic()
        let note = "mic: \(dev.map(deviceName) ?? "none") (\(why))"
        if note != lastNote { log(note); lastNote = note }
        if let d = dev {
            if mic.deviceID != d {
                do {
                    try mic.start(device: d)
                    log("open mic '\(mic.name)'")
                } catch { log("cannot open mic: \(error.localizedDescription)") }
            }
        } else if mic.deviceID != nil {
            mic.stop()
        }
    }

    reconcile()
    if mic.deviceID == nil && tap.outputUID.isEmpty {
        notify(tr("Recording did NOT start", "Запись НЕ началась"), tr("Could not open any microphone or system sound.", "Не удалось открыть ни микрофон, ни звук компьютера."))
        try? pcmHandle.close()
        try? fm.removeItem(at: pcmURL)
        return 1
    }
    mixer.start()
    try? "\(getpid())".write(to: pidURL, atomically: true, encoding: .utf8)
    appendLine(toggleLogURL, "START \(name)")
    let micLabel = mic.name.isEmpty ? tr("no microphone", "микрофон не найден") : mic.name
    let sysLabel = tap.name.isEmpty ? tr("no system sound", "звук компьютера не найден") : tap.name
    log("START \(name) | mic '\(mic.name)' + output '\(tap.name)' | output \(settings.outputDir.path)")
    notify(tr("Recording ●", "Запись идёт ●"), "\(micLabel) + \(sysLabel)")

    let started = Date()
    var auto = false
    let finish: () -> Void = {
        tap.stop()
        mic.stop()
        mixer.finish()
        try? pcmHandle.synchronize()
        try? pcmHandle.close()
        log("captured \(durText(mixer.seconds))")
        let final = finalize(pcm: pcmURL, name: name, settings: settings)
        if let f = final {
            appendLine(toggleLogURL, "STOP \(f.path) \(durText(mixer.seconds))")
            let title = auto ? tr("Recording stopped automatically ■", "Запись остановлена автоматически ■") : tr("Recording saved ■", "Запись сохранена ■")
            notify(title, "\(f.lastPathComponent) · \(durText(mixer.seconds))")
        } else {
            appendLine(toggleLogURL, "STOP FAILED \(pcmURL.path)")
            notify(tr("Recording was not saved", "Запись не сохранилась"), pcmURL.path)
        }
        try? fm.removeItem(at: pidURL)
        exit(final == nil ? 1 : 0)
    }

    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    let sigTerm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    sigTerm.setEventHandler { finish() }
    sigTerm.resume()
    let sigInt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigInt.setEventHandler { finish() }
    sigInt.resume()

    // follow default devices: re-check twice a second; stop after the maximum length
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
    timer.setEventHandler {
        reconcile()
        if Date().timeIntervalSince(started) > settings.maxHours * 3600 {
            auto = true
            finish()
        }
    }
    timer.resume()
    NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { _ in
        mic.stop()
        reconcile()
    }
    keepAlive = [sigTerm, sigInt, timer]
    dispatchMain()
}

// MARK: - commands
func readPid() -> Int32? {
    guard let s = try? String(contentsOf: pidURL, encoding: .utf8) else { return nil }
    return Int32(s.trimmingCharacters(in: .whitespacesAndNewlines))
}

func cmdStart(settings: Settings) -> Int32 {
    if isRunning() {
        notify(tr("Already recording ●", "Запись уже идёт ●"))
        print("already recording")
        return 0
    }
    try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
    try? fm.removeItem(at: pidURL)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
    var childArgs = ["_run"]
    if quiet { childArgs.append("--quiet") }
    if let o = outputFlag { childArgs += ["--output", o] }
    p.arguments = childArgs
    p.standardInput = FileHandle.nullDevice
    if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile()
        p.standardOutput = h
        p.standardError = h
    }
    do { try p.run() } catch {
        print("cannot start: \(error)")
        return 1
    }
    for _ in 0..<100 {
        usleep(100_000)
        if !p.isRunning {
            print("recording did not start (see \(logURL.path))")
            return p.terminationStatus == 0 ? 1 : p.terminationStatus
        }
        if fm.fileExists(atPath: pidURL.path) && isRunning() {
            print("recording -> \(settings.outputDir.path)")
            return 0
        }
    }
    return 0
}

func cmdStop(settings: Settings) -> Int32 {
    if !isRunning() {
        if let rec = recoverLeftovers(settings: settings) {
            notify(tr("Recording saved ■", "Запись сохранена ■"), rec.lastPathComponent)
            print(rec.path)
        } else {
            notify(tr("Not recording", "Запись не идёт"), tr("Nothing to stop.", "Нечего останавливать."))
            print("not recording")
        }
        return 0
    }
    if let pid = readPid() { kill(pid, SIGTERM) }
    let t0 = Date()
    while isRunning() && Date().timeIntervalSince(t0) < 180 { usleep(250_000) }
    if isRunning() {
        if let pid = readPid() { kill(pid, SIGKILL) }
        usleep(500_000)
        if let rec = recoverLeftovers(settings: settings) { notify(tr("Recording saved ■", "Запись сохранена ■"), rec.lastPathComponent) }
    } else {
        print("stopped")
    }
    return 0
}

func cmdStatus(settings: Settings) -> Int32 {
    let run = isRunning()
    print(run ? "recording" : "idle")
    print("output: \(settings.outputDir.path)")
    if let t = try? String(contentsOf: toggleLogURL, encoding: .utf8), let l = t.split(separator: "\n").last { print("last: \(l)") }
    return run ? 0 : 1
}

// MARK: - main
var mode = "toggle"
var firstArg = true
var argIndex = 1
let argv = CommandLine.arguments
while argIndex < argv.count {
    let a = argv[argIndex]
    if a == "--quiet" || a == "-q" {
        quiet = true
    } else if (a == "--output" || a == "-o") && argIndex + 1 < argv.count {
        outputFlag = argv[argIndex + 1]
        argIndex += 1
    } else if a.hasPrefix("--output=") {
        outputFlag = String(a.dropFirst("--output=".count))
    } else if firstArg {
        mode = a
        firstArg = false
    }
    argIndex += 1
}
let settings = loadSettings()
if mode == "toggle" { mode = isRunning() ? "stop" : "start" }
switch mode {
case "version", "--version", "-v":
    print("RecPill \(version) (macOS beta)")
    exit(0)
case "help", "--help", "-h":
    print("recpill start | stop | toggle [--quiet] [--output DIR] | status | version")
    exit(0)
case "status": exit(cmdStatus(settings: settings))
case "start": exit(cmdStart(settings: settings))
case "stop": exit(cmdStop(settings: settings))
case "_run": exit(runRecorder(settings: settings))
default:
    FileHandle.standardError.write("Unknown command '\(mode)'. Try: start, stop, toggle, status.\n".data(using: .utf8)!)
    exit(2)
}
