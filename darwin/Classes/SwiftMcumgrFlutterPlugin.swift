#if os(iOS)
    import Flutter
    import UIKit
#elseif os(macOS)
    import AppKit
    import FlutterMacOS
#endif
import CoreBluetooth
import iOSMcuManagerLibrary

public class SwiftMcumgrFlutterPlugin: NSObject, FlutterPlugin {
    private let bluetoothReadyGate = BluetoothReadyGate()
    /// Budget for the transport's own central to settle. Mirrors
    /// `BluetoothReadyGate`'s 5s so both readiness steps fail in the same order
    /// of magnitude.
    private static let transportWarmUpTimeout: TimeInterval = 5
    private static let transportWarmUpRetryDelay: TimeInterval = 0.25

    static let namespace = "mcumgr_flutter"

    private var updateManagers: [String: UpdateManager] = [:]
    private var settingsManager: SettingsManager?

    // Lazy initialization to avoid triggering Bluetooth permission at app startup
    private var _centralManager: CBCentralManager?
    private var centralManager: CBCentralManager {
        if _centralManager == nil {
            _centralManager = CBCentralManager(delegate: self, queue: .main)
        }
        return _centralManager!
    }

    private let updateStateEventChannel: FlutterEventChannel
    private let updateProgressEventChannel: FlutterEventChannel

    private var _fsManagerPlugin: FsManagerPlugin?
    private let binaryMessenger: FlutterBinaryMessenger
    private var fsManagerPlugin: FsManagerPlugin {
        if _fsManagerPlugin == nil {
            _fsManagerPlugin = FsManagerPlugin(
                centralManagerProvider: { [weak self] in self?.centralManager },
                messenger: binaryMessenger
            )
        }
        return _fsManagerPlugin!
    }

    // Log channels
    private let logEventChannel: FlutterEventChannel

    private let updateStateStreamHandler = StreamHandler()
    private let updateProgressStreamHandler = StreamHandler()
    private let logStreamHandler = StreamHandler()

    public init(
        updateStateEventChannel: FlutterEventChannel,
        updateProgressEventChannel: FlutterEventChannel,
        logEventChannel: FlutterEventChannel,
        binaryMessenger: FlutterBinaryMessenger
    ) {
        self.binaryMessenger = binaryMessenger
        self.updateStateEventChannel = updateStateEventChannel
        self.updateProgressEventChannel = updateProgressEventChannel
        self.logEventChannel = logEventChannel

        super.init()

        updateStateEventChannel.setStreamHandler(updateStateStreamHandler)
        updateProgressEventChannel.setStreamHandler(updateProgressStreamHandler)
        logEventChannel.setStreamHandler(logStreamHandler)

        // Initialize FsManagerPlugin API setup
        _ = fsManagerPlugin
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
        let messenger = registrar.messenger()
    #else
        let messenger = registrar.messenger
    #endif
        let channel = FlutterMethodChannel(name: namespace + "/method_channel", binaryMessenger: messenger)

        let updateStateEventChannel = FlutterEventChannel(channel: .updateStateEventChannel, binaryMessenger: messenger)
        let updateProgressEventChannel = FlutterEventChannel(channel: .updateProgressEventChannel, binaryMessenger: messenger)
        let logEventChannel = FlutterEventChannel(channel: .logEventChannel, binaryMessenger: messenger)

        let instance = SwiftMcumgrFlutterPlugin(
            updateStateEventChannel: updateStateEventChannel,
            updateProgressEventChannel: updateProgressEventChannel,
            logEventChannel: logEventChannel,
            binaryMessenger: messenger
        )
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let method = FlutterMethod(rawValue: call.method) else {
            let error = FlutterMethodNotImplemented
            result(error)
            return
        }

        do {
            switch method {
            case .update:
                try update(call: call)
                result(nil)
            case .updateSingleImage:
                try updateSingleImage(call: call)
                result(nil)
            case .initializeUpdateManager:
                try initializeUpdateManager(call: call, result: result)
            case .pause:
                try pause(call: call)
                result(nil)
            case .resume:
                try resume(call: call)
                result(nil)
            case .isPaused:
                result(try isPaused(call: call))
            case .isInProgress:
                result(try isInProgress(call: call))
            case .cancel:
                try cancel(call: call)
                result(nil)
            case .kill:
                try kill(call: call)
                result(nil)
            case .readLogs:
                result(try readLogs(call: call).serializedData())
            case .clearLogs:
                try retrieveManager(call: call).updateLogger.clearLogs()
                result(nil)
            case .readImageList:
                try readImages(call: call, result: result)
            case .confirmImage:
                try confirmImage(call: call, result: result)
            case .erase:
                try erase(call: call, result: result)
            case .initSettings:
                try initSettingsManager(call: call, result: result)
            case .fetchSettings:
                try fetchSettings(result: result)
            case .readSetting:
                try readSetting(call: call, result: result)
            case .writeSetting:
                try writeSetting(call: call, result: result)
            case .disposeSettings:
                settingsManager = nil
                result(nil)
            }
        } catch let e as FlutterError {
            result(e)
        } catch {
            result(FlutterError(error: error, call: call))
        }
    }

