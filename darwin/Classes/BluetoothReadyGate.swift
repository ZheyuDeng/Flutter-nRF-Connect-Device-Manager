import CoreBluetooth
import Foundation

/// Used only before creating an update manager. All calls run on the main queue.
/// A newly created ASK-backed central may briefly report poweredOff before ready.
final class BluetoothReadyGate {
    private struct Request {
        let ready: () -> Void
        let failed: (CBManagerState) -> Void
        let timeout: DispatchWorkItem
    }

    private let timeout: TimeInterval
    private var state: CBManagerState = .unknown
    private var pending: [UUID: Request] = [:]

    init(timeout: TimeInterval = 5) {
        self.timeout = timeout
    }

    func wait(ready: @escaping () -> Void, failed: @escaping (CBManagerState) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        if state == .poweredOn {
            ready()
        } else if state == .unauthorized || state == .unsupported {
            failed(state)
        } else {
            let id = UUID()
            let deadline = DispatchWorkItem { [weak self] in
                guard let self = self, let request = self.pending.removeValue(forKey: id) else { return }
                request.failed(self.state)
            }
            pending[id] = Request(ready: ready, failed: failed, timeout: deadline)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: deadline)
        }
    }

    func update(_ state: CBManagerState) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.state = state
        guard state == .poweredOn || state == .unauthorized || state == .unsupported else { return }
        let requests = Array(pending.values)
        pending.removeAll()
        for request in requests {
            request.timeout.cancel()
            if state == .poweredOn {
                request.ready()
            } else {
                request.failed(state)
            }
        }
    }
}
