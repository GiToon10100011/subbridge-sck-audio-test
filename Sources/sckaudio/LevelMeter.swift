import AVFoundation
import Foundation

/// 오디오 입력 상태를 재기 위한 계측기. 캡처 큐에서 record(), 상태 타이머에서 snapshot()을 부른다.
final class LevelMeter {
    struct Snapshot {
        var buffers = 0
        var frames: Int64 = 0
        var droppedBuffers = 0
        /// 직전 snapshot 이후 구간의 피크/RMS (선형 0...1)
        var windowPeak: Float = 0
        var windowRMS: Float = 0
        /// 시작 이후 최대 피크
        var maxPeak: Float = 0
        var formatDescription = "-"
        var levelsAvailable = true
        var secondsSinceLastBuffer: TimeInterval?
        var writeError: String?
    }

    private let lock = NSLock()
    private var buffers = 0
    private var frames: Int64 = 0
    private var dropped = 0
    private var windowPeak: Float = 0
    private var windowSumSquares: Double = 0
    private var windowSamples: Int64 = 0
    private var maxPeak: Float = 0
    private var formatDescription = "-"
    private var levelsAvailable = true
    private var lastBufferUptime: TimeInterval?
    private var writeError: String?

    func record(_ pcm: AVAudioPCMBuffer) {
        var peak: Float = 0
        var sumSquares: Double = 0
        var samples: Int64 = 0
        var available = true

        if let data = pcm.floatChannelData {
            let frameCount = Int(pcm.frameLength)
            let stride = pcm.stride
            for channel in 0..<Int(pcm.format.channelCount) {
                let p = data[channel]
                for i in 0..<frameCount {
                    let v = abs(p[i * stride])
                    if v > peak { peak = v }
                    sumSquares += Double(v) * Double(v)
                }
                samples += Int64(frameCount)
            }
        } else {
            available = false
        }

        let f = pcm.format
        let layout = f.isInterleaved ? "interleaved" : "non-interleaved"
        let desc = "\(Int(f.sampleRate))Hz \(f.channelCount)ch \(Self.name(f.commonFormat)) \(layout)"

        lock.lock()
        defer { lock.unlock() }
        buffers += 1
        frames += Int64(pcm.frameLength)
        formatDescription = desc
        levelsAvailable = available
        lastBufferUptime = ProcessInfo.processInfo.systemUptime
        windowPeak = max(windowPeak, peak)
        windowSumSquares += sumSquares
        windowSamples += samples
        maxPeak = max(maxPeak, peak)
    }

    func noteDropped() {
        lock.lock()
        dropped += 1
        lock.unlock()
    }

    func noteWriteError(_ error: Error) {
        lock.lock()
        writeError = error.localizedDescription
        lock.unlock()
    }

    /// resetWindow가 true면 구간 피크/RMS를 비운다. 상태 타이머가 매 틱 호출한다.
    func snapshot(resetWindow: Bool) -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        var s = Snapshot()
        s.buffers = buffers
        s.frames = frames
        s.droppedBuffers = dropped
        s.windowPeak = windowPeak
        s.windowRMS = windowSamples > 0 ? Float((windowSumSquares / Double(windowSamples)).squareRoot()) : 0
        s.maxPeak = maxPeak
        s.formatDescription = formatDescription
        s.levelsAvailable = levelsAvailable
        s.secondsSinceLastBuffer = lastBufferUptime.map { ProcessInfo.processInfo.systemUptime - $0 }
        s.writeError = writeError
        if resetWindow {
            windowPeak = 0
            windowSumSquares = 0
            windowSamples = 0
        }
        return s
    }

    private static func name(_ f: AVAudioCommonFormat) -> String {
        switch f {
        case .pcmFormatFloat32: return "Float32"
        case .pcmFormatFloat64: return "Float64"
        case .pcmFormatInt16: return "Int16"
        case .pcmFormatInt32: return "Int32"
        default: return "other"
        }
    }
}

func dbfs(_ linear: Float) -> String {
    linear <= 1e-6 ? "-inf" : String(format: "%.1f", 20 * log10(Double(linear)))
}
