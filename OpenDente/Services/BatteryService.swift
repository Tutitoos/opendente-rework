import Foundation
import Combine
import IOKit.ps
import os.log
import Darwin

private let log = Logger(subsystem: "com.opendente.app", category: "BatteryService")

/// The firmware contract, not each sample's magnitude, selects B0RM byte order.
enum SMCRemainingCapacityFormat: Equatable {
    case legacyBigEndian, modernLittleEndian, unknown

    init(bcf0Size: UInt32?) {
        switch bcf0Size {
        case 4: self = .legacyBigEndian
        case 1: self = .modernLittleEndian
        default: self = .unknown
        }
    }
}

struct BatteryCapacitySnapshot: Equatable {
    var current: Int?
    var full: Int?
    var design: Int?
    var hardwarePercentage: Int?
    var source: BatteryDataSource = .unavailable
    var currentSource: BatteryDataSource = .unavailable
    var quality: BatteryDataQuality = .unavailable
    var unavailableReason: String?
    var isEstimated = false
}

/// Pure parsers used by the polling path and regression fixtures alike.
enum BatteryReadingParser {
    static func unsigned16(_ value: SMCValue?) -> Int? {
        guard let value, value.trimmedDataType == "ui16", value.dataSize == 2,
              value.bytes.count == 2, let raw = value.uint16Value else { return nil }
        return Int(raw)
    }

    static func remainingCapacity(_ value: SMCValue?, format: SMCRemainingCapacityFormat,
                                  full: Int) -> Int? {
        guard let value, value.trimmedDataType == "ui16", value.dataSize == 2,
              value.bytes.count == 2, (1...20_000).contains(full) else { return nil }
        let remaining: Int?
        switch format {
        case .legacyBigEndian: remaining = value.uint16BigEndian.map(Int.init)
        case .modernLittleEndian: remaining = value.uint16Value.map(Int.init)
        case .unknown: return nil // Do not guess a value that can control charging.
        }
        return remaining.flatMap { validRemaining($0, full: full) ? $0 : nil }
    }

    /// ui8 is verified on current firmware. Do not invent a ui16 scale/byte order.
    static func hardwarePercentage(_ value: SMCValue?) -> Int? {
        guard let value, value.trimmedDataType == "ui8", value.dataSize == 1,
              value.bytes.count == 1, let raw = value.uint8Value, raw <= 100 else { return nil }
        return Int(raw)
    }

