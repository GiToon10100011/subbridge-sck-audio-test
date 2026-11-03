import AVFoundation
import Foundation

/// 화면 녹화 권한 없이 "샘플 버퍼 이후" 경로(계측 → 파일 쓰기 → 읽기)를 합성 사인파로 확인한다.
/// SCStream 자체(권한 · 앱 필터 · 실제 소리)는 검증하지 못한다 — 그건 `record` 로 확인한다.
enum SelfTest {
    private static let rate = 48_000.0
    private static let seconds = 2.0
    private static let amplitude: Float = 0.5
    private static let chunk = 1024

    static func run() -> Int32 {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sckaudio-selftest-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            print("FAIL  임시 폴더를 만들 수 없음: \(error.localizedDescription)")
            return 1
        }
        defer { try? FileManager.default.removeItem(at: dir) }

        var ok = true
        for format in [AudioFileFormat.wav, .m4a] {
            ok = verify(format, in: dir) && ok
        }
        print(ok ? "selftest 통과" : "selftest 실패")
        return ok ? 0 : 1
    }

    private static func verify(_ format: AudioFileFormat, in dir: URL) -> Bool {
        let label = format.rawValue.uppercased()
        let total = Int(rate * seconds)
        guard let pcmFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false
        ) else {
            print("FAIL  [\(label)] 포맷 생성 실패")
            return false
        }

        let url = dir.appendingPathComponent("tone.\(format.rawValue)")
        let writer = AudioFileWriter(url: url, format: format)
        let meter = LevelMeter()
        var written = 0
        var chunks = 0

        do {
            while written < total {
                let n = min(chunk, total - written)
                guard let buf = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(n)),
                      let data = buf.floatChannelData else { throw SelfTestError("버퍼 생성 실패") }
                buf.frameLength = AVAudioFrameCount(n)
                for ch in 0..<2 {
                    for i in 0..<n {
                        data[ch][i] = amplitude * Float(sin(2 * Double.pi * 440 * Double(written + i) / rate))
                    }
                }
                meter.record(buf)
                try writer.write(buf)
                written += n
                chunks += 1
            }
            writer.finish()

            let snap = meter.snapshot(resetWindow: true)
            let again = meter.snapshot(resetWindow: false)

            let file = try AVAudioFile(forReading: url)
            guard let rb = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)) else {
                throw SelfTestError("읽기 버퍼 생성 실패")
            }
            try file.read(into: rb)
            var readPeak: Float = 0
            if let d = rb.floatChannelData {
                for ch in 0..<Int(rb.format.channelCount) {
                    for i in 0..<Int(rb.frameLength) { readPeak = max(readPeak, abs(d[ch][i])) }
                }
            }

            let lengthTolerance = format == .wav ? 0 : 4096  // AAC는 프라이밍/패딩 프레임이 붙는다
            let peakTolerance: Float = format == .wav ? 0.01 : 0.1

            let checks: [(String, Bool)] = [
                ("계측 버퍼 수 \(snap.buffers) == \(chunks)", snap.buffers == chunks),
                ("계측 프레임 수 \(snap.frames) == \(total)", snap.frames == Int64(total)),
                ("계측 최대 피크 \(dbfs(snap.maxPeak)) dBFS ≈ 0.5", abs(snap.maxPeak - amplitude) < 0.01),
                ("snapshot(resetWindow:) 뒤 구간 피크가 0", again.windowPeak == 0),
                ("파일 샘플레이트 \(Int(file.fileFormat.sampleRate)) == 48000", file.fileFormat.sampleRate == rate),
                ("파일 채널 수 \(file.fileFormat.channelCount) == 2", file.fileFormat.channelCount == 2),
                ("파일 길이 \(file.length) ≈ \(total) (±\(lengthTolerance))",
                 abs(Int(file.length) - total) <= lengthTolerance),
                ("읽어 온 피크 \(dbfs(readPeak)) dBFS ≈ 0.5", abs(readPeak - amplitude) <= peakTolerance),
            ]
            var ok = true
            for (name, pass) in checks {
                print("\(pass ? "PASS" : "FAIL")  [\(label)] \(name)")
                ok = ok && pass
            }
            return ok
        } catch {
            print("FAIL  [\(label)] \(error.localizedDescription)")
            return false
        }
    }
}

private struct SelfTestError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
