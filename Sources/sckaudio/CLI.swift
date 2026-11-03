import CoreGraphics
import Foundation
import ScreenCaptureKit

struct CLIError: Error {
    let message: String
    var exitCode: Int32 = 1
}

struct RecordOptions {
    var apps: [String] = []
    var output: URL?
    var format: AudioFileFormat?
    var duration: TimeInterval?
    var config = CaptureConfig()
}

enum StopReason {
    case signal
    case duration
    case streamError(Error)
}

enum CLI {
    static let usage = """
    sckaudio — ScreenCaptureKit 시스템 오디오 캡처 검증 도구 (영상은 저장하지 않음)

    사용법:
      sckaudio check [--request]       화면 녹화 권한 상태 확인 (--request: 권한 요청 창을 띄움)
      sckaudio list                    실행 중인 앱 목록 (--app 에 쓸 이름 · bundle id · pid)
      sckaudio record [옵션]           오디오 캡처 → 파일 저장. Ctrl-C 로 종료
      sckaudio selftest                권한 없이 계측기 · WAV/M4A 쓰기 경로를 합성 신호로 검증

    record 옵션:
      --app <이름|bundle id|pid>       이 앱의 오디오만 캡처 (여러 번 지정 가능). 생략하면 시스템 전체
      --out, -o <경로>                 출력 파일 (기본: ./capture-<시각>.wav)
      --format wav|m4a                 기본 wav (16-bit PCM). m4a 는 AAC
      --duration, -d <초>              지정 시간 뒤 자동 종료
      --rate <Hz>                      샘플레이트 (기본 48000)
      --channels 1|2                   채널 수 (기본 2)
      --include-self                   이 프로세스의 오디오도 포함 (기본: 제외)
    """