    static func registryInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let raw = number.doubleValue
        guard raw.isFinite, raw.rounded() == raw, raw >= 0, raw <= 20_000 else { return nil }
        return Int(raw)
    }

    static func validRemaining(_ remaining: Int, full: Int) -> Bool {
        remaining >= 0 && (1...20_000).contains(full)
            && Double(remaining) / Double(full) <= 1.1
    }

    private static func invalidPair(full: Int?, design: Int?) -> Bool {
        guard let full, let design else { return false }
        return !BatteryState.validCapacityPair(full: full, design: design)
    }

    static func resolveCapacities(full: SMCValue?, design: SMCValue?, remaining: SMCValue?,
                                  format: SMCRemainingCapacityFormat, brsc: SMCValue?,
                                  registry: [String: Any]?, normalizedPercentage: Int?) -> BatteryCapacitySnapshot {
        var result = BatteryCapacitySnapshot()
        let smcFull = unsigned16(full)
        let smcDesign = unsigned16(design)
        let registryFull = registryInteger(registry?["FullChargeCapacity"])
        let registryDesign = registryInteger(registry?["DesignCapacity"])

        // Select a complete pair in mAh. IOPS Max Capacity (usually 100%) is not a fallback.
        if let smcFull, let smcDesign,
           BatteryState.validCapacityPair(full: smcFull, design: smcDesign) {
            result.full = smcFull; result.design = smcDesign; result.source = .smc
        } else if let registryFull, let registryDesign,
                  BatteryState.validCapacityPair(full: registryFull, design: registryDesign) {
            result.full = registryFull; result.design = registryDesign; result.source = .ioRegistry
        }

        guard let selectedFull = result.full else {
            let invalidSMC = (full != nil && smcFull == nil) || (design != nil && smcDesign == nil)
                || invalidPair(full: smcFull, design: smcDesign)
            let invalidRegistry = (registry?["FullChargeCapacity"] != nil && registryFull == nil)
                || (registry?["DesignCapacity"] != nil && registryDesign == nil)
                || invalidPair(full: registryFull, design: registryDesign)
            result.quality = invalidSMC || invalidRegistry ? .invalid : .unavailable
            result.unavailableReason = result.quality == .invalid
                ? "No complete, coherent capacity pair in mAh"
                : "Capacity sensors unavailable"
            result.hardwarePercentage = hardwarePercentage(brsc)
            return result
        }
        result.quality = .valid

        if result.source == .smc,
           let raw = remainingCapacity(remaining, format: format, full: selectedFull) {
            result.current = raw; result.currentSource = .smc
        } else if let raw = registryInteger(registry?["RemainingCapacity"]),
                  validRemaining(raw, full: selectedFull) {
            result.current = raw; result.currentSource = .ioRegistry
        }

        if let current = result.current {
            result.hardwarePercentage = min(100, Int((Double(current) / Double(selectedFull) * 100).rounded()))
        } else {
            result.hardwarePercentage = hardwarePercentage(brsc)
            if let normalizedPercentage, (0...100).contains(normalizedPercentage) {
                result.current = selectedFull * normalizedPercentage / 100
                result.currentSource = .estimated
                result.isEstimated = true
            }
        }
        return result
    }
}

struct SystemBatteryHealth: Equatable, Sendable {
    var condition: BatteryCondition = .unknown
    var maximumCapacityPercentage: Int?
    var source: BatteryDataSource = .unavailable
}

struct BatteryPowerSourceSnapshot: Equatable, Sendable {
    var percentage: Int?
    var isCharging = false
    var isPluggedIn = false
    var cycleCount: Int?
    var timeToEmpty: Int?
    var timeToFull: Int?
    var systemHealth = SystemBatteryHealth()

    var hasValidBatteryReading: Bool { percentage != nil }
}

/// IOPS includes UPS devices and can publish absent batteries. Only a present
/// internal battery may supply the percentage and AC state used by the controller.
enum IOPSBatteryParser {
    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func integerNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let raw = number.doubleValue
        // IOPS documents these capacities as signed kCFNumberIntType values.
        guard raw.isFinite, raw >= 0, raw <= Double(Int32.max), raw.rounded() == raw else { return nil }
        return raw
    }

    private static func boundedInteger(_ value: Any?, maximum: Int) -> Int? {
        guard let raw = integerNumber(value), raw <= Double(maximum) else { return nil }
        return Int(raw)
    }

    static func parse(_ descriptions: [[String: Any]]) -> BatteryPowerSourceSnapshot {
        for description in descriptions {
            guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  boolean(description[kIOPSIsPresentKey]) == true,
                  let current = integerNumber(description[kIOPSCurrentCapacityKey]),
                  let maximum = integerNumber(description[kIOPSMaxCapacityKey]),
                  maximum > 0, current <= maximum,
                  let isCharging = boolean(description[kIOPSIsChargingKey]),
                  let powerSource = description[kIOPSPowerSourceStateKey] as? String,
                  powerSource == kIOPSACPowerValue || powerSource == kIOPSBatteryPowerValue else { continue }
            return BatteryPowerSourceSnapshot(
                percentage: Int((current / maximum * 100).rounded()),
                isCharging: isCharging,
                isPluggedIn: powerSource == kIOPSACPowerValue,
                cycleCount: boundedInteger(description["CycleCount"], maximum: 10_000),
                timeToEmpty: boundedInteger(description[kIOPSTimeToEmptyKey], maximum: 100_000),
                timeToFull: boundedInteger(description[kIOPSTimeToFullChargeKey], maximum: 100_000),
                systemHealth: SystemBatteryHealthParser.iops(description)
            )
        }
        return BatteryPowerSourceSnapshot()
    }
}