    private func initializeUpdateManager(call: FlutterMethodCall, result: @escaping FlutterResult) throws {
        guard let uuidString = call.arguments as? String, UUID(uuidString: uuidString) != nil else {
            throw FlutterError(code: ErrorCode.wrongArguments.rawValue, message: "Can not create UUID from provided arguments", details: call.debugDetails)
        }

        waitForBluetooth(call: call, result: result)
    }

    private func waitForBluetooth(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let manager = centralManager
        bluetoothReadyGate.update(manager.state)
        bluetoothReadyGate.wait(ready: {
            self.handlePostponedCall(call: call, result: result, central: manager)
        }, failed: { [weak self] state in
            result(FlutterError(
                // Typed so Dart can tell "Bluetooth cannot serve this" from a
                // device-side transport failure instead of parsing messages.
                code: ErrorCode.bluetoothUnavailable.rawValue,
                message: self?.bluetoothStateMessage(state) ?? "Bluetooth did not become ready",
                details: ["method": call.method, "bluetoothState": state.rawValue]
            ))
        })
    }


    // MARK: - Transport readiness

    /// `bluetoothReadyGate` covers this plugin's own central. `McuMgrBleTransport`
    /// builds a *second* `CBCentralManager` when the update manager is created
    /// (`UpdateManager.init`), and its first `_send` reads that manager's state
    /// synchronously — so a freshly created transport can answer
    /// `centralManagerPoweredOff` while Bluetooth is perfectly healthy. Field
    /// capture 2026-09-20: the very first update of an app session failed that
    /// way and a manual retry succeeded.
    ///
    /// Warm the transport with one real SMP read before handing the manager to
    /// Dart, and classify the outcome here, where the errors are still typed:
    ///   * transport not ready while *our* central is poweredOn → warm-up race,
    ///     retry within the budget;
    ///   * our central not poweredOn → `bluetoothUnavailable`, no retry;
    ///   * anything else (missing SMP service, connection timeout, …) →
    ///     `transportUnavailable`, no retry.
    /// Registration is rolled back on failure so the next attempt is not
    /// rejected by the `updateManagerExists` guard.
    private func warmUpTransport(
        uuidString: String,
        call: FlutterMethodCall,
        central: CBCentralManager,
        result: @escaping FlutterResult
    ) {
        let deadline = Date().addingTimeInterval(Self.transportWarmUpTimeout)
        var settled = false
        let finish: (FlutterError?) -> Void = { [weak self] error in
            dispatchPrecondition(condition: .onQueue(.main))
            guard !settled else { return }
            settled = true
            if let error {
                self?.updateManagers.removeValue(forKey: uuidString)
                result(error)
            } else {
                result(nil)
            }
        }
        // A native SMP read cannot be cancelled, and Nordic's own connection
        // timeout is 20s. Bound what the user waits on independently of it.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.transportWarmUpTimeout + 0.5) {
            finish(FlutterError(
                code: ErrorCode.bluetoothUnavailable.rawValue,
                message: "DFU transport did not become ready in time",
                details: ["method": call.method, "bluetoothState": central.state.rawValue]
            ))
        }
        attemptTransportWarmUp(
            uuidString: uuidString,
            call: call,
            central: central,
            deadline: deadline,
            attempt: 1,
            finish: finish
        )
    }

    private func attemptTransportWarmUp(
        uuidString: String,
        call: FlutterMethodCall,
        central: CBCentralManager,
        deadline: Date,
        attempt: Int,
        finish: @escaping (FlutterError?) -> Void
    ) {
        guard let manager = updateManagers[uuidString] else { return }
        manager.imageManager.list { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let error else {
                    finish(nil)
                    return
                }
                // A response is proof enough: an empty or absent image list is
                // a valid answer from a device whose slots are not enumerable,
                // and the upgrade itself never reads this list.
                guard self.isTransportNotReady(error) else {
                    finish(FlutterError(
                        code: ErrorCode.transportUnavailable.rawValue,
                        message: error.localizedDescription,
                        details: ["method": call.method, "attempt": attempt]
                    ))
                    return
                }
                guard central.state == .poweredOn else {
                    finish(FlutterError(
                        code: ErrorCode.bluetoothUnavailable.rawValue,
                        message: self.bluetoothStateMessage(central.state),
                        details: ["method": call.method, "bluetoothState": central.state.rawValue]
                    ))
                    return
                }
                guard Date() < deadline else {
                    finish(FlutterError(
                        code: ErrorCode.bluetoothUnavailable.rawValue,
                        message: "DFU transport did not become ready in time",
                        details: ["method": call.method, "attempt": attempt]
                    ))
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.transportWarmUpRetryDelay) {
                    self.attemptTransportWarmUp(
                        uuidString: uuidString,
                        call: call,
                        central: central,
                        deadline: deadline,
                        attempt: attempt + 1,
                        finish: finish
                    )
                }
            }
        }
    }

    /// Only the transport's own "central is not usable yet" cases. Missing SMP
    /// service, missing characteristic, connection timeouts and disconnects are
    /// deliberately excluded: retrying those cannot help.
    func isTransportNotReady(_ error: Error) -> Bool {
        guard let error = error as? McuMgrBleTransportError else { return false }
        switch error {
        case .centralManagerPoweredOff, .centralManagerNotReady:
            return true
        default:
            return false
        }
    }

    func bluetoothStateMessage(_ state: CBManagerState) -> String {
        switch state {
        case .unauthorized: return "Bluetooth is unauthorized"
        case .unsupported: return "Unsupported bluetooth state"
        case .poweredOff: return "Bluetooth is powered off"
        default: return "Bluetooth did not become ready"
        }
    }

    private func handleUpdateManager(for peripheral: CBPeripheral, call: FlutterMethodCall) throws {
        guard let uuidString = call.arguments as? String else {
            throw FlutterError(code: ErrorCode.wrongArguments.rawValue, message: "Can not create UUID from provided arguments", details: call.debugDetails)
        }

        guard case .none = updateManagers[uuidString] else {
            throw FlutterError(code: ErrorCode.updateManagerExists.rawValue, message: "Updated manager for provided peripheral already exists", details: call.debugDetails)
        }

        let logger = UpdateLogger(identifier: uuidString, streamHandler: logStreamHandler)
        let updateManager = UpdateManager(peripheral: peripheral, progressStreamHandler: updateProgressStreamHandler, stateStreamHandler: updateStateStreamHandler, logStreamHandler: logStreamHandler, updateLogger: logger)
        updateManagers[uuidString] = updateManager
    }

    private func retrieveManager(call: FlutterMethodCall) throws -> UpdateManager {
        guard let uuid = call.arguments as? String else {
            throw FlutterError(code: ErrorCode.wrongArguments.rawValue, message: "Can't retrieve UUID of the device", details: call.debugDetails)
        }

        guard let manager = updateManagers[uuid] else {
            throw FlutterError(code: ErrorCode.updateManagerDoesNotExist.rawValue, message: "Update manager does not exist", details: call.debugDetails)
        }

        return manager
    }

    private func pause(call: FlutterMethodCall) throws {
        try retrieveManager(call: call).pause()
    }

    private func resume(call: FlutterMethodCall) throws {
        try retrieveManager(call: call).resume()
    }

    private func isPaused(call: FlutterMethodCall) throws -> Bool {
        try retrieveManager(call: call).dfuManager.isPaused()
    }

    private func isInProgress(call: FlutterMethodCall) throws -> Bool {
        try retrieveManager(call: call).dfuManager.isInProgress()
    }

    private func cancel(call: FlutterMethodCall) throws {
        try retrieveManager(call: call).cancel()
    }

    private func update(call: FlutterMethodCall) throws {
        guard let data = call.arguments as? FlutterStandardTypedData else {
            throw FlutterError(code: ErrorCode.wrongArguments.rawValue, message: "Can not parse provided arguments", details: call.debugDetails)
        }

        let args = try ProtoUpdateWithImageCallArguments(serializedBytes: data.data)
        guard let manager = updateManagers[args.deviceUuid] else {
            throw FlutterError(code: ErrorCode.updateManagerDoesNotExist.rawValue, message: "Update manager does not exist", details: call.debugDetails)
        }

        let images = args.images.map { ImageManager.Image(proto: $0) }
        let config = args.hasConfiguration ? FirmwareUpgradeConfiguration(proto: args.configuration) : FirmwareUpgradeConfiguration()

        try manager.update(images: images, config: config)
    }

    private func updateSingleImage(call: FlutterMethodCall) throws {
        guard let data = call.arguments as? FlutterStandardTypedData else {
            throw FlutterError(code: ErrorCode.wrongArguments.rawValue, message: "Can not parse provided arguments", details: call.debugDetails)
        }

        let args = try ProtoUpdateCallArgument(serializedBytes: data.data)
        guard let manager = updateManagers[args.deviceUuid] else {
            throw FlutterError(code: ErrorCode.updateManagerDoesNotExist.rawValue, message: "Update manager does not exist", details: call.debugDetails)
        }

        let config = args.hasConfiguration ? FirmwareUpgradeConfiguration(proto: args.configuration) : FirmwareUpgradeConfiguration()
        let hash: Data
        if args.hasHash {
            hash = args.hash
        } else {
            hash = try McuMgrImage(data: args.firmwareData).hash
        }

        try manager.update(hash: hash, data: args.firmwareData, config: config)
    }

    private func kill(call: FlutterMethodCall) throws {
        let uuid = try retrieveManager(call: call).peripheral.identifier.uuidString
        updateManagers.removeValue(forKey: uuid)
    }

    // MARK: Logs

    private func readLogs(call: FlutterMethodCall) throws -> ProtoReadMessagesResponse {
        guard let data = call.arguments as? FlutterStandardTypedData else {
            throw FlutterError(code: ErrorCode.wrongArguments.rawValue, message: "Can not parse provided arguments", details: call.debugDetails)
        }

        let args = try ProtoReadLogCallArguments(serializedBytes: data.data)
        guard let manager = updateManagers[args.uuid] else {
            throw FlutterError(code: ErrorCode.updateManagerDoesNotExist.rawValue, message: "Update manager does not exist", details: call.debugDetails)
        }

        return manager.updateLogger.readLogs()
    }

    private func readImages(call: FlutterMethodCall, result: @escaping FlutterResult) throws {
        guard let uuid = call.arguments as? String else {
            throw FlutterError(code: ErrorCode.wrongArguments.rawValue, message: "Can't retrieve UUID of the device", details: call.debugDetails)
        }

        let manager = try retrieveManager(call: call)

        manager.imageManager.list { response, error in
            if let error {
                result(FlutterError(error: error, call: call))
                return
            }

            var protoResponse = ProtoListImagesResponse()
            if let images = response?.images {
                protoResponse.images = images.map { $0.toProto() }
                protoResponse.existing = true
            } else {
                protoResponse.existing = false
            }

            protoResponse.uuid = uuid

            do {
                result(try protoResponse.serializedData())
            } catch {
                result(FlutterError(error: error, call: call))
            }
        }
    }

    /// Confirms the image with the hash given in the call's arguments.
    private func confirmImage(call: FlutterMethodCall, result: @escaping FlutterResult) throws {
        guard let args = call.arguments as? [String: Any],
              let uuid = args["deviceId"] as? String else {
            throw FlutterError(code: ErrorCode.wrongArguments.rawValue, message: "Expected map arguments with deviceId and hash", details: call.debugDetails)
        }

        guard let hashData = (args["hash"] as? FlutterStandardTypedData)?.data else {
            throw FlutterError(code: ErrorCode.wrongArguments.rawValue, message: "Image hash expected", details: call.debugDetails)
        }

        guard let manager = updateManagers[uuid] else {
            throw FlutterError(code: ErrorCode.updateManagerDoesNotExist.rawValue, message: "Update manager does not exist", details: call.debugDetails)
        }

        let hash: [UInt8] = [UInt8](hashData)
        manager.imageManager.confirm(hash: hash) { response, error in
            if let error {
                result(FlutterError(error: error, call: call))
                return
            }

            result(nil)
        }
    }
  
    /// Erases the default secondary image slot or a specific raw image slot channel.
    private func erase(call: FlutterMethodCall, result: @escaping FlutterResult) throws {
        guard let args = call.arguments as? [String: Any],
              let uuid = args["deviceUuid"] as? String else {
            throw FlutterError(code: ErrorCode.wrongArguments.rawValue, message: "Can not parse erase arguments", details: call.debugDetails)
        }

        let channelValue = args["channel"]
        let channel = (channelValue as? Int) ?? (channelValue as? NSNumber)?.intValue
        if let channel, channel < 0 {
            throw FlutterError(code: ErrorCode.wrongArguments.rawValue, message: "Channel must not be negative", details: call.debugDetails)
        }

        guard let manager = updateManagers[uuid] else {
            throw FlutterError(code: ErrorCode.updateManagerDoesNotExist.rawValue, message: "Update manager does not exist", details: call.debugDetails)
        }

        let image = channel.map { $0 / 2 }
        let slot = channel.map { $0 % 2 }
        manager.imageManager.erase(image: image, slot: slot) { _, error in
            if let error {
                result(FlutterError(error: error, call: call))
                return
            }

            result(nil)
        }
    }
}