    static func run(_ args: [String]) async -> Int32 {
        do {
            switch try parse(args) {
            case .help:
                print(usage)
                return 0
            case .check(let request):
                return check(request: request)
            case .list:
                return try await list()
            case .selftest:
                return SelfTest.run()
            case .record(let options):
                return try await record(options)
            }
        } catch let e as CLIError {
            fputs("오류: \(e.message)\n", stderr)
            if e.exitCode == 64 { fputs("\n\(usage)\n", stderr) }
            return e.exitCode
        } catch {
            fputs("오류: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    // MARK: 인자 파싱

    enum Command {
        case help
        case check(request: Bool)
        case list
        case selftest
        case record(RecordOptions)
    }

    static func parse(_ args: [String]) throws -> Command {
        guard let first = args.first else { return .help }
        let rest = Array(args.dropFirst())
        switch first {
        case "help", "-h", "--help": return .help
        case "check": return .check(request: rest.contains("--request"))
        case "list": return .list
        case "selftest": return .selftest
        case "record": return .record(try parseRecord(rest))
        default: throw CLIError(message: "알 수 없는 명령: \(first)", exitCode: 64)
        }
    }

    static func parseRecord(_ args: [String]) throws -> RecordOptions {
        var o = RecordOptions()
        var i = 0
        func value(_ flag: String) throws -> String {
            i += 1
            guard i < args.count else { throw CLIError(message: "\(flag) 에 값이 필요합니다", exitCode: 64) }
            return args[i]
        }
        while i < args.count {
            let flag = args[i]
            switch flag {
            case "--app":
                o.apps.append(try value(flag))
            case "--out", "-o":
                let path = (try value(flag) as NSString).expandingTildeInPath
                o.output = URL(fileURLWithPath: path)
            case "--format":
                guard let f = AudioFileFormat(rawValue: try value(flag).lowercased()) else {
                    throw CLIError(message: "--format 은 wav 또는 m4a", exitCode: 64)
                }
                o.format = f
            case "--duration", "-d":
                guard let d = Double(try value(flag)), d > 0 else {
                    throw CLIError(message: "--duration 은 0보다 큰 초 단위 숫자", exitCode: 64)
                }
                o.duration = d
            case "--rate":
                guard let r = Int(try value(flag)), r > 0 else {
                    throw CLIError(message: "--rate 는 양의 정수(Hz)", exitCode: 64)
                }
                o.config.sampleRate = r
            case "--channels":
                guard let c = Int(try value(flag)), (1...2).contains(c) else {
                    throw CLIError(message: "--channels 는 1 또는 2", exitCode: 64)
                }
                o.config.channels = c
            case "--include-self":
                o.config.includeSelf = true
            default:
                throw CLIError(message: "알 수 없는 옵션: \(flag)", exitCode: 64)
            }
            i += 1
        }
        return o
    }

    // MARK: check

    static func check(request: Bool) -> Int32 {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        print("macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)")
        let env = ProcessInfo.processInfo.environment
        let host = env["__CFBundleIdentifier"] ?? env["TERM_PROGRAM"] ?? "알 수 없음"
        print("실행 호스트(권한을 줄 앱으로 추정): \(host)")
        var granted = CGPreflightScreenCaptureAccess()
        print("화면 녹화 권한: \(granted ? "허용됨" : "없음")")
        if !granted && request {
            print("권한 요청 창을 띄웁니다. 허용한 뒤 호스트 앱을 완전히 종료했다가 다시 실행하세요.")
            granted = CGRequestScreenCaptureAccess()
        }
        if !granted {
            print("→ 시스템 설정 > 개인정보 보호 및 보안 > 화면 및 시스템 오디오 녹음 에서 위 호스트 앱을 켜세요.")
        }
        return granted ? 0 : 1
    }

    // MARK: list

    static func list() async throws -> Int32 {
        let content = try await shareableContent()
        var windowCount: [pid_t: Int] = [:]
        for w in content.windows {
            if let pid = w.owningApplication?.processID { windowCount[pid, default: 0] += 1 }
        }
        let apps = content.applications
            .filter { !$0.applicationName.isEmpty }
            .sorted { $0.applicationName.localizedCaseInsensitiveCompare($1.applicationName) == .orderedAscending }
        for app in apps {
            let name = app.applicationName.padding(toLength: 28, withPad: " ", startingAt: 0)
            let pid = String(app.processID).padding(toLength: 7, withPad: " ", startingAt: 0)
            print("\(name) pid \(pid) \(app.bundleIdentifier)  (창 \(windowCount[app.processID] ?? 0)개)")
        }
        print("\n앱 \(apps.count)개 / 디스플레이 \(content.displays.count)개")
        return 0
    }

    // MARK: record

    static func record(_ o: RecordOptions) async throws -> Int32 {
        // 권한이 필요 없는 인자 검증을 먼저 끝낸다.
        let format = try resolveFormat(o)
        let url = o.output ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("capture-\(timestamp()).\(format.rawValue)")
        if FileManager.default.fileExists(atPath: url.path) {
            throw CLIError(message: "이미 존재하는 파일입니다: \(url.path)")
        }

        if !CGPreflightScreenCaptureAccess() {
            fputs("경고: 화면 녹화 권한이 없는 것으로 보입니다. 계속 시도합니다 (`sckaudio check` 참고).\n", stderr)
        }

        let content = try await shareableContent()
        guard let display = content.displays.first else {
            throw CLIError(message: "캡처할 디스플레이가 없습니다")
        }
        let apps = try resolveApps(o.apps, in: content)

        let writer = AudioFileWriter(url: url, format: format)
        let capture = AudioCapture(config: o.config, writer: writer)

        let (events, continuation) = AsyncStream.makeStream(of: StopReason.self)
        capture.onStreamStopped = { continuation.yield(.streamError($0)) }

        let queue = DispatchQueue(label: "sckaudio.control")
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let signalSources = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
            let src = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            src.setEventHandler { continuation.yield(.signal) }
            src.resume()
            return src
        }

        do {
            try await capture.start(display: display, apps: apps)
        } catch {
            throw translate(error)
        }

        let target = apps.isEmpty
            ? "시스템 전체"
            : apps.map { "\($0.applicationName)(pid \($0.processID))" }.joined(separator: ", ")
        let requestedFormat = "\(o.config.sampleRate)Hz \(o.config.channels)ch"
        fputs("캡처 시작 — 대상: \(target)\n", stderr)
        fputs("요청 포맷: \(requestedFormat) → \(url.path)\n", stderr)
        fputs("Ctrl-C 로 종료\(o.duration.map { " (또는 \(Int($0))초 뒤 자동 종료)" } ?? "")\n\n", stderr)

        let reporter = StatusReporter(meter: capture.meter, sampleRate: Double(o.config.sampleRate))
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { reporter.tick() }
        timer.resume()

        if let d = o.duration {
            queue.asyncAfter(deadline: .now() + d) { continuation.yield(.duration) }
        }

        var streamError: Error?
        for await reason in events {
            if case .streamError(let e) = reason { streamError = e }
            break
        }

        timer.cancel()
        signalSources.forEach { $0.cancel() }
        await capture.stop()
        reporter.finish()

        if let e = streamError {
            fputs("\n스트림이 시스템에 의해 중지됨: \(e.localizedDescription)\n", stderr)
        }
        return reporter.summary(url: url, wroteFile: writer.hasWritten)
    }

    // MARK: 도우미

    static func shareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.current
        } catch {
            throw translate(error)
        }
    }