struct SystemBatteryHealthCache {
    static let lifetime: TimeInterval = 600
    private(set) var health: SystemBatteryHealth?
    private(set) var updatedAt: Date?

    mutating func record(_ health: SystemBatteryHealth?, at now: Date) {
        self.health = health
        updatedAt = health == nil ? nil : now
    }

    func value(at now: Date) -> SystemBatteryHealth? {
        guard let updatedAt else { return nil }
        let age = now.timeIntervalSince(updatedAt)
        return age >= 0 && age < Self.lifetime ? health : nil
    }
}

enum SystemBatteryHealthParser {
    static func condition(_ value: Any?) -> BatteryCondition {
        guard let string = value as? String else { return .unknown }
        switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "normal", "good": return .normal
        case "fair", "poor", "check battery", "permanent battery failure",
             "service recommended", "service battery", "replace soon", "replace now":
            return .serviceRecommended
        default: return .unknown
        }
    }

    static func iops(_ description: [String: Any]) -> SystemBatteryHealth {
        var health = SystemBatteryHealth(source: .iops)
        let failures = description["BatteryFailureModes"] as? [String] ?? []
        if description["Internal Failure"] as? Bool == true || !failures.isEmpty {
            health.condition = .serviceRecommended
        } else {
            health.condition = condition(description["BatteryHealthCondition"])
            if health.condition == .unknown { health.condition = condition(description["BatteryHealth"]) }
        }
        // Max Capacity in this dictionary is state of charge, never native battery health.
        return health
    }

    static func maximumCapacity(_ value: Any?) -> Int? {
        let raw: Double?
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            raw = number.doubleValue
        } else if let string = value as? String {
            var clean = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.hasSuffix("%") {
                clean.removeLast()
                clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !clean.isEmpty, clean.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
            raw = Double(clean)
        } else {
            raw = nil
        }
        guard let raw, raw.isFinite, raw.rounded() == raw, (0...100).contains(raw) else { return nil }
        return Int(raw)
    }

    static func systemProfiler(_ data: Data) -> SystemBatteryHealth? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["SPPowerDataType"] as? [[String: Any]] else { return nil }
        for entry in entries {
            let info = (entry["battery_health_info"] ?? entry["sppower_battery_health_info"]) as? [String: Any]
            guard let info else { continue }
            let health = SystemBatteryHealth(
                condition: condition(info["sppower_battery_health"]),
                maximumCapacityPercentage: maximumCapacity(info["sppower_battery_health_maximum_capacity"]),
                source: .systemProfiler
            )
            if health.condition != .unknown || health.maximumCapacityPercentage != nil { return health }
        }
        return nil
    }
}

/// One owned subprocess, with cancellation and a real wall-clock deadline. The lock
/// protects process publication against the timer/cancellation callback. File output
/// avoids waiting for EOF if a subprocess descendant retains a pipe descriptor.
final class SystemHealthCommandRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning {
            // Kill only the command owned by this runner. SIGKILL also handles a
            // collector that ignores SIGTERM; no wait for an unbounded grace period.
            kill(process.processIdentifier, SIGKILL)
        }
    }

    func run(executableURL: URL, arguments: [String], timeout: TimeInterval) -> Data? {
        guard timeout > 0, timeout.isFinite else { return nil }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenDente-health-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        catch { return nil }
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("output.json")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil,
                                            attributes: [.posixPermissions: 0o600]),
              let output = try? FileHandle(forWritingTo: outputURL) else { return nil }
        defer { try? output.close() }

        let command = Process()
        command.executableURL = executableURL
        command.arguments = arguments
        command.standardOutput = output
        command.standardError = FileHandle.nullDevice
        lock.lock()
        guard !cancelled else { lock.unlock(); return nil }
        process = command
        do { try command.run() } catch { process = nil; lock.unlock(); return nil }
        lock.unlock()

        let deadline = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        deadline.schedule(deadline: .now() + timeout)
        deadline.setEventHandler { [weak self] in self?.cancel() }
        deadline.resume()
        command.waitUntilExit()
        deadline.cancel()

        lock.lock()
        process = nil
        let didCancel = cancelled
        lock.unlock()
        guard !didCancel, command.terminationStatus == 0,
              let input = try? FileHandle(forReadingFrom: outputURL) else { return nil }
        defer { try? input.close() }
        // This tiny report is normally a few KB. Reject unexpectedly large output.
        guard let data = try? input.read(upToCount: 1_048_577), data.count <= 1_048_576 else { return nil }
        return data
    }
}

