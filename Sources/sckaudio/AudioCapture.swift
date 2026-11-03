import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

struct CaptureConfig {
    var sampleRate = 48_000
    var channels = 2
    var includeSelf = false
}

/// SCStream 한 개를 감싸고, 오디오 샘플 버퍼를 파일과 계측기로 보낸다.
/// ScreenCaptureKit에는 오디오 전용 모드가 없어서 디스플레이 필터가 필요하다.
/// 영상은 2x2 / 1fps로 줄이고 프레임은 받는 즉시 버린다(저장하지 않는다).
final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    let meter = LevelMeter()
    /// 시스템이 스트림을 멈췄을 때(사용자 중지 · 권한 회수 등) 호출된다.
    var onStreamStopped: ((Error) -> Void)?

    private let config: CaptureConfig
    private let writer: AudioFileWriter
    private let audioQueue = DispatchQueue(label: "sckaudio.audio")
    private let videoQueue = DispatchQueue(label: "sckaudio.video-discard")
    private var stream: SCStream?

    init(config: CaptureConfig, writer: AudioFileWriter) {
        self.config = config
        self.writer = writer
    }

    /// apps가 비어 있으면 시스템 전체, 있으면 그 앱들의 오디오만 캡처한다.
    func start(display: SCDisplay, apps: [SCRunningApplication]) async throws {
        let filter: SCContentFilter
        if apps.isEmpty {
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        } else {
            filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
        }

        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = !config.includeSelf
        cfg.sampleRate = config.sampleRate
        cfg.channelCount = config.channels
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        cfg.showsCursor = false

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        // .screen 출력을 안 붙이면 시스템이 프레임을 못 보낸다고 로그를 남길 수 있다. 받아서 버린다.
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        try await s.startCapture()
        stream = s
    }

    func stop() async {
        if let s = stream {
            // 시스템이 이미 멈춘 스트림이면 stopCapture가 던진다. 마무리는 계속해야 하므로 무시한다.
            try? await s.stopCapture()
            stream = nil
        }
        audioQueue.sync {}  // 큐에 남은 버퍼를 다 쓴 뒤에 파일을 닫는다
        writer.finish()
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
        guard let pcm = Self.makePCMBuffer(from: sampleBuffer) else {
            meter.noteDropped()
            return
        }
        meter.record(pcm)
        do {
            try writer.write(pcm)
        } catch {
            meter.noteWriteError(error)
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStreamStopped?(error)
    }

    // MARK: 변환

    /// 포맷은 가정하지 않고 샘플 버퍼의 ASBD에서 읽는다.
    private static func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let desc = sampleBuffer.formatDescription,
              var asbd = desc.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: pcm.mutableAudioBufferList
        )
        return status == noErr ? pcm : nil
    }
}
