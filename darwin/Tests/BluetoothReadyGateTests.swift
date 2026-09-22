import CoreBluetooth
import Foundation

// Run with swiftc Classes/BluetoothReadyGate.swift Tests/BluetoothReadyGateTests.swift.
@main
struct BluetoothReadyGateTests {
    static func main() {
        func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.06)) }

        // Initial off/unknown/resetting must not fail before readiness arrives.
        for initial: CBManagerState in [.poweredOff, .unknown, .resetting] {
            let gate = BluetoothReadyGate(timeout: 0.02)
            var successes = 0
            var failures = 0
            gate.update(initial)
            gate.wait(ready: { successes += 1 }, failed: { _ in failures += 1 })
            precondition(successes == 0 && failures == 0)
            precondition(!gate.isIdle)
            gate.update(.poweredOn)
            spin()
            precondition(successes == 1 && failures == 0)
            precondition(gate.isIdle)
        }

        // Timeout completes exactly once; a late poweredOn cannot start an old update.
        let gate = BluetoothReadyGate(timeout: 0.02)
        var successes = 0
        var failures: [CBManagerState] = []
        gate.update(.poweredOff)
        gate.wait(ready: { successes += 1 }, failed: { failures.append($0) })
        precondition(!gate.isIdle)
        gate.update(.unknown) // State changes must not restart the timeout budget.
        spin()
        precondition(gate.isIdle)
        gate.update(.poweredOn)
        precondition(successes == 0 && failures == [.unknown])
        gate.wait(ready: { successes += 1 }, failed: { failures.append($0) })
        precondition(successes == 1 && failures.count == 1)

        // Permission denial / unsupported hardware remain immediate failures.
        for state: CBManagerState in [.unauthorized, .unsupported] {
            for alreadyKnown in [false, true] {
                let gate = BluetoothReadyGate(timeout: 0.02)
                var failures: [CBManagerState] = []
                if alreadyKnown { gate.update(state) }
                gate.wait(ready: { preconditionFailure("Unexpected ready") },
                          failed: { failures.append($0) })
                if !alreadyKnown { gate.update(state) }
                precondition(failures == [state])
                spin()
                precondition(failures == [state])
            }
        }
        // DFU and Settings can wait together; each must complete exactly once.
        for becomesReady in [false, true] {
            let shared = BluetoothReadyGate(timeout: 0.02)
            var results: [String: Int] = [:]
            for manager in ["dfu", "settings"] {
                shared.wait(ready: {
                    precondition(becomesReady)
                    results[manager, default: 0] += 1
                }, failed: { _ in
                    precondition(!becomesReady)
                    results[manager, default: 0] += 1
                })
            }
            if becomesReady { shared.update(.poweredOn) }
            spin()
            shared.update(.poweredOn)
            precondition(results == ["dfu": 1, "settings": 1])
        }

        print("BluetoothReadyGate: recovery, timeout, late callback, retry and permission cases passed")
    }
}