/// A low-frequency fallback. The actor keeps blocking process work off MainActor.
actor SystemBatteryHealthProvider {
    static let shared = SystemBatteryHealthProvider()

    func read() async -> SystemBatteryHealth? {
        guard !Task.isCancelled else { return nil }
        let runner = SystemHealthCommandRunner()
        return await withTaskCancellationHandler {
            guard let data = runner.run(executableURL: URL(fileURLWithPath: "/usr/sbin/system_profiler"),
                                        arguments: ["-json", "-detailLevel", "mini", "-timeout", "5", "SPPowerDataType"],
                                        timeout: 10), !Task.isCancelled else { return nil }
            return SystemBatteryHealthParser.systemProfiler(data)
        } onCancel: {
            runner.cancel()
        }
    }
}

/// Monitors battery state using IOKit power source APIs + SMC for detailed data.
/// Reading does not require root.
@MainActor
final class BatteryService: ObservableObject {

    static let shared = BatteryService()

    @Published var batteryState: BatteryState = .unknown
    @Published private(set) var smcAvailable = false

    private var timer: Timer?
    private var runLoopSource: CFRunLoopSource?
    private let smc = SMCService.shared
    let settings: AppSettings
    private var remainingCapacityFormat: SMCRemainingCapacityFormat = .unknown
    private var running = false
    private var systemHealthTask: Task<Void, Never>?
    private var lastSystemHealthRequest: Date?
    private var systemHealthCache = SystemBatteryHealthCache()
    private let systemHealthReader: @Sendable () async -> SystemBatteryHealth?
    /// Whether the first IORegistry diagnostic dump has been logged (avoid spamming every 2s)
    private var didLogIORegistryDiag = false
    /// Last logged NotChargingReason — only log when it changes
    private var lastLoggedNotChargingReason: UInt64?
    /// Whether full AdapterDetails have been logged (re-log when adapter first appears)
    private var didLogAdapterDetails = false
    /// Last logged ChargerInhibitReason — only log when it changes
    private var lastLoggedInhibitReason: UInt64?

    init(settings: AppSettings = .shared,
         systemHealthReader: @escaping @Sendable () async -> SystemBatteryHealth? = {
             await SystemBatteryHealthProvider.shared.read()
         }) {
        self.settings = settings
        self.systemHealthReader = systemHealthReader
    }

    // MARK: - Lifecycle

    func start() {
        guard !running else { return }
        running = true
        // Open SMC connection (for temperature, power, detailed data)
        do {
            try smc.open()
            smcAvailable = true
            remainingCapacityFormat = SMCRemainingCapacityFormat(bcf0Size: smc.keyInfo("BCF0")?.size)
            log.notice("SMC connected successfully")
        } catch {
            log.error("SMC not available: \(error.localizedDescription, privacy: .public)")
            smcAvailable = false
            remainingCapacityFormat = .unknown
        }

        // Initial read
        update()

        // Start polling
        scheduleTimer()

        // Register for power source change notifications
        registerPowerSourceNotification()
    }

    func stop() {
        running = false
        systemHealthTask?.cancel()
        systemHealthTask = nil
        systemHealthCache.record(nil, at: Date())
        lastSystemHealthRequest = nil
        timer?.invalidate()
        timer = nil
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        runLoopSource = nil
        remainingCapacityFormat = .unknown
        smcAvailable = false
        smc.close()
    }

