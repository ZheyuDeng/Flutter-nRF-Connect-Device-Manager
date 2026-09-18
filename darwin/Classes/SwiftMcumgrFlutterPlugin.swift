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

    static let namespace = "mcumgr_flutter"

    private var updateManagers: [String: UpdateManager] = [:]

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

        let manager = centralManager
        bluetoothReadyGate.update(manager.state)
        bluetoothReadyGate.wait(ready: {
            self.handlePostponedCall(call: call, result: result, central: manager)
        }, failed: { state in
            let message: String
            switch state {
            case .unauthorized: message = "Bluetooth is unauthorized"
            case .unsupported: message = "Unsupported bluetooth state"
            case .poweredOff: message = "Bluetooth is powered off"
            default: message = "Bluetooth did not become ready within 5 seconds"
            }
            result(FlutterError(
                code: ErrorCode.wrongArguments.rawValue,
                message: message,
                details: ["method": call.method, "bluetoothState": state.rawValue]
            ))
        })
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
}

extension SwiftMcumgrFlutterPlugin: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothReadyGate.update(central.state)
    }

    private func handlePostponedCall(call: FlutterMethodCall, result: FlutterResult, central: CBCentralManager) {
        guard let uuidString = call.arguments as? String, let uuid = UUID(uuidString: uuidString) else {
            let error = FlutterError(code: ErrorCode.wrongArguments.rawValue, message: "Can not create UUID from provided arguments", details: call.debugDetails)
            result(error)
            return
        }
        if let peripheral = central.retrievePeripherals(withIdentifiers: [uuid]).first {
            do {
                try handleUpdateManager(for: peripheral, call: call)
                result(nil)
            } catch {
                result(error)
            }
        } else {
            let error = FlutterError(code: ErrorCode.wrongArguments.rawValue, message: "Can not retreive peripheral to update", details: call.debugDetails)
            result(error)
        }
    }
}