    /// 권한 거부는 원인과 해결 방법을 같이 알려준다.
    static func translate(_ error: Error) -> Error {
        let ns = error as NSError
        if ns.domain == SCStreamErrorDomain && ns.code == SCStreamError.Code.userDeclined.rawValue {
            return CLIError(message: """
            화면 녹화 권한이 거부되었습니다 (SCStreamError -3801).
              1) 시스템 설정 > 개인정보 보호 및 보안 > 화면 및 시스템 오디오 녹음
              2) 이 명령을 실행한 터미널 앱(`sckaudio check` 가 호스트를 알려줍니다)을 켠다
              3) 그 터미널 앱을 완전히 종료(Cmd-Q)했다가 다시 실행한다
            """)
        }
        return CLIError(message: "\(ns.localizedDescription) (\(ns.domain) \(ns.code))")
    }

    static func resolveApps(_ queries: [String], in content: SCShareableContent) throws -> [SCRunningApplication] {
        var result: [SCRunningApplication] = []
        for q in queries {
            let lower = q.lowercased()
            let pid = Int32(q)
            let matches = content.applications.filter { app in
                if let pid, app.processID == pid { return true }
                return app.bundleIdentifier.lowercased() == lower
                    || app.applicationName.lowercased().contains(lower)
            }
            guard !matches.isEmpty else {
                throw CLIError(message: "'\(q)' 와 일치하는 앱이 없습니다. 앱을 실행한 뒤 `sckaudio list` 로 이름을 확인하세요.")
            }
            for m in matches where !result.contains(where: { $0.processID == m.processID }) {
                result.append(m)
            }
        }
        return result
    }

    static func resolveFormat(_ o: RecordOptions) throws -> AudioFileFormat {
        let fromExtension = o.output.flatMap { AudioFileFormat(rawValue: $0.pathExtension.lowercased()) }
        if let f = o.format {
            if let e = fromExtension, e != f {
                throw CLIError(message: "--format \(f.rawValue) 와 출력 파일 확장자가 다릅니다")
            }
            return f
        }
        if let out = o.output, fromExtension == nil {
            throw CLIError(message: "출력 파일 확장자는 .wav 또는 .m4a 여야 합니다: \(out.lastPathComponent)")
        }
        return fromExtension ?? .wav
    }

    static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}