    /// Immediate refresh when popover opens (don't wait for next tick)
    func popoverDidOpen() {
        update()
    }

    func update() {
        refreshSystemHealthIfNeeded()
        let ioKitState = readIOKitPowerSource()
        let smcState = smcAvailable ? readSMCData() : SMCData()
        let ioRegState = readIORegistryBattery()
        let cachedSystemHealth = systemHealthCache.value(at: Date())
        let capacities = BatteryReadingParser.resolveCapacities(
            full: smcState.fullChargeCapacityValue, design: smcState.designCapacityValue,
            remaining: smcState.remainingCapacityValue, format: remainingCapacityFormat,
            brsc: smcState.brscValue, registry: ioRegState.batteryData,
            normalizedPercentage: ioKitState.percentage
        )
        let condition: SystemBatteryHealth? = ioKitState.systemHealth.condition != .unknown
            ? ioKitState.systemHealth : cachedSystemHealth

        // Always build AdapterInfo from IORegistry when available.
        // SMC VD0R/ID0R override negotiated voltage/current with live readings.
        // Views decide visibility using isPluggedIn + mode (IORegistry caches stale data after unplug).
        let adapterInfo: AdapterInfo? = ioRegState.adapterInfo.map { info in
            AdapterInfo(
                name: info.name,
                description: info.description,
                manufacturer: info.manufacturer,
                model: info.model,
                watts: info.watts,
                voltage: smcState.adapterVoltage ?? info.voltage,
                current: smcState.adapterCurrent ?? info.current,
                serial: info.serial,
                firmware: info.firmware,
                isWireless: info.isWireless,
                usbPDProfiles: info.usbPDProfiles,
                activeProfileIndex: info.activeProfileIndex
            )
        }

        let state = BatteryState(
            percentage: ioKitState.percentage ?? 0,
            hardwarePercentage: capacities.hardwarePercentage,
            isCharging: ioKitState.isCharging,
            isPluggedIn: ioKitState.isPluggedIn,
            currentCapacity: capacities.current,
            maxCapacity: capacities.full,
            designCapacity: capacities.design,
            cycleCount: smcState.cycleCount
                ?? BatteryReadingParser.registryInteger(ioRegState.batteryData?["CycleCount"])
                ?? ioKitState.cycleCount,
            temperature: smcState.temperature,
            voltage: smcState.voltage,
            amperage: smcState.amperage,
            systemPower: smcState.systemPower,
            adapterPower: smcState.adapterPower,
            adapterInfo: adapterInfo,
            batteryPower: smcState.batteryPower,
            notChargingReason: ioRegState.notChargingReason,
            chargerInhibitReason: ioRegState.chargerInhibitReason,
            timeToEmpty: ioKitState.timeToEmpty,
            timeToFull: ioKitState.timeToFull,
            hasValidBatteryReading: ioKitState.hasValidBatteryReading,
            systemMaximumCapacityPercentage: cachedSystemHealth?.maximumCapacityPercentage,
            batteryCondition: condition?.condition ?? .unknown,
            batteryConditionSource: condition?.condition == .unknown ? .unavailable : condition?.source ?? .unavailable,
            systemMaximumCapacitySource: cachedSystemHealth?.maximumCapacityPercentage == nil
                ? .unavailable : .systemProfiler,
            capacitySource: capacities.source,
            currentCapacitySource: capacities.currentSource,
            healthDataQuality: capacities.quality,
            capacityUnavailableReason: capacities.unavailableReason,
            isCurrentCapacityEstimated: capacities.isEstimated
        )

        batteryState = state
    }

    // MARK: - IOKit Power Source (no root needed)

    private func readIOKitPowerSource() -> BatteryPowerSourceSnapshot {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [Any] else {
            return BatteryPowerSourceSnapshot()
        }
        let descriptions = sources.compactMap { source in
            IOPSGetPowerSourceDescription(snapshot, source as CFTypeRef)?.takeUnretainedValue() as? [String: Any]
        }
        return IOPSBatteryParser.parse(descriptions)
    }