extension SwiftMcumgrFlutterPlugin: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothReadyGate.update(central.state)
    }

    private func handlePostponedCall(call: FlutterMethodCall, result: @escaping FlutterResult, central: CBCentralManager) {
        var uuidString = call.arguments as? String

        if uuidString == nil {
            if let args = call.arguments as? [String: Any], let addressString = args["deviceAddress"] as? String {
                uuidString = addressString
            }
        }

        guard let uuidString = uuidString, let uuid = UUID(uuidString: uuidString) else {
            let error = FlutterError(code: ErrorCode.wrongArguments.rawValue, message: "Can not create UUID from provided arguments", details: call.debugDetails)
            result(error)
            return
        }
        if let peripheral = central.retrievePeripherals(withIdentifiers: [uuid]).first {
            do {
                if let method = FlutterMethod(rawValue: call.method), method == .initSettings {
                    let transport = try handleSettingsManager(for: peripheral, call: call)
                    transport.connect { connectionResult in
                        switch connectionResult {
                        case .connected:
                            result(nil)
                        case .deferred:
                            result(nil)
                        case .failed(let error):
                            result(FlutterError(code: Self.settingsManagerErrorCode,
                                                message: "Failed to connect: \(error.localizedDescription)",
                                                details: nil))
                        }
                    }
                } else {
                    try handleUpdateManager(for: peripheral, call: call)
                    // Do not report success until the transport's own central
                    // can actually carry an SMP request.
                    warmUpTransport(
                        uuidString: peripheral.identifier.uuidString,
                        call: call,
                        central: central,
                        result: result
                    )
                }
            } catch {
                result(error)
            }
        } else {
            let error = FlutterError(code: ErrorCode.wrongArguments.rawValue, message: "Can not retreive peripheral to update", details: call.debugDetails)
            result(error)
        }
    }

    // MARK: - Settings Manager Methods

    private static let settingsManagerErrorCode = "MCU_MGR_SETTINGS_MANAGER"

    private func initSettingsManager(call: FlutterMethodCall, result: @escaping FlutterResult) throws {
        guard let args = call.arguments as? [String: Any] else {
            throw FlutterError(code: Self.settingsManagerErrorCode,
                               message: "Expected map with deviceAddress, padTo4Bytes, and encodeValueToCBOR",
                               details: nil)
        }

        guard let addressString = args["deviceAddress"] as? String,
              UUID(uuidString: addressString) != nil else {
            throw FlutterError(code: Self.settingsManagerErrorCode,
                               message: "Device address expected in map",
                               details: nil)
        }

        // Settings and DFU share one readiness gate, including its timeout
        // and permission failures. Never leave Settings in the removed queue.
        waitForBluetooth(call: call, result: result)
    }

    private func handleSettingsManager(for peripheral: CBPeripheral, call: FlutterMethodCall) throws -> McuMgrBleTransport {
        guard case .none = settingsManager else {
            throw FlutterError(code: ErrorCode.updateManagerExists.rawValue, message: "Settings manager for provided peripheral already exists", details: call.debugDetails)
        }

        guard let args = call.arguments as? [String: Any] else {
            throw FlutterError(code: Self.settingsManagerErrorCode,
                               message: "Expected map with deviceAddress, padTo4Bytes, and encodeValueToCBOR",
                               details: nil)
        }

        let padTo4Bytes = args["padTo4Bytes"] as? Bool ?? false
        let encodeValueToCBOR = args["encodeValueToCBOR"] as? Bool ?? false
        let useByteStringEncoding = args["useByteStringEncoding"] as? Bool ?? true
        let precisionMode = args["precisionMode"] as? String ?? "auto"

        let transport = McuMgrBleTransport(peripheral)
        settingsManager = SettingsManager(transport: transport,
                                          padTo4Bytes: padTo4Bytes,
                                          encodeValueToCBOR: encodeValueToCBOR,
                                          useByteStringEncoding: useByteStringEncoding,
                                          precisionMode: precisionMode,
                                          logStreamHandler: logStreamHandler)

        return transport
    }

    private func fetchSettings(result: @escaping FlutterResult) throws {
        guard let settingsManager = settingsManager else {
            throw FlutterError(code: Self.settingsManagerErrorCode,
                               message: "Settings manager is not initialized",
                               details: nil)
        }

        settingsManager.fetchSettings(result: result)
    }

    private func readSetting(call: FlutterMethodCall, result: @escaping FlutterResult) throws {
        guard let settingsManager = settingsManager else {
            throw FlutterError(code: Self.settingsManagerErrorCode,
                               message: "Settings manager is not initialized",
                               details: nil)
        }

        guard let key = call.arguments as? String else {
            throw FlutterError(code: Self.settingsManagerErrorCode,
                               message: "Expected key",
                               details: nil)
        }

        settingsManager.readSettings(key: key, result: result)
    }

    private func writeSetting(call: FlutterMethodCall, result: @escaping FlutterResult) throws {
        guard let settingsManager = settingsManager else {
            throw FlutterError(code: Self.settingsManagerErrorCode,
                               message: "Settings manager is not initialized",
                               details: nil)
        }

        guard let args = call.arguments as? [String: Any],
              let key = args["key"] as? String,
              let value = args["value"] else {
            throw FlutterError(code: Self.settingsManagerErrorCode,
                               message: "Expected key-value map",
                               details: nil)
        }

        settingsManager.writeSetting(key: key, value: value, result: result)
    }
}