/// 0.5초마다 상태 한 줄을 stderr 로 내보내고, 종료 때 상태별 누적 시간을 요약한다.
final class StatusReporter {
    enum State: String {
        case waiting = "WAITING"   // 아직 오디오 버퍼가 한 번도 안 옴
        case active = "ACTIVE"     // 소리가 들어오는 중
        case silent = "SILENT"     // 버퍼는 오지만 전부 무음
        case stalled = "STALLED"   // 버퍼가 끊김
    }

    private static let tick = 0.5
    private static let silentPeak: Float = 0.0003  // 약 -70 dBFS
    private static let stallSeconds = 1.5

    private let meter: LevelMeter
    private let sampleRate: Double
    private let started = ProcessInfo.processInfo.systemUptime
    private let isTTY = isatty(STDERR_FILENO) != 0
    private var ticks: [State: Int] = [:]
    private var printedAny = false

    init(meter: LevelMeter, sampleRate: Double) {
        self.meter = meter
        self.sampleRate = sampleRate
    }

    func tick() {
        let s = meter.snapshot(resetWindow: true)
        let state = Self.state(of: s)
        ticks[state, default: 0] += 1

        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let captured = Double(s.frames) / sampleRate
        let levels = s.levelsAvailable
            ? "peak \(dbfs(s.windowPeak)) dBFS  rms \(dbfs(s.windowRMS)) dBFS  max \(dbfs(s.maxPeak)) dBFS"
            : "레벨 계산 불가(Float32 아님)"
        var line = "[경과 \(Self.clock(elapsed)) | 오디오 \(Self.clock(captured))] \(state.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0))  \(levels)  | 버퍼 \(s.buffers)  \(s.formatDescription)"
        if s.droppedBuffers > 0 { line += "  변환실패 \(s.droppedBuffers)" }
        if let err = s.writeError { line += "  쓰기오류: \(err)" }

        if isTTY {
            fputs("\r\u{1B}[2K\(line)", stderr)
        } else if Int(elapsed / Self.tick) % 2 == 0 {
            fputs("\(line)\n", stderr)  // 파이프로 받을 땐 1초에 한 줄
        }
        printedAny = true
    }

    func finish() {
        if isTTY && printedAny { fputs("\n", stderr) }
    }

    /// 요약을 출력하고 종료 코드를 돌려준다. 오디오 버퍼가 하나도 없었으면 2.
    func summary(url: URL, wroteFile: Bool) -> Int32 {
        let s = meter.snapshot(resetWindow: false)
        func secs(_ st: State) -> String { String(format: "%.1f", Double(ticks[st] ?? 0) * Self.tick) }

        print("── 요약 ──")
        print("상태별 시간(초): ACTIVE \(secs(.active)) / SILENT \(secs(.silent)) / STALLED \(secs(.stalled)) / WAITING \(secs(.waiting))")
        print("받은 버퍼 \(s.buffers)개, 프레임 \(s.frames) (\(String(format: "%.2f", Double(s.frames) / sampleRate))초 분량), 포맷 \(s.formatDescription)")
        print("최대 피크 \(dbfs(s.maxPeak)) dBFS")

        guard wroteFile else {
            print("파일: 만들어지지 않음 — 오디오 버퍼가 한 번도 도착하지 않았습니다.")
            return 2
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        print("파일: \(url.path) (\(size) bytes)")
        if s.maxPeak < Self.silentPeak {
            print("주의: 파일은 만들어졌지만 전 구간이 무음입니다. 확인할 것: 대상이 실제로 소리를 냈는지, 시스템 출력이 음소거/볼륨 0은 아닌지, 서비스가 오디오를 막고 있지는 않은지.")
        }
        return 0
    }

    private static func state(of s: LevelMeter.Snapshot) -> State {
        guard let age = s.secondsSinceLastBuffer else { return .waiting }
        if age > stallSeconds { return .stalled }
        if s.levelsAvailable && s.windowPeak < silentPeak { return .silent }
        return .active
    }

    private static func clock(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        return String(format: "%02d:%04.1f", m, seconds - Double(m * 60))
    }
}
