import CoreGraphics
import Foundation
import ScreenCaptureKit

enum PickerOutcome {
    case selected(SCContentFilter)
    case cancelled    // 사용자가 선택기에서 취소했다
    case interrupted  // 선택을 기다리던 중 cancel()로 중단됐다 (Ctrl-C)
}

struct PickerError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// macOS 네이티브 콘텐츠 선택기를 단일 창 모드로 띄우고, 결과를 한 번만 돌려준다.
@available(macOS 14.0, *)
final class ContentPicker: NSObject, SCContentSharingPickerObserver {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PickerOutcome, Error>?
    /// pick()이 대기에 들어가기 전에 먼저 도착한 결과
    private var early: Result<PickerOutcome, Error>?
    private var done = false

    /// 선택기를 띄우고 선택 · 취소 · 실패 중 하나로 정확히 한 번 끝난다.
    func pick() async throws -> PickerOutcome {
        if let result = peekEarly() { return try result.get() }

        let picker = SCContentSharingPicker.shared
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = .singleWindow
        config.allowsChangingSelectedContent = false  // 캡처가 시작된 뒤에는 선택을 바꾸지 못하게 한다
        picker.defaultConfiguration = config
        picker.add(self)
        picker.isActive = true

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<PickerOutcome, Error>) in
            lock.lock()
            if let early {
                lock.unlock()
                cleanup()  // 설정하는 사이에 끝난 경우, 방금 켠 선택기를 다시 정리한다
                cont.resume(with: early)
                return
            }
            continuation = cont
            lock.unlock()
            DispatchQueue.main.async { SCContentSharingPicker.shared.present() }
        }
    }

    /// 선택을 기다리는 중이면 중단시킨다 (Ctrl-C). pick() 전에 불러도 안전하다.
    func cancel() {
        finish(.success(.interrupted))
    }

    // MARK: SCContentSharingPickerObserver

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        finish(.success(.cancelled))
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        guard filter.style == .window else {
            finish(.failure(PickerError(message: "창이 아닌 대상이 선택되었습니다 (스타일: \(Self.styleName(filter.style)))")))
            return
        }
        finish(.success(.selected(filter)))
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        finish(.failure(error))
    }

    // MARK: 내부

    private func peekEarly() -> Result<PickerOutcome, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return early
    }

    private func finish(_ result: Result<PickerOutcome, Error>) {
        lock.lock()
        guard !done else {
            lock.unlock()
            return
        }
        done = true
        let cont = continuation
        continuation = nil
        if cont == nil { early = result }
        lock.unlock()

        cleanup()
        cont?.resume(with: result)
    }

    private func cleanup() {
        let picker = SCContentSharingPicker.shared
        picker.isActive = false
        picker.remove(self)
    }

    // MARK: 선택 결과 설명

    /// 선택된 필터를 사람이 읽을 줄로 풀어 쓴다. 앱·창 정보는 macOS 15.2부터 제공된다.
    static func describe(_ filter: SCContentFilter) -> [String] {
        let r = filter.contentRect
        var lines = ["스타일 \(styleName(filter.style)), 영역 \(Int(r.width))x\(Int(r.height)) pt, 배율 \(filter.pointPixelScale)"]
        if #available(macOS 15.2, *) {
            let apps = filter.includedApplications
            let windows = filter.includedWindows
            for app in apps {
                lines.append("앱: \(app.applicationName) (\(app.bundleIdentifier), pid \(app.processID))")
            }
            for w in windows {
                let owner = w.owningApplication.map { "\($0.applicationName) pid \($0.processID)" } ?? "소유 앱 불명"
                lines.append("창: \"\(w.title ?? "(제목 없음)")\" — \(owner), windowID \(w.windowID)")
            }
            if apps.isEmpty && windows.isEmpty { lines.append("포함된 앱·창 정보 없음") }
        } else {
            lines.append("앱·창 상세는 macOS 15.2 이상에서만 제공됩니다 (이 OS에서는 표시하지 않음)")
        }
        return lines
    }

    static func styleName(_ style: SCShareableContentStyle) -> String {
        switch style {
        case .none: return "none"
        case .window: return "window"
        case .display: return "display"
        case .application: return "application"
        @unknown default: return "unknown(\(style.rawValue))"
        }
    }
}
