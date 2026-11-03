import AVFoundation
import Foundation

enum AudioFileFormat: String {
    case wav
    case m4a
}

/// 첫 버퍼의 포맷으로 AVAudioFile을 늦게 연다. 캡처 큐에서만 호출한다.
final class AudioFileWriter {
    let url: URL
    let format: AudioFileFormat
    private var file: AVAudioFile?
    /// finish() 뒤에도 유지된다 — file 참조 유무와 별개로 "파일이 만들어졌는가"를 답한다.
    private(set) var hasWritten = false

    init(url: URL, format: AudioFileFormat) {
        self.url = url
        self.format = format
    }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        if file == nil { file = try open(for: buffer.format) }
        try file?.write(from: buffer)
        hasWritten = true
    }

    /// 파일을 닫는다. AVAudioFile은 해제 시점에 마무리되므로 참조를 놓는 것이 핵심이다.
    func finish() {
        if #available(macOS 15.0, *) { file?.close() }
        file = nil
    }

    private func open(for pcm: AVAudioFormat) throws -> AVAudioFile {
        var settings: [String: Any] = [
            AVSampleRateKey: pcm.sampleRate,
            AVNumberOfChannelsKey: pcm.channelCount,
        ]
        switch format {
        case .wav:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = false
            settings[AVLinearPCMIsNonInterleaved] = false
        case .m4a:
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateKey] = 64_000 * Int(pcm.channelCount)
        }
        // processingFormat을 들어오는 버퍼와 같게 맞춰야 write(from:)가 변환 없이 받는다.
        return try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: pcm.commonFormat,
            interleaved: pcm.isInterleaved
        )
    }
}
