import Combine
import WatchKit

final class SessionManager: NSObject, ObservableObject, WKExtendedRuntimeSessionDelegate {
    private var extendedSession: WKExtendedRuntimeSession?

    func startSession() {
        guard extendedSession == nil || extendedSession?.state == .invalid else { return }

        let session = WKExtendedRuntimeSession()
        session.delegate = self
        session.start()
        extendedSession = session
        print("[Session] Extended runtime session started")
    }

    func endSession() {
        extendedSession?.invalidate()
        extendedSession = nil
        print("[Session] Extended runtime session ended")
    }

    // MARK: - WKExtendedRuntimeSessionDelegate

    func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        print("[Session] Session active")
    }

    func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        print("[Session] Session will expire soon")
    }

    func extendedRuntimeSession(
        _ extendedRuntimeSession: WKExtendedRuntimeSession,
        didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
        error: Error?
    ) {
        print("[Session] Session invalidated: \(reason.rawValue), error: \(error?.localizedDescription ?? "none")")
        extendedSession = nil
    }
}
