import Foundation

/// Narrow interfaces keep daemon safety tests independent of hardware and system files.
protocol HelperSMC: Sendable {
    func open() throws
    func keyExists(_ key: String) -> Bool
    func keyInfo(_ key: String) -> (type: String, size: UInt32)?
    func keyInfoChecked(_ key: String) throws -> (type: String, size: UInt32)?
    func readKeyOptional(_ key: String) -> SMCValue?
    func writeKey(_ key: String, bytes: [UInt8]) throws
}

extension SMCService: HelperSMC {}

protocol HelperWatchdog: Sendable {
    func receivedHeartbeat()
    func suspend()
    func resume()
}

protocol HelperStateStore: Sendable {
    func read() throws -> HelperState.ChargingState?
    func write(_ state: HelperState.ChargingState) throws
}

/// IOMessage.h uses function-like C macros that Swift cannot import. These are the
/// SDK's iokit_common_msg values (sys_iokit | sub_iokit_common | message number).
enum HelperPowerMessage: UInt32 {
    case canSystemSleep = 0xe0000270
    case systemWillSleep = 0xe0000280
    case systemHasPoweredOn = 0xe0000300
}
