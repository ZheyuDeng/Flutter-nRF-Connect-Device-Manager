//
//  ErrorCode.swift
//  mcumgr_flutter
//
//  Created by Mykola Kibysh on 11/12/2020.
//

import Foundation

public enum ErrorCode: String {
    case platformError = "Error"
    case wrongArguments = "WrongArguments"
    case updateManagerExists = "UpdateManagerExists"
    case updateManagerDoesNotExist = "UpdateManagerDoesNotExist"
    case flutterTypeError = "FlutterTypeError"
    case updateError = "UpdateError"
    /// Bluetooth itself cannot serve the request: powered off, unauthorized,
    /// unsupported, or still not ready after the transport warm-up budget.
    /// Retrying without user action is pointless except for the timeout case.
    case bluetoothUnavailable = "BluetoothUnavailable"
    /// The transport reached the device but the SMP exchange failed (missing
    /// service or characteristic, connection timeout, disconnect). Recovery
    /// needs the device, not Bluetooth.
    case transportUnavailable = "TransportUnavailable"
}