    // MARK: - SMC Data (detailed, no root for reads)

    private struct SMCData {
        var temperature: Double?
        var voltage: Double?
        var amperage: Double?
        var systemPower: Double?
        var adapterPower: Double?
        var adapterVoltage: Double?  // VD0R (live adapter voltage)
        var adapterCurrent: Double?  // ID0R (live adapter current)
        var batteryPower: Double?
        var cycleCount: Int?
        var buicPercentage: Int?        // BUIC: UI-smoothed SoC (same as macOS %)
        var brscValue: SMCValue?
        var remainingCapacityValue: SMCValue?
        var fullChargeCapacityValue: SMCValue?
        var designCapacityValue: SMCValue?
    }

    private func readSMCData() -> SMCData {
        var data = SMCData()

        // Temperature: prefer TB0T/TB1T (flt on Apple Silicon) over B0AT (ui16 deci-Kelvin)
        if let val = smc.readKeyOptional("TB0T") {
            if val.dataType.hasPrefix("flt"), let f = val.floatValue {
                data.temperature = Double(f)
            } else if let sp = val.sp78Value {
                data.temperature = sp
            }
        }
        // Fallback to B0AT if TB0T didn't work
        if data.temperature == nil, let val = smc.readKeyOptional("B0AT") {
            if val.dataType == "ui16", let raw = val.uint16Value {
                let celsius = (Double(raw) - 2732.0) / 10.0
                if celsius > -20 && celsius < 100 {
                    data.temperature = celsius
                }
            }
        }

        // Voltage: B0AV in mV
        if let raw = smc.readUInt16("B0AV") {
            data.voltage = Double(raw) / 1000.0
        }

        // Current: B0AC in mA (signed)
        if let raw = smc.readInt16("B0AC") {
            data.amperage = Double(raw) / 1000.0
        }

        // System power: PSTR
        if let val = smc.readKeyOptional("PSTR") {
            if let f = val.floatValue, val.dataType.hasPrefix("flt") {
                data.systemPower = Double(f)
            } else if let sp = val.sp78Value {
                data.systemPower = sp
            }
        }

        // Adapter power: PDTR
        if let val = smc.readKeyOptional("PDTR") {
            if let f = val.floatValue, val.dataType.hasPrefix("flt") {
                data.adapterPower = Double(f)
            } else if let sp = val.sp96Value {
                data.adapterPower = sp
            }
        }

        // Adapter voltage: VD0R (Apple Silicon — flt or uint16 mV)
        if let val = smc.readKeyOptional("VD0R") {
            if val.dataType.hasPrefix("flt"), let f = val.floatValue {
                data.adapterVoltage = Double(f)
            } else if let raw = val.uint16Value {
                data.adapterVoltage = Double(raw) / 1000.0
            }
        }

        // Adapter current: ID0R (Apple Silicon — flt or uint16 mA)
        if let val = smc.readKeyOptional("ID0R") {
            if val.dataType.hasPrefix("flt"), let f = val.floatValue {
                data.adapterCurrent = Double(f)
            } else if let raw = val.uint16Value {
                data.adapterCurrent = Double(raw) / 1000.0
            }
        }

        // Battery power: prefer B0AP (direct hardware measurement in mW) over V*A calculation
        if let val = smc.readKeyOptional("B0AP") {
            if let f = val.floatValue, val.dataType.hasPrefix("flt") {
                data.batteryPower = Double(f)
            } else if let raw = val.int32Value {
                data.batteryPower = Double(raw) / 1000.0  // mW -> W
            }
        }
        // Fallback to V*A if B0AP unavailable
        if data.batteryPower == nil, let v = data.voltage, let a = data.amperage {
            data.batteryPower = v * a
        }

        // Cycle count
        if let raw = BatteryReadingParser.unsigned16(smc.readKeyOptional("B0CT")), raw < 10_000 {
            data.cycleCount = raw
        }

        // BUIC: "Battery UI Charge" — smoothed percentage macOS shows to users.
        // Kept for diagnostics, but NOT used as hardware SoC (it matches IOKit exactly).
        if let raw = smc.readUInt8("BUIC"), raw <= 100 {
            data.buicPercentage = Int(raw)
        }

        // Retain metadata for the shared strict parser. Unknown BRSC formats and
        // unknown B0RM firmware contracts are not guessed into charging percentages.
        data.brscValue = smc.readKeyOptional("BRSC")
        data.fullChargeCapacityValue = smc.readKeyOptional("B0FC")
        data.designCapacityValue = smc.readKeyOptional("B0DC")
        data.remainingCapacityValue = smc.readKeyOptional("B0RM")

        return data
    }

    // MARK: - IORegistry (adapter details, not-charging reason)

    private func readIORegistryBattery() -> (adapterInfo: AdapterInfo?, notChargingReason: UInt64?, chargerInhibitReason: UInt64?, batteryData: [String: Any]?) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return (nil, nil, nil, nil) }
        defer { IOObjectRelease(service) }

        // Read only the keys we need — NOT CreateCFProperties which copies the entire 16KB+ dict
        // (PortControllerInfo alone is 9KB of data we never use)
        let adapterDict = IORegistryEntryCreateCFProperty(service, "AdapterDetails" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any]
        let chargerDict = IORegistryEntryCreateCFProperty(service, "ChargerData" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any]
        var batteryData = IORegistryEntryCreateCFProperty(service, "BatteryData" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any] ?? [:]
        // These are raw mAh fields; CurrentCapacity/MaxCapacity can be normalized percentages.
        for (target, fallback) in [("FullChargeCapacity", "AppleRawMaxCapacity"),
                                   ("RemainingCapacity", "AppleRawCurrentCapacity"),
                                   ("DesignCapacity", "DesignCapacity"), ("CycleCount", "CycleCount")] {
            if batteryData[target] == nil {
                batteryData[target] = IORegistryEntryCreateCFProperty(service, fallback as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue()
            }
        }

        // Parse AdapterDetails
        var adapterInfo: AdapterInfo?
        if let adapter = adapterDict {
            let name = adapter["Name"] as? String
                ?? adapter["Description"] as? String
                ?? "Unknown Adapter"
            let description = adapter["Description"] as? String
            let manufacturer = adapter["Manufacturer"] as? String
            let model = adapter["Model"] as? String
            let watts = adapter["Watts"] as? Int ?? 0

            // AdapterVoltage in mV, Current in mA
            let voltage: Double = {
                if let v = adapter["AdapterVoltage"] as? Int { return Double(v) / 1000.0 }
                return 0
            }()
            let current: Double = {
                if let a = adapter["Current"] as? Int { return Double(a) / 1000.0 }
                return 0
            }()

            let serial = adapter["SerialString"] as? String
            let firmware = adapter["FwVersion"] as? String
            let isWireless = adapter["IsWireless"] as? Bool ?? false

            // USB-PD profiles (keys: MaxVoltage/MaxCurrent in mV/mA)
            var profiles: [USBPDProfile] = []
            if let menu = adapter["UsbHvcMenu"] as? [[String: Any]] {
                for entry in menu {
                    if let v = entry["MaxVoltage"] as? Int, let a = entry["MaxCurrent"] as? Int {
                        profiles.append(USBPDProfile(
                            voltage: Double(v) / 1000.0,
                            current: Double(a) / 1000.0
                        ))
                    }
                }
            }
            let activeIndex = adapter["UsbHvcHvcIndex"] as? Int

            adapterInfo = AdapterInfo(
                name: name,
                description: description,
                manufacturer: manufacturer,
                model: model,
                watts: watts,
                voltage: voltage,
                current: current,
                serial: serial,
                firmware: firmware,
                isWireless: isWireless,
                usbPDProfiles: profiles,
                activeProfileIndex: activeIndex
            )
        }

        // NotChargingReason and ChargerInhibitReason from ChargerData
        var notChargingReason: UInt64?
        var chargerInhibitReason: UInt64?
        if let chargerData = chargerDict {
            if let raw = chargerData["NotChargingReason"] {
                if let val = raw as? UInt64 {
                    notChargingReason = val
                } else if let val = raw as? Int {
                    notChargingReason = UInt64(bitPattern: Int64(val))
                }
                if notChargingReason != lastLoggedNotChargingReason {
                    let hex = String(notChargingReason ?? 0, radix: 16, uppercase: true)
                    log.notice("NotChargingReason: \(notChargingReason ?? 0, privacy: .public) (0x\(hex, privacy: .public))")
                    lastLoggedNotChargingReason = notChargingReason
                }
            }

            // ChargerInhibitReason — may reveal WHO is inhibiting (us vs system)
            if let raw = chargerData["ChargerInhibitReason"] {
                var val: UInt64 = 0
                if let v = raw as? UInt64 { val = v }
                else if let v = raw as? Int { val = UInt64(bitPattern: Int64(v)) }
                chargerInhibitReason = val
                if val != lastLoggedInhibitReason {
                    let hex = String(val, radix: 16, uppercase: true)
                    log.notice("ChargerInhibitReason: \(val, privacy: .public) (0x\(hex, privacy: .public))")
                    lastLoggedInhibitReason = val
                }
            }

            // Log IORegistry dict keys once, and re-log if adapter appears
            // (first read may be on battery with sparse data)
            let hasFullAdapter = (adapterDict?.count ?? 0) > 1
            if !didLogIORegistryDiag || (!didLogAdapterDetails && hasFullAdapter) {
                let chargerKeys = chargerData.keys.sorted().joined(separator: ", ")
                log.info("ChargerData keys: [\(chargerKeys, privacy: .public)]")
                if let adapter = adapterDict {
                    let adapterKeys = adapter.keys.sorted().joined(separator: ", ")
                    log.info("AdapterDetails keys: [\(adapterKeys, privacy: .public)]")
                    if hasFullAdapter { didLogAdapterDetails = true }
                }
                didLogIORegistryDiag = true
            }
        }

        return (adapterInfo, notChargingReason, chargerInhibitReason, batteryData)
    }

    // MARK: - Polling

    /// Fixed 2s polling interval. SMC reads cost ~300µs total per poll — negligible
    /// even on battery. A fixed interval keeps the status bar responsive and charging
    /// verification fast, with no measurable impact on battery life.
    static let pollingInterval: TimeInterval = 2
    static let systemHealthRefreshInterval: TimeInterval = 300
    static let systemHealthCacheLifetime: TimeInterval = SystemBatteryHealthCache.lifetime

    private func refreshSystemHealthIfNeeded(now: Date = Date()) {
        guard running, systemHealthTask == nil,
              lastSystemHealthRequest.map({
                  let age = now.timeIntervalSince($0)
                  return age < 0 || age >= Self.systemHealthRefreshInterval
              }) ?? true
        else { return }
        lastSystemHealthRequest = now
        let reader = systemHealthReader
        systemHealthTask = Task { [weak self, reader] in
            let health = await reader()
            guard !Task.isCancelled, let self, self.running else { return }
            self.systemHealthTask = nil
            // A failed refresh becomes unknown, rather than perpetuating cached Good.
            self.systemHealthCache.record(health, at: Date())
            self.update()
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.update()
            }
        }
    }

    // MARK: - Power Source Notifications

    private func registerPowerSourceNotification() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let ctx = context else { return }
            let service = Unmanaged<BatteryService>.fromOpaque(ctx).takeUnretainedValue()
            // Callback fires on main RunLoop — use assumeIsolated for Swift 6 safety
            MainActor.assumeIsolated {
                service.update()
                service.scheduleTimer()
            }
        }, context)?.takeRetainedValue() {
            self.runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }
}
