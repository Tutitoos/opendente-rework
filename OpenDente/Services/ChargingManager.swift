import Foundation
import Combine
import os.log

private let log = Logger(subsystem: "com.opendente.app", category: "Charging")

/// Protocol for SMC charging control operations. Enables testing without real hardware.
protocol ChargingControl: Sendable {
    func enableCharging(completion: (@Sendable (Bool, String?) -> Void)?)
    func inhibitCharging(completion: (@Sendable (Bool, String?) -> Void)?)
    func forceDischarge(enable: Bool, completion: (@Sendable (Bool, String?) -> Void)?)
    func resetToDefaults(completion: (@Sendable (Bool, String?) -> Void)?)
    func setMagSafeLED(color: UInt8, completion: (@Sendable (Bool, String?) -> Void)?)
    nonisolated func resetToDefaultsSync(timeout: TimeInterval)
}

extension ChargingControl {
    nonisolated func resetToDefaultsSync() {
        resetToDefaultsSync(timeout: 2.0)
    }
}

extension HelperClient: ChargingControl {}

enum ChargingEvent: Equatable, Sendable {
    case dischargeCompleted
    case topUpStarted
}

enum NativeChargingPolicyEvent: Equatable, Sendable {
    case limitRequested(Int)
    case limitChanged(previous: Int?, current: Int, external: Bool)
    case optimizedChargingRequested(Bool)
    case optimizedChargingChanged(previous: Bool?, enabled: Bool, external: Bool)
    case operationFailed(operation: String, code: String, values: [String: String])
}

@MainActor
protocol ChargingOperationTimeoutControl: AnyObject {
    func schedule(after seconds: TimeInterval, action: @escaping @MainActor @Sendable () -> Void)
    func cancel()
}

@MainActor
private final class ChargingOperationTimeout: ChargingOperationTimeoutControl {
    private var task: Task<Void, Never>?

    func schedule(after seconds: TimeInterval, action: @escaping @MainActor @Sendable () -> Void) {
        cancel()
        task = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(seconds))
            } catch {
                return
            }
            action()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

/// Manages charging logic: charge limit, sailing mode, heat protection, discharge, top up.
/// Writes to SMC require root privileges (via privileged helper).
@MainActor
final class ChargingManager: ObservableObject {

    static let shared = ChargingManager()

    /// Events describe completed actions, rather than inferring them from mode changes.
    let events = PassthroughSubject<ChargingEvent, Never>()
    let policyEvents = PassthroughSubject<NativeChargingPolicyEvent, Never>()

    @Published var mode: ChargingMode = .idle {
        didSet {
            if mode != oldValue {
                log.notice("Mode: \(oldValue.displayName, privacy: .public) → \(self.mode.displayName, privacy: .public)")
                inhibitRetryCount = 0
                didNotifyInhibitExhausted = false
                if mode != .charging && mode != .topUp { systemChargeLimitConflict = false }
                updateMagSafeLED()
            }
        }
    }
    @Published var chargingAPI: SMCChargingAPI = .unknown {
        didSet {
            guard nativeChargeLimitControl != nil else { return }
            initializeNativeChargeLimit()
        }
    }
    @Published var isHelperInstalled = false
    @Published private(set) var isPreventingSleep = false
    @Published private(set) var isUsingNativeChargeLimit = false
    @Published private(set) var isReleasingSMCForNative = false
    @Published private(set) var effectiveNativeChargeLimit: Int?
    @Published private(set) var isNativeChargeLimitTemporarilyOverridden = false
    @Published private(set) var availableNativeChargeLimits: [Int] = []
    @Published private(set) var nativeChargeLimitError: String?
    @Published private(set) var nativeChargeLimitErrorSource: Error?
    @Published private(set) var optimizedChargingEnabled: Bool?
    @Published private(set) var optimizedChargingError: String?
    @Published private(set) var optimizedChargingErrorSource: Error?

    var canControlOptimizedCharging: Bool { optimizedChargingEnabled != nil && !isReleasingSMCForNative }

    var supportsSMCControls: Bool {
        isHelperInstalled && chargingAPI != .unknown && !isUsingNativeChargeLimit
    }

    var canControlChargeLimit: Bool {
        supportsSMCControls || (isUsingNativeChargeLimit && effectiveNativeChargeLimit != nil && !isReleasingSMCForNative)
    }

    private let smc = SMCService.shared
    private let battery: BatteryService
    let settings: AppSettings
    private let helper: ChargingControl
    private let sleepAssertion: SleepAssertionControl
    private let controlTimeout: ChargingOperationTimeoutControl
    private let nativeChargeLimitControl: (any NativeChargeLimitControl)?
    private let smcChargingAPIDetector: (() -> SMCChargingAPI)?
    private var cancellables = Set<AnyCancellable>()
    private var nativeInitializationAttempted = false
    private var nativeSupportConfirmed = false
    private var ownsSMCChargingGate = false
    private var ownsSMCDischargeGate = false
    private var nativeSMCReleaseError: Error?
    private var lastObservedSettingsLimit: Int?
    private var nativeRequestError: String?
    private var nativeReadError: String?
    private var nativeRequestErrorSource: Error?
    private var nativeWriteInProgress = false
    private var optimizedRequestError: String?
    private var optimizedRequestErrorSource: Error?
    var heatProtectionTimer: Date?

    private enum ControlOperation: Equatable, Sendable {
        case enableCharging
        case inhibitCharging
        case forceDischarge(Bool)
        case reset
    }

    private struct PendingControlOperation {
        let id: UInt64
        let operation: ControlOperation
        let reportsDischargeCompletion: Bool
        let modeAfterStop: ChargingMode?
    }

    private var controlQueue: [PendingControlOperation] = []
    private var activeControlOperation: PendingControlOperation?
    private var latestControlID: UInt64 = 0
    private var latestDischargeID: UInt64 = 0
    /// Remains true after an ambiguous/partial write until a stop or reset succeeds.
    private var dischargeMayBeActive = false
    private var dischargeStopRequested = false
    private var pendingDischargeCompletion = false
    private var modeAfterDischargeStop: ChargingMode = .idle
    private var automaticDischargeCancelled = false
    private var lastAutomaticDischargeSetting: Bool?
    private var latestBatteryReadingValid: Bool
    private var wakeResyncPending = false

    /// Mode captured at sleep entry — used to know what was happening before sleep.
    /// Internal for testability.
    private(set) var modeBeforeSleep: ChargingMode?

    /// Tracked helper version — used to gate protocol features (e.g. MagSafe LED).
    /// Internal for testability.
    var helperVersion: String?

    /// Last LED color sent to avoid duplicate XPC calls.
    /// Internal setter for testability (simulating helper reconnect).
    var lastLEDColor: UInt8?

    /// Timestamp of last inhibit send — used to debounce verification re-sends.
    /// Internal for testability.
    var lastInhibitTime: Date?

    /// Timestamp of the very first inhibit in the current cycle — used for total elapsed logging.
    var firstInhibitTime: Date?

    /// Number of verification re-sends in the current inhibit cycle.
    /// Reset when IOKit confirms not charging or mode changes.
    var inhibitRetryCount: Int = 0

    /// Whether the enable-mismatch diagnostic has been logged for the current charging cycle.
    private var didLogEnableMismatch = false

    /// Whether we already notified the user about inhibit retry exhaustion this cycle.
    /// Reset when inhibit is confirmed or mode changes.
    /// Internal for testability.
    private(set) var didNotifyInhibitExhausted = false

    /// True when macOS system Charge Limit is blocking our attempt to charge.
    /// We set CHTE to enable, but the system's separate firmware gate stays closed.
    @Published private(set) var systemChargeLimitConflict = false

    /// Last known IOKit isCharging state — used by LED to reflect hardware truth
    /// regardless of which evaluateState code path ran.
    private(set) var lastIsCharging: Bool = false

    private convenience init() {
        self.init(settings: .shared, helper: HelperClient.shared, battery: .shared,
                  sleepAssertion: SleepAssertionManager(),
                  nativeChargeLimitControl: PowerUINativeChargeLimitControl())
    }

    /// Initializer with dependency injection for testability
    init(settings: AppSettings, helper: ChargingControl, battery: BatteryService,
         sleepAssertion: SleepAssertionControl? = nil,
         controlTimeout: ChargingOperationTimeoutControl? = nil,
         nativeChargeLimitControl: (any NativeChargeLimitControl)? = nil,
         smcChargingAPIDetector: (() -> SMCChargingAPI)? = nil) {
        self.settings = settings
        self.helper = helper
        self.battery = battery
        self.sleepAssertion = sleepAssertion ?? SleepAssertionManager()
        self.controlTimeout = controlTimeout ?? ChargingOperationTimeout()
        self.nativeChargeLimitControl = nativeChargeLimitControl
        self.smcChargingAPIDetector = smcChargingAPIDetector
        self.latestBatteryReadingValid = battery.batteryState.hasValidBatteryReading
    }

    // MARK: - Lifecycle

    func start() {
        log.notice("Starting — limit: \(self.settings.chargeLimit, privacy: .public)%, sailing: \(self.settings.sailingModeEnabled ? "on" : "off", privacy: .public), heat protection: \(self.settings.heatProtectionEnabled ? "on" : "off", privacy: .public)")
        detectChargingAPI()
        initializeNativeChargeLimit()
        connectToHelper()

        // React to battery state changes
        battery.$batteryState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.evaluateState(state)
            }
            .store(in: &cancellables)

        // React to settings changes (e.g. charge limit, sailing range) so the state
        // machine re-evaluates immediately instead of waiting for the next battery poll.
        // .receive(on:) defers to the next RunLoop iteration, after the new value is set.
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.handleSettingsChange()
                // Resync sleep setting with helper on any settings change.
                // Lightweight: sends a single bool over XPC, no SMC writes.
                self.syncSleepSettingsWithHelper()
            }
            .store(in: &cancellables)

        // Evaluate immediately — the Combine publisher delivers on next run loop,
        // but we need mode set before setupStatusItem() runs
        evaluateState(battery.batteryState)
    }

    /// Connect to the helper daemon and start heartbeat.
    /// Called at startup and after helper installation.
    func connectToHelper() {
        // Injected controls must never inspect or connect to the real test-host daemon.
        guard let client = helper as? HelperClient else { return }
        let status = HelperInstaller.status
        isHelperInstalled = (status == .enabled)
        log.info("Helper status: \(HelperInstaller.statusDescription, privacy: .public)")

        if isHelperInstalled {
            client.connect()

            // Auto-resync when helper restarts (crash recovery) or reconnects
            client.onHelperRestarted = { [weak self] in
                log.info("Helper restarted/reconnected — resyncing state")
                self?.syncWithHelper()
            }

            syncWithHelper()
        }
    }

    /// Query helper version/API and resync charging state.
    /// Called on initial connection and after helper restarts.
    private func syncWithHelper() {
        guard let client = helper as? HelperClient else { return }
        client.getChargingAPI { [weak self] api in
            Task { @MainActor in
                guard let self else { return }
                switch api {
                case "legacy": self.chargingAPI = .legacy
                case "tahoe":  self.chargingAPI = .tahoe
                default: self.chargingAPI = .unknown
                }
                self.refreshNativeChargingPolicy()
                self.retryNativeSMCRelease()
                self.evaluateState(self.battery.batteryState)
                self.syncSleepSettingsWithHelper()
            }
        }
        client.getVersion { [weak self] version in
            Task { @MainActor in
                self?.helperVersion = version
                log.info("Helper version: \(version, privacy: .public)")
                // Reset LED cache — helper may have restarted with default LED state
                self?.lastLEDColor = nil
                self?.updateMagSafeLED()
                // Sync sleep settings with helper (defense-in-depth)
                self?.syncSleepSettingsWithHelper()
                // Resync charging state with the (re)connected helper
                self?.resyncChargingState()
            }
        }
    }

    /// Sync the stopChargingWhenSleeping setting to the helper (version-gated).
    /// Also computes the LED color the helper should use when inhibiting on sleep.
    private func syncSleepSettingsWithHelper() {
        guard let client = helper as? HelperClient,
              let version = helperVersion,
              version.isVersionAtLeast(HelperConstants.minVersionSleepSync) else {
            return
        }
        // 0xFF = sentinel for "don't touch LED" (when controlMagSafeLED is off)
        let ledColor: UInt8 = supportsSMCControls && settings.controlMagSafeLED
            ? (settings.magSafeLEDOffWhenInactive ? HelperConstants.ledOff : HelperConstants.ledGreen)
            : 0xFF
        client.syncSleepSettings(
            stopChargingWhenSleeping: supportsSMCControls && settings.stopChargingWhenSleeping,
            sleepLEDColor: ledColor
        )
    }

    // MARK: - API Detection

    /// Detect which SMC keys this Mac supports for charging control (read-only, no root needed)
    private func detectChargingAPI() {
        if let smcChargingAPIDetector {
            chargingAPI = smcChargingAPIDetector()
            return
        }
        // Try Tahoe keys first (newer)
        if smc.keyExists("CHTE") {
            chargingAPI = .tahoe
            log.notice("Detected Tahoe charging API (CHTE/CHIE)")
        } else if smc.keyExists("CH0B") {
            chargingAPI = .legacy
            log.notice("Detected legacy charging API (CH0B/CH0C)")
        } else {
            chargingAPI = .unknown
            log.notice("No charging control keys detected")
        }

        logDiagnosticDump()
    }

    // MARK: - Native Charge Limit

    private var usesNativePolicy: Bool {
        isUsingNativeChargeLimit
    }

    /// Called once at startup. A failed discovery may recover by reading later,
    /// but must not silently write an old desired limit during that recovery.
    func initializeNativeChargeLimit() {
        guard let nativeChargeLimitControl else { return }
        guard !nativeInitializationAttempted else { return }
        nativeInitializationAttempted = true
        lastObservedSettingsLimit = settings.chargeLimit
        do {
            let snapshot = try nativeChargeLimitControl.readState()
            // macOS is authoritative. Discovery must never overwrite the Mac
            // with an old app preference, even on a machine that also has SMC.
            try acceptNativeSnapshot(snapshot, adoptSetting: true)
        } catch {
            recordNativeReadFailure(error)
        }
        refreshOptimizedCharging()
    }

    /// Refresh only reads. Adoption stamps the observed setting before publishing
    /// it, so Combine's deferred objectWillChange cannot turn it into a write.
    func refreshNativeChargeLimit() {
        guard nativeInitializationAttempted else {
            initializeNativeChargeLimit()
            return
        }
        guard let nativeChargeLimitControl else { return }
        do {
            let snapshot = try nativeChargeLimitControl.readState()
            try acceptNativeSnapshot(snapshot, adoptSetting: true)
        } catch {
            recordNativeReadFailure(error)
        }
    }

    func refreshNativeChargingPolicy() {
        refreshNativeChargeLimit()
        refreshOptimizedCharging()
    }

    private func refreshOptimizedCharging() {
        guard let nativeChargeLimitControl else { return }
        do {
            let actual = try nativeChargeLimitControl.readOptimizedChargingState().enabled
            let previous = optimizedChargingEnabled
            optimizedChargingEnabled = actual
            optimizedChargingError = optimizedRequestError
            optimizedChargingErrorSource = optimizedRequestErrorSource
            if previous != actual {
                policyEvents.send(.optimizedChargingChanged(previous: previous, enabled: actual, external: true))
            }
        } catch {
            optimizedChargingEnabled = nil
            optimizedChargingError = error.localizedDescription
            optimizedChargingErrorSource = error
        }
    }

    @discardableResult
    func setOptimizedChargingEnabled(_ enabled: Bool) -> Bool {
        guard !isReleasingSMCForNative else { return false }
        guard let nativeChargeLimitControl else { return false }
        policyEvents.send(.optimizedChargingRequested(enabled))
        optimizedRequestError = nil
        optimizedRequestErrorSource = nil
        do {
            let previous = optimizedChargingEnabled
            _ = try nativeChargeLimitControl.setOptimizedCharging(enabled)
            // A success reply is insufficient: native readback must agree.
            let snapshot = try nativeChargeLimitControl.readOptimizedChargingState()
            let actual = snapshot.enabled
            optimizedChargingEnabled = actual
            guard actual == enabled, !snapshot.temporarilyOverridden else {
                throw NativeChargeLimitError.optimizedVerificationFailed(requested: enabled, actual: actual)
            }
            optimizedChargingError = nil
            optimizedChargingErrorSource = nil
            if previous != actual {
                policyEvents.send(.optimizedChargingChanged(previous: previous, enabled: actual, external: false))
            }
            return true
        } catch {
            optimizedRequestError = error.localizedDescription
            optimizedRequestErrorSource = error
            optimizedChargingEnabled = try? nativeChargeLimitControl.readOptimizedCharging()
            optimizedChargingError = optimizedRequestError
            optimizedChargingErrorSource = error
            sendPolicyFailure(operation: "optimizedCharging", error: error)
            return false
        }
    }

    /// An explicit request is active only after independent native readback.
    /// SMC callers retain the existing setting-driven state machine.
    @discardableResult
    func setChargeLimit(_ limit: Int) -> Bool {
        if !nativeInitializationAttempted { initializeNativeChargeLimit() }
        if usesNativePolicy {
            guard !isReleasingSMCForNative else { return false }
            if !nativeInitializationAttempted {
                nativeInitializationAttempted = true
                lastObservedSettingsLimit = settings.chargeLimit
            }
            enterNativePolicyIfNeeded()
            refreshNativeChargeLimit()
            policyEvents.send(.limitRequested(limit))
            return applyNativeChargeLimit(limit)
        }
        guard supportsSMCControls else { return false }
        settings.chargeLimit = limit
        return true
    }

    /// Shared by the real settings subscription and deterministic regression tests.
    func handleSettingsChange() {
        if usesNativePolicy {
            let desired = settings.chargeLimit
            if desired != lastObservedSettingsLimit {
                lastObservedSettingsLimit = desired
                _ = setChargeLimit(desired)
            }
        }
        evaluateState(battery.batteryState)
    }

    private func acceptNativeSnapshot(_ snapshot: NativeChargeLimitSnapshot, adoptSetting: Bool) throws {
        let limits = snapshot.availableLimits.sorted()
        guard !limits.isEmpty, Set(limits).count == limits.count,
              limits.allSatisfy({ (80...100).contains($0) }),
              limits.contains(100), (0...100).contains(snapshot.limit),
              [0, 1, 3].contains(snapshot.nativeFeatureState),
              snapshot.enabled == (snapshot.nativeFeatureState == 1),
              !snapshot.enabled || limits.contains(snapshot.limit),
              (80...100).contains(snapshot.effectiveLimit),
              limits.contains(snapshot.effectiveLimit) else {
            throw NativeChargeLimitError.invalidState("malformed native policy snapshot")
        }
        let previous = effectiveNativeChargeLimit
        nativeSupportConfirmed = true
        enterNativePolicyIfNeeded()
        availableNativeChargeLimits = limits
        effectiveNativeChargeLimit = snapshot.effectiveLimit
        isNativeChargeLimitTemporarilyOverridden = snapshot.isTemporaryOverride
        nativeReadError = nil
        nativeChargeLimitError = nativeSMCReleaseError?.localizedDescription ?? nativeRequestError
        nativeChargeLimitErrorSource = nativeSMCReleaseError ?? nativeRequestErrorSource
        if adoptSetting {
            // Preserve the pre-migration SMC value separately, then reflect
            // native truth in the primary UI setting without a feedback write.
            if settings.legacySMCChargeLimit == nil {
                settings.legacySMCChargeLimit = settings.chargeLimit
            }
            let habitualLimit = snapshot.isTemporaryOverride
                ? settings.monthlyFullChargeCycle?.previousPolicy.chargeLimit.effectiveLimit
                    ?? (settings.monthlyChargeRecoveryUnknown ? settings.chargeLimit : snapshot.effectiveLimit)
                : snapshot.effectiveLimit
            lastObservedSettingsLimit = habitualLimit
            if settings.chargeLimit != habitualLimit {
                settings.chargeLimit = habitualLimit
            }
        }
        if previous != snapshot.effectiveLimit {
            policyEvents.send(.limitChanged(previous: previous, current: snapshot.effectiveLimit,
                                           external: nativeWriteInProgress == false))
        }
    }

    private func recordNativeReadFailure(_ error: Error) {
        nativeReadError = "Cannot read the native charge limit: \(error.localizedDescription)"
        effectiveNativeChargeLimit = nil
        isNativeChargeLimitTemporarilyOverridden = false
        availableNativeChargeLimits = []
        nativeChargeLimitError = [nativeRequestError, nativeReadError].compactMap { $0 }.joined(separator: " ")
        nativeChargeLimitErrorSource = nativeSMCReleaseError ?? nativeRequestErrorSource ?? error
        // A transient failed read of a supported backend must not make SMC
        // write against a possibly active native policy. Only initial discovery
        // on an unsupported Mac may use the established SMC fallback.
        let unsupported = (error as? NativeChargeLimitError) == .unavailable
        if nativeSupportConfirmed || chargingAPI == .unknown || !unsupported {
            enterNativePolicyIfNeeded()
        }
    }

    private func recordUnsupportedNativeLimit(_ limit: Int) {
        let choices = availableNativeChargeLimits.map { "\($0)%" }.joined(separator: ", ")
        nativeRequestError = "The requested limit \(limit)% is unsupported by macOS. Choose \(choices)."
        nativeRequestErrorSource = NativeChargeLimitError.unsupportedLimit(limit)
        nativeChargeLimitError = nativeRequestError
        nativeChargeLimitErrorSource = nativeRequestErrorSource
    }

    @discardableResult
    private func applyNativeChargeLimit(_ limit: Int) -> Bool {
        guard effectiveNativeChargeLimit != nil, let nativeChargeLimitControl else { return false }
        guard availableNativeChargeLimits.contains(limit) else {
            recordUnsupportedNativeLimit(limit)
            sendPolicyFailure(operation: "chargeLimit", error: NativeChargeLimitError.unsupportedLimit(limit))
            return false
        }
        nativeRequestError = nil
        nativeRequestErrorSource = nil
        nativeWriteInProgress = true
        defer { nativeWriteInProgress = false }
        do {
            // The service verifies its write; read independently as well so a
            // reply alone never makes an unobserved requested limit look active.
            _ = try nativeChargeLimitControl.setLimit(limit)
            let actual = try nativeChargeLimitControl.readState()
            try acceptNativeSnapshot(actual, adoptSetting: true)
            guard actual.effectiveLimit == limit, limit != 100 || (!actual.enabled && !actual.isTemporaryOverride) else {
                nativeRequestError = "macOS did not apply \(limit)%; its effective limit is \(actual.effectiveLimit)% (native policy enabled: \(actual.enabled))."
                let failure = NativeChargeLimitError.verificationFailed(requested: limit, actual: actual.effectiveLimit, enabled: actual.enabled)
                nativeRequestErrorSource = failure
                nativeChargeLimitError = nativeRequestError
                nativeChargeLimitErrorSource = failure
                sendPolicyFailure(operation: "chargeLimit", error: failure)
                return false
            }
            nativeChargeLimitError = nil
            nativeChargeLimitErrorSource = nil
            if battery.batteryState.hasValidBatteryReading {
                evaluateNativeBatteryState(battery.batteryState)
            }
            return true
        } catch {
            nativeRequestError = "Cannot apply \(limit)%: \(error.localizedDescription)"
            nativeRequestErrorSource = error
            do {
                try acceptNativeSnapshot(nativeChargeLimitControl.readState(), adoptSetting: true)
            } catch {
                recordNativeReadFailure(error)
            }
            nativeChargeLimitError = [nativeRequestError, nativeReadError].compactMap { $0 }.joined(separator: " ")
            nativeChargeLimitErrorSource = nativeRequestErrorSource
            sendPolicyFailure(operation: "chargeLimit", error: error)
            return false
        }
    }

    private func sendPolicyFailure(operation: String, error: Error) {
        let failure = ChargingPolicyFailure(error: error)
        policyEvents.send(.operationFailed(operation: operation, code: failure.code, values: failure.values))
    }

    private func clearSMCTrackingForNativePolicy() {
        // A native handoff must first finish the existing app-owned write and
        // confirm the targeted release. Clearing it early loses ownership.
        if isReleasingSMCForNative {
            controlQueue.removeAll()
            return
        }
        latestControlID &+= 1
        latestDischargeID = latestControlID
        controlQueue.removeAll()
        activeControlOperation = nil
        controlTimeout.cancel()
        pendingDischargeCompletion = false
        dischargeMayBeActive = false
        dischargeStopRequested = false
        firstInhibitTime = nil
        lastInhibitTime = nil
        inhibitRetryCount = 0
        didNotifyInhibitExhausted = false
        systemChargeLimitConflict = false
        heatProtectionTimer = nil
        if isPreventingSleep {
            sleepAssertion.allowSleep()
            isPreventingSleep = false
        }
    }

    /// Backend entry is separate from one-time startup preference application.
    /// Every return from SMC must invalidate its active/queued callbacks, while
    /// native recovery only reads and adopts the persistent macOS policy.
    private func enterNativePolicyIfNeeded() {
        guard nativeChargeLimitControl != nil, !isUsingNativeChargeLimit else { return }
        isUsingNativeChargeLimit = true
        let activeMayInhibit = activeControlOperation?.operation == .inhibitCharging ||
            activeControlOperation?.operation == .forceDischarge(true)
        if ownsSMCChargingGate || ownsSMCDischargeGate || dischargeMayBeActive || activeMayInhibit {
            isReleasingSMCForNative = true
            controlQueue.removeAll()
            continueNativeSMCRelease()
            return
        }
        clearSMCTrackingForNativePolicy()
    }

    /// Reconnection can retry a failed release. Ordinary policy polling never
    /// repeats hardware writes or takes ownership of gates set by another app.
    func retryNativeSMCRelease() {
        guard isReleasingSMCForNative, activeControlOperation == nil else { return }
        nativeSMCReleaseError = nil
        continueNativeSMCRelease()
    }

    private func continueNativeSMCRelease() {
        guard isReleasingSMCForNative, activeControlOperation == nil, nativeSMCReleaseError == nil else { return }
        if ownsSMCDischargeGate || dischargeMayBeActive {
            enqueueControl(.forceDischarge(false))
        } else if ownsSMCChargingGate {
            enqueueControl(.enableCharging)
        } else {
            isReleasingSMCForNative = false
            nativeChargeLimitError = nativeRequestError
            nativeChargeLimitErrorSource = nativeRequestErrorSource
            clearSMCTrackingForNativePolicy()
            if battery.batteryState.hasValidBatteryReading { evaluateNativeBatteryState(battery.batteryState) }
        }
    }

    private func failNativeSMCRelease(detail: String?) {
        let failure = NSError(domain: "com.opendente.nativeSMCRelease", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "The app's previous SMC charging control could not be released."])
        nativeSMCReleaseError = failure
        nativeChargeLimitError = failure.localizedDescription
        nativeChargeLimitErrorSource = failure
        log.error("Native handoff could not release an app-owned SMC gate: \(detail ?? "unknown error", privacy: .public)")
        policyEvents.send(.operationFailed(operation: "releaseSMC", code: "smcReleaseFailed",
                                          values: ["detail": detail ?? "unknown error"]))
    }

    private func evaluateNativeBatteryState(_ state: BatteryState) {
        lastIsCharging = state.isCharging
        if !state.isPluggedIn {
            mode = .onBattery
        } else if state.isCharging {
            mode = .charging
        } else if state.systemChargeLimitActive
                    || effectiveNativeChargeLimit.map({ state.percentage >= $0 }) == true {
            mode = .paused
        } else {
            mode = .idle
        }
    }

    /// One-time diagnostic dump at startup for Tahoe investigation.
    private func logDiagnosticDump() {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osStr = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"

        var model = "unknown"
        var size: Int = 0
        if sysctlbyname("hw.model", nil, &size, nil, 0) == 0 {
            var buf = [CChar](repeating: 0, count: size)
            if sysctlbyname("hw.model", &buf, &size, nil, 0) == 0 {
                model = String(decoding: buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }

        let diagnosticKeys = ["CHTE", "CHIE", "CH0B", "CH0C", "CH0I", "CH0J", "ACLC"]
        var keyLines: [String] = []
        for key in diagnosticKeys {
            if let info = smc.keyInfo(key) {
                let valueStr: String
                if let value = smc.readKeyOptional(key) {
                    let hex = value.bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
                    valueStr = "  value=[\(hex)]"
                } else {
                    valueStr = "  value=<unreadable>"
                }
                keyLines.append("  \(key): exists=true  type=\(info.type)  size=\(info.size)\(valueStr)")
            } else {
                keyLines.append("  \(key): exists=false")
            }
        }

        let state = battery.batteryState
        let pct = state.percentage
        let apiName: String
        switch chargingAPI {
        case .tahoe: apiName = "tahoe"
        case .legacy: apiName = "legacy"
        case .unknown: apiName = "unknown"
        }

        log.notice("""
        === OpenDente Diagnostic Dump ===
        macOS: \(osStr, privacy: .public)
        Model: \(model, privacy: .public)
        Charging API: \(apiName, privacy: .public)
        \(keyLines.joined(separator: "\n"), privacy: .public)
        Battery: \(pct, privacy: .public)%, charging=\(state.isCharging, privacy: .public), pluggedIn=\(state.isPluggedIn, privacy: .public)
        =================================
        """)
    }

    // MARK: - State Machine

    /// Evaluate battery state and decide charging mode. Internal for testability.
    func evaluateState(_ state: BatteryState) {
        // Missing/invalid internal-battery data is not a zero-percent reading.
        // Preserve gates, thermal holds, cancellation and sleep tracking until
        // the next valid snapshot instead of applying invented percentage data.
        latestBatteryReadingValid = state.hasValidBatteryReading
        if nativeChargeLimitControl != nil { refreshNativeChargingPolicy() }
        if usesNativePolicy {
            guard state.hasValidBatteryReading else { return }
            evaluateNativeBatteryState(state)
            return
        }
        guard state.hasValidBatteryReading else { return }
        if wakeResyncPending {
            handleDidWake(state)
            return
        }
        let pct = state.effectivePercentage(useHardware: settings.useHardwareBatteryPercentage)

        lastIsCharging = state.isCharging
        defer {
            verifyInhibitedCharging(state, percentage: pct)
            updateSleepAssertion(state)
            updateMagSafeLED()
        }

        if lastAutomaticDischargeSetting != settings.automaticDischarge {
            automaticDischargeCancelled = false
            lastAutomaticDischargeSetting = settings.automaticDischarge
        }

        // A failed stop can leave the discharge gate active even though the user
        // cancelled or normal evaluation selected another mode. Clear it before
        // sending further charge commands or losing the adapter-present exception.
        if dischargeStopRequested {
            retryDischargeStopIfNeeded()
            return
        }

        // Not plugged in = on battery, nothing to control.
        // Exception: during force discharge, IOKit reports power source as "battery"
        // even though the charger is physically connected. Don't kill our own discharge.
        guard state.isPluggedIn || mode == .discharging else {
            if mode == .topUp {
                log.info("Top Up ended: unplugged at \(state.percentage, privacy: .public)%")
            }
            // Clean slate — no pending inhibit verification on battery
            firstInhibitTime = nil
            lastInhibitTime = nil
            inhibitRetryCount = 0
            if let adapterPower = state.adapterPower, adapterPower < 0.1 {
                automaticDischargeCancelled = false
            }
            mode = .onBattery
            return
        }

        // Heat protection takes priority
        if settings.heatProtectionEnabled, mode == .heatProtection, state.temperature == nil {
            return // Missing sensor data cannot prove the battery has cooled.
        }
        if settings.heatProtectionEnabled, let temp = state.temperature {
            if temp >= settings.heatProtectionTemp {
                // Reset hysteresis timer on every spike (including re-spikes during cooldown)
                heatProtectionTimer = Date()
                if mode != .heatProtection {
                    log.warning("Heat protection: \(temp, format: .fixed(precision: 1), privacy: .public)°C ≥ \(self.settings.heatProtectionTemp, format: .fixed(precision: 1), privacy: .public)°C at \(state.percentage, privacy: .public)%")
                    let wasDischarging = mode == .discharging
                    mode = .heatProtection
                    if wasDischarging {
                        forceDischarge(false)
                    }
                    inhibitCharging()
                }
                return
            } else if mode == .heatProtection {
                if let timer = heatProtectionTimer {
                    // Hysteresis: wait 5 minutes after temp last exceeded threshold
                    if Date().timeIntervalSince(timer) >= 300 {
                        log.info("Heat protection ended: \(temp, format: .fixed(precision: 1), privacy: .public)°C < \(self.settings.heatProtectionTemp, format: .fixed(precision: 1), privacy: .public)°C, cooldown elapsed")
                        heatProtectionTimer = nil
                        // Fall through to normal evaluation
                    } else {
                        return // Still in hysteresis period
                    }
                }
                // heatProtectionTimer is nil — hysteresis ended, fall through to re-evaluate
            }
        }

        // Top Up mode — stay until unplugged (guard above) or user cancels
        if mode == .topUp {
            updateSystemChargeLimitConflict(state)
            return
        }

        // Calibration mode - handled separately
        if mode == .calibrating {
            return
        }

        // Discharge mode - don't override until unplugged (or auto-discharge reaches limit)
        if mode == .discharging {
            // Real unplug detection: during force discharge, IOKit reports isPluggedIn=false.
            // A real unplug is when isPluggedIn=false AND adapter power is gone.
            if !state.isPluggedIn, let adapterPower = state.adapterPower, adapterPower < 0.1 {
                log.info("Discharge ended: charger unplugged at \(pct, privacy: .public)%")
                mode = .onBattery
                automaticDischargeCancelled = false
                forceDischarge(false)
                return
            }
            if pct <= settings.chargeLimit {
                log.info("Discharge reached limit: \(pct, privacy: .public)% ≤ \(self.settings.chargeLimit, privacy: .public)%")
                finishDischargeAtLimit()
                if dischargeStopRequested { return }
                // Fall through to normal evaluation
            } else {
                return
            }
        }

        let limit = settings.chargeLimit

        // Sailing mode = hysteresis to prevent micro-cycling (80→79→charge→80→…).
        // Two asymmetric thresholds:
        //   Stop charging at:  limit (e.g. 80%)
        //   Start charging at: lowerBound (e.g. 70%) — only if sailing enabled
        // Sailing is entered from .paused/.heatProtection (dropping from above)
        // or from .onBattery/.idle (plug-in/app start within range).
        // NEVER from .charging — that would cut off a charge cycle before reaching the limit.
        if settings.sailingModeEnabled {
            let lowerBound = settings.sailingLowerBound

            if pct >= limit {
                if mode != .paused {
                    log.notice("Limit reached: \(pct, privacy: .public)% ≥ \(limit, privacy: .public)% → paused")
                    let needsInhibit = mode != .sailing && mode != .heatProtection
                    mode = .paused
                    if needsInhibit {
                        inhibitCharging()
                    }
                }
            } else if pct >= lowerBound {
                if mode == .charging {
                    // Keep charging toward limit — don't interrupt
                } else if mode != .sailing {
                    log.notice("Sailing: \(pct, privacy: .public)% in range \(lowerBound, privacy: .public)–\(limit, privacy: .public)%")
                    let needsInhibit = mode != .paused && mode != .heatProtection
                    mode = .sailing
                    if needsInhibit {
                        inhibitCharging()
                    }
                }
            } else {
                if mode != .charging {
                    log.notice("Below range: \(pct, privacy: .public)% < \(lowerBound, privacy: .public)% → charging to \(limit, privacy: .public)%")
                    mode = .charging
                    enableCharging()
                }
            }
        } else {
            // No sailing mode — simple limit
            if pct >= limit {
                if mode != .paused {
                    log.notice("Limit reached: \(pct, privacy: .public)% ≥ \(limit, privacy: .public)% → paused")
                    let needsInhibit = mode != .heatProtection
                    mode = .paused
                    if needsInhibit {
                        inhibitCharging()
                    }
                }
            } else {
                if mode != .charging {
                    log.notice("Below limit: \(pct, privacy: .public)% < \(limit, privacy: .public)% → charging")
                    mode = .charging
                    enableCharging()
                }
            }
        }

        // Automatic discharge: if battery > limit and auto-discharge is on
        if settings.automaticDischarge && !automaticDischargeCancelled && pct > limit && mode == .paused {
            log.notice("Auto-discharge: \(pct, privacy: .public)% > \(limit, privacy: .public)%")
            startDischarge()
        }

        // System charge limit conflict detection.
        updateSystemChargeLimitConflict(state)

        // Diagnostic: if we enabled charging but IOKit says not charging and it's
        // NOT the system charge limit, log SMC readback once per cycle for diagnostics.
        if mode == .charging && !state.isCharging && state.isPluggedIn
            && !state.systemChargeLimitActive && !didLogEnableMismatch {
            if let val = smc.readKeyOptional("CHTE") {
                let hex = val.bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
                log.warning("Enable mismatch: mode=charging but isCharging=false — CHTE readback: [\(hex, privacy: .public)]")
            } else if let val = smc.readKeyOptional("CH0B") {
                let hex = val.bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
                log.warning("Enable mismatch: mode=charging but isCharging=false — CH0B readback: [\(hex, privacy: .public)]")
            }
            didLogEnableMismatch = true
        } else if mode != .charging || state.isCharging {
            didLogEnableMismatch = false
        }
    }

    /// Runs for all exits from evaluation, including heat and cooldown holds.
    private func verifyInhibitedCharging(_ state: BatteryState, percentage pct: Int) {
        // Verification: system is the source of truth.
        // If we think charging is inhibited but IOKit still reports isCharging,
        // the SMC write may not have taken effect — re-send.
        // IOKit can lag 15-30s on Apple Silicon before reflecting the new state,
        // so debounce at 15s and limit to 3 retries to avoid unnecessary SMC writes.
        let inhibitElapsed = lastInhibitTime.map { Date().timeIntervalSince($0) } ?? .infinity
        let totalInhibitElapsed = firstInhibitTime.map { Date().timeIntervalSince($0) } ?? .infinity
        if (mode == .paused || mode == .sailing || mode == .heatProtection)
            && state.isCharging {
            let inhibitPending = activeControlOperation?.operation == .inhibitCharging
                || controlQueue.contains { $0.operation == .inhibitCharging }
            if inhibitElapsed >= 15 && inhibitRetryCount < 3 && !inhibitPending {
                inhibitRetryCount += 1
                log.warning("IOKit still reports charging in \(self.mode.displayName, privacy: .public) mode — re-sending inhibit (\(self.inhibitRetryCount, privacy: .public)/3, \(String(format: "%.0f", totalInhibitElapsed), privacy: .public)s since first inhibit) | IOKit: isCharging=\(state.isCharging, privacy: .public), pct=\(pct, privacy: .public)%, adapterPower=\(String(format: "%.1f", state.adapterPower ?? -1), privacy: .public)W, batteryPower=\(String(format: "%.1f", state.batteryPower ?? 0), privacy: .public)W")
                inhibitCharging()
            } else if inhibitRetryCount >= 3 && !didNotifyInhibitExhausted {
                didNotifyInhibitExhausted = true
                log.error("Inhibit retry exhausted (3/3, \(String(format: "%.0f", totalInhibitElapsed), privacy: .public)s since first inhibit) — SMC writes may be overridden by system | IOKit: isCharging=\(state.isCharging, privacy: .public), pct=\(pct, privacy: .public)%, adapterPower=\(String(format: "%.1f", state.adapterPower ?? -1), privacy: .public)W, batteryPower=\(String(format: "%.1f", state.batteryPower ?? 0), privacy: .public)W")
                NotificationService.shared.send(.inhibitFailed, settings: settings)
            }
        } else if (mode == .paused || mode == .sailing || mode == .heatProtection)
                    && !state.isCharging && lastInhibitTime != nil
                    && inhibitElapsed >= 2 {
            // Require ≥2s since inhibit write to avoid confirming in the same evaluateState
            // call that sent the inhibit (e.g. cable plug with stale SMC inhibit).
            if inhibitRetryCount > 0 {
                log.notice("IOKit confirmed: charging stopped in \(self.mode.displayName, privacy: .public) mode (after \(self.inhibitRetryCount, privacy: .public) retries, \(String(format: "%.0f", totalInhibitElapsed), privacy: .public)s)")
            } else {
                log.notice("IOKit confirmed: charging stopped in \(self.mode.displayName, privacy: .public) mode")
            }
            inhibitRetryCount = 0
            firstInhibitTime = nil
            lastInhibitTime = nil
            didNotifyInhibitExhausted = false
        }
    }

    // MARK: - Sleep/Wake

    /// Called by AppDelegate when macOS is about to sleep.
    /// If stopChargingWhenSleeping is on: inhibits charging so the battery doesn't
    /// charge to 100% during sleep. Also stops discharge (pointless during sleep).
    func handleWillSleep() {
        // macOS owns the persistent native gate, including while asleep.
        guard !usesNativePolicy else { return }
        modeBeforeSleep = mode
        log.notice("Will sleep: mode=\(self.mode.displayName, privacy: .public), stopCharging=\(self.settings.stopChargingWhenSleeping, privacy: .public), disableSleep=\(self.settings.disableSleepUntilChargeLimit, privacy: .public)")

        // Always stop discharge before sleep — no system load means meaningless drain
        if mode == .discharging {
            forceDischarge(false)
            log.info("Will sleep: stopped discharge")
        }

        guard settings.stopChargingWhenSleeping else {
            log.info("Will sleep: stopChargingWhenSleeping OFF — no inhibit")
            return
        }
        // If mode is .onBattery or .idle, there's nothing to inhibit
        guard mode != .onBattery && mode != .idle else {
            log.info("Will sleep: mode is \(self.mode.displayName, privacy: .public) — nothing to inhibit")
            return
        }

        // Pre-emptively inhibit charging before sleep.
        // Even if already inhibited (paused/sailing), re-send as defense in depth —
        // macOS may have cleared the SMC state.
        inhibitCharging()

        // Update LED to reflect that charging is now inhibited.
        // Without this, LED stays orange (frozen) during sleep even though
        // charging was stopped. MagSafe LED is visible with the lid closed.
        if settings.controlMagSafeLED {
            let color = settings.magSafeLEDOffWhenInactive
                ? HelperConstants.ledOff
                : HelperConstants.ledGreen
            sendLEDColor(color)
        }

        log.notice("Will sleep: inhibited charging (stopChargingWhenSleeping)")
    }

    /// Called by AppDelegate after macOS wakes from sleep.
    /// Clears stale state and re-evaluates — the state machine handles all transitions.
    func handleDidWake(_ currentState: BatteryState) {
        if usesNativePolicy {
            modeBeforeSleep = nil
            wakeResyncPending = false
            evaluateState(currentState)
            return
        }
        guard currentState.hasValidBatteryReading else {
            latestBatteryReadingValid = false
            wakeResyncPending = true
            return
        }
        wakeResyncPending = false
        let previousMode = modeBeforeSleep
        let pct = currentState.effectivePercentage(useHardware: settings.useHardwareBatteryPercentage)
        log.notice("Did wake: modeBeforeSleep=\(previousMode?.displayName ?? "nil", privacy: .public), battery=\(pct, privacy: .public)%, pluggedIn=\(currentState.isPluggedIn, privacy: .public), isCharging=\(currentState.isCharging, privacy: .public)")

        modeBeforeSleep = nil
        // Clear stale verification state from before sleep
        firstInhibitTime = nil
        lastInhibitTime = nil
        inhibitRetryCount = 0
        didNotifyInhibitExhausted = false
        // LED hardware state may differ from lastLEDColor — the helper's sleep
        // callback writes ACLC directly without updating the app's tracking variable.
        // Reset so updateMagSafeLED() re-sends unconditionally after wake.
        lastLEDColor = nil

        // A successful sleep stop needs normal evaluation on wake. If that stop
        // is unresolved, retain tracking until its retry succeeds, then evaluate
        // normally instead of leaving an inactive gate in .discharging forever.
        if mode == .discharging {
            if dischargeStopRequested {
                modeAfterDischargeStop = .onBattery
            } else {
                mode = .onBattery
            }
        }

        let modeBeforeEval = mode
        evaluateState(currentState)

        // evaluateState skips SMC writes when mode hasn't changed (optimization).
        // After sleep, SMC state may be stale (we inhibited during sleep, or macOS
        // reset charging state). Re-send the correct command if mode was unchanged.
        if mode == modeBeforeEval {
            resyncSMCAfterWake()
        }

        log.notice("Did wake: evaluated → mode=\(self.mode.displayName, privacy: .public)")
    }

    /// Re-send the SMC command for the current mode after wake.
    /// Called when evaluateState kept the same mode and thus skipped the SMC write.
    private func resyncSMCAfterWake() {
        guard supportsSMCControls else { return }
        if dischargeStopRequested {
            retryDischargeStopIfNeeded()
            return
        }
        switch mode {
        case .charging, .topUp:
            enableCharging()
            log.info("Wake resync: re-enabled charging")
        case .paused, .sailing, .heatProtection:
            inhibitCharging()
            log.info("Wake resync: re-inhibited charging")
        case .discharging:
            forceDischarge(true)
            log.info("Wake resync: re-enabled discharge")
        case .onBattery, .idle, .calibrating:
            break
        }
    }

    // MARK: - Sleep Assertion

    /// Update IOPMAssertion to prevent/allow system idle sleep.
    /// Called at the end of every evaluateState.
    private func updateSleepAssertion(_ state: BatteryState) {
        guard !usesNativePolicy else { return }
        guard settings.disableSleepUntilChargeLimit else {
            if isPreventingSleep {
                log.info("Sleep assertion: released (setting disabled)")
                sleepAssertion.allowSleep()
                isPreventingSleep = false
            }
            return
        }

        let pct = state.effectivePercentage(useHardware: settings.useHardwareBatteryPercentage)
        // Keep awake while actively working toward the charge limit
        // An unavailable adapter reading cannot establish a physical unplug
        // while force discharge itself makes IOKit report battery power.
        let adapterPresent = state.isPluggedIn
            || (mode == .discharging && (state.adapterPower.map { $0 >= 0.1 } ?? true))
        let shouldPrevent = adapterPresent
            && pct != settings.chargeLimit
            && (mode == .charging || mode == .discharging)

        if shouldPrevent && !isPreventingSleep {
            log.info("Sleep assertion: preventing sleep (mode=\(self.mode.displayName, privacy: .public), \(pct, privacy: .public)% → \(self.settings.chargeLimit, privacy: .public)%)")
            isPreventingSleep = sleepAssertion.preventSleep(
                reason: "OpenDente: Charging to \(settings.chargeLimit)%"
            )
        } else if !shouldPrevent && isPreventingSleep {
            log.info("Sleep assertion: released (mode=\(self.mode.displayName, privacy: .public), pct=\(pct, privacy: .public)%, limit=\(self.settings.chargeLimit, privacy: .public)%, pluggedIn=\(state.isPluggedIn, privacy: .public))")
            sleepAssertion.allowSleep()
            isPreventingSleep = false
        }
    }

    // MARK: - System Charge Limit Conflict

    /// Detect when macOS system Charge Limit (26.4+) is blocking our attempt to charge.
    /// The system uses a separate firmware gate from CHTE — both must be open.
    /// NotChargingReason bit 24 (0x1000000) = system-level inhibit.
    private func updateSystemChargeLimitConflict(_ state: BatteryState) {
        let wantsToCharge = mode == .charging || mode == .topUp
        let batteryReceivingPower = (state.batteryPower ?? 0) > 0.1

        if wantsToCharge && !state.isCharging && state.isPluggedIn
            && state.systemChargeLimitActive && !batteryReceivingPower {
            if !systemChargeLimitConflict {
                systemChargeLimitConflict = true
                let hex = String(state.notChargingReason ?? 0, radix: 16, uppercase: true)
                log.warning("System charge limit conflict: NotChargingReason=0x\(hex, privacy: .public) — system is blocking via separate gate")
                NotificationService.shared.send(.systemChargeLimitConflict, settings: settings)
            }
        } else if systemChargeLimitConflict {
            systemChargeLimitConflict = false
            log.notice("System charge limit conflict cleared")
        }
    }

    // MARK: - Actions

    /// Whether SMC commands can be sent (helper installed and API detected)
    private var canControlCharging: Bool {
        supportsSMCControls
    }

    /// Start Top Up - temporarily charge to 100%
    func startTopUp() {
        guard canControlCharging, canStartWithBatteryReading, !dischargeStopRequested else {
            log.warning("Cannot start Top Up: \(self.controlUnavailableReason, privacy: .public)")
            return
        }
        log.notice("Top Up started at \(self.battery.batteryState.percentage, privacy: .public)% (limit was \(self.settings.chargeLimit, privacy: .public)%)")

        events.send(.topUpStarted)
        mode = .topUp
        enableCharging()
    }

    /// Cancel Top Up manually — inhibit charging as a safe default,
    /// next poll will re-evaluate the correct mode.
    func cancelTopUp() {
        guard supportsSMCControls, mode == .topUp else { return }
        log.notice("Top Up cancelled by user at \(self.battery.batteryState.percentage, privacy: .public)%")

        mode = .idle
        inhibitCharging()
    }

    /// Manually start discharge
    func startDischarge() {
        guard canControlCharging, canStartWithBatteryReading, !dischargeStopRequested else {
            log.warning("Cannot start discharge: \(self.controlUnavailableReason, privacy: .public)")
            return
        }
        log.notice("Discharge started at \(self.battery.batteryState.percentage, privacy: .public)%")
        automaticDischargeCancelled = false
        mode = .discharging
        forceDischarge(true)
    }

    /// Stop discharge
    func stopDischarge() {
        guard !usesNativePolicy else { return }
        log.notice("Discharge stopped at \(self.battery.batteryState.percentage, privacy: .public)%")
        automaticDischargeCancelled = true
        lastAutomaticDischargeSetting = settings.automaticDischarge
        // Cancel a start that has not reached the helper yet.
        controlQueue.removeAll { $0.operation == .forceDischarge(true) }
        mode = .idle
        forceDischarge(false)
    }

    private func finishDischargeAtLimit() {
        mode = .idle
        forceDischarge(false, reportsCompletion: true)
    }

    /// Manually pause charging at current level
    func pauseCharging() {
        guard canControlCharging else {
            log.warning("Cannot pause charging: \(self.controlUnavailableReason, privacy: .public)")
            return
        }
        log.notice("Charging paused manually at \(self.battery.batteryState.percentage, privacy: .public)%")
        mode = .paused
        inhibitCharging()
    }

    private var controlUnavailableReason: String {
        if usesNativePolicy { return "this action requires SMC controls; macOS manages the native charge limit" }
        if !isHelperInstalled { return "helper not installed" }
        if chargingAPI == .unknown { return "no charging API detected" }
        if dischargeStopRequested { return "waiting for discharge to stop" }
        if !canStartWithBatteryReading { return "battery reading unavailable" }
        return "unknown"
    }

    private var canStartWithBatteryReading: Bool {
        latestBatteryReadingValid && battery.batteryState.hasValidBatteryReading
    }

    // MARK: - SMC Charging Control (via Helper)

    /// Disable charging (battery stops receiving charge, Mac runs from adapter)
    private func inhibitCharging() {
        guard !usesNativePolicy, isHelperInstalled else { return }
        guard chargingAPI != .unknown else {
            log.warning("Cannot inhibit charging: no API detected")
            return
        }

        enqueueControl(.inhibitCharging)
    }

    /// Enable charging (allow battery to charge)
    private func enableCharging() {
        guard !usesNativePolicy, isHelperInstalled else { return }
        guard chargingAPI != .unknown else {
            log.warning("Cannot enable charging: no API detected")
            return
        }

        // End any pending inhibit verification cycle
        firstInhibitTime = nil
        lastInhibitTime = nil
        inhibitRetryCount = 0
        didNotifyInhibitExhausted = false

        enqueueControl(.enableCharging)
    }

    /// Force discharge (Mac runs from battery while plugged in)
    private func forceDischarge(_ enable: Bool, reportsCompletion: Bool = false) {
        guard !usesNativePolicy, isHelperInstalled else { return }
        guard chargingAPI != .unknown else {
            log.warning("Cannot set discharge: no API detected")
            return
        }

        dischargeStopRequested = !enable
        pendingDischargeCompletion = !enable && reportsCompletion
        modeAfterDischargeStop = mode
        enqueueControl(.forceDischarge(enable), reportsCompletion: reportsCompletion,
                       modeAfterStop: enable ? nil : mode)
    }

    private func retryDischargeStopIfNeeded() {
        guard canControlCharging else { return }
        let alreadyStopping = activeControlOperation?.operation == .forceDischarge(false)
            || activeControlOperation?.operation == .reset
            || controlQueue.contains { $0.operation == .forceDischarge(false) || $0.operation == .reset }
        guard !alreadyStopping else { return }
        enqueueControl(.forceDischarge(false), reportsCompletion: pendingDischargeCompletion,
                       modeAfterStop: modeAfterDischargeStop)
    }

    /// One charging operation at a time: XPC reply scheduling and the helper's
    /// lock do not guarantee that independently sent writes execute in order.
    private func enqueueControl(_ operation: ControlOperation, reportsCompletion: Bool = false,
                                modeAfterStop: ChargingMode? = nil) {
        latestControlID &+= 1
        let command = PendingControlOperation(id: latestControlID, operation: operation,
                                              reportsDischargeCompletion: reportsCompletion,
                                              modeAfterStop: modeAfterStop)
        switch operation {
        case .forceDischarge, .reset:
            latestDischargeID = command.id
        default:
            break
        }
        controlQueue.append(command)
        sendNextControlOperation()
    }

    private func sendNextControlOperation() {
        guard !usesNativePolicy || isReleasingSMCForNative else { return }
        guard activeControlOperation == nil, !controlQueue.isEmpty else { return }
        let command = controlQueue.removeFirst()
        activeControlOperation = command
        controlTimeout.schedule(after: 15) { [weak self, id = command.id] in
            self?.finishControlOperation(id: id, success: false, error: "Helper reply timed out")
        }
        let reply: @Sendable (Bool, String?) -> Void = { [weak self, id = command.id] success, error in
            Self.deliverControlReply { [weak self] in
                self?.finishControlOperation(id: id, success: success, error: error)
            }
        }
        switch command.operation {
        case .enableCharging:
            helper.enableCharging(completion: reply)
        case .inhibitCharging:
            lastInhibitTime = Date()
            if firstInhibitTime == nil { firstInhibitTime = lastInhibitTime }
            helper.inhibitCharging(completion: reply)
        case .forceDischarge(let enable):
            if enable { dischargeMayBeActive = true }
            helper.forceDischarge(enable: enable, completion: reply)
        case .reset:
            helper.resetToDefaults(completion: reply)
        }
    }

    private nonisolated static func deliverControlReply(
        _ action: @escaping @MainActor @Sendable () -> Void
    ) {
        // HelperClient replies on main. Keep synchronous test controls synchronous,
        // while still supporting a control that invokes its reply off-main.
        if Thread.isMainThread {
            MainActor.assumeIsolated { action() }
        } else {
            Task { @MainActor in action() }
        }
    }

    private func finishControlOperation(id: UInt64, success: Bool, error: String?) {
        // An invalidated operation or duplicate reply cannot drain a newer queue.
        guard let command = activeControlOperation, command.id == id else { return }
        controlTimeout.cancel()
        activeControlOperation = nil

        if success {
            switch command.operation {
            case .inhibitCharging: ownsSMCChargingGate = true
            case .enableCharging: ownsSMCChargingGate = false
            case .forceDischarge(true): ownsSMCChargingGate = true; ownsSMCDischargeGate = true
            case .forceDischarge(false): ownsSMCDischargeGate = false; dischargeMayBeActive = false
            case .reset: ownsSMCChargingGate = false; ownsSMCDischargeGate = false; dischargeMayBeActive = false
            }
        }
        if isReleasingSMCForNative {
            if success { continueNativeSMCRelease() }
            else {
                // A reply failure cannot prove the previously dispatched own
                // inhibition was rolled back. Retain it for targeted recovery.
                if command.operation == .inhibitCharging || command.operation == .forceDischarge(true) {
                    ownsSMCChargingGate = true
                }
                failNativeSMCRelease(detail: error)
            }
            return
        }

        if success {
            switch command.operation {
            case .forceDischarge(false), .reset:
                dischargeMayBeActive = false
                if command.id == latestDischargeID {
                    dischargeStopRequested = false
                    pendingDischargeCompletion = false
                    if mode == .discharging, command.modeAfterStop != nil {
                        mode = modeAfterDischargeStop
                    }
                    if command.reportsDischargeCompletion {
                        events.send(.dischargeCompleted)
                    }
                }
            default:
                break
            }
            log.info("Control operation \(id, privacy: .public) completed")
        } else {
            log.error("Control operation \(id, privacy: .public) failed: \(error ?? "unknown error", privacy: .public)")
            switch command.operation {
            case .forceDischarge(let enable) where command.id == latestDischargeID:
                // A failed multi-key write may already have enabled discharge.
                // Retain that uncertainty and retry a stop, rather than erasing it.
                dischargeMayBeActive = true
                dischargeStopRequested = true
                if enable { modeAfterDischargeStop = .idle }
                pendingDischargeCompletion = command.reportsDischargeCompletion
                mode = .discharging
                // These writes were chosen before we knew the discharge gate
                // was uncertain. Re-evaluate them after a confirmed stop.
                controlQueue.removeAll()
                if enable {
                    enqueueControl(.forceDischarge(false), modeAfterStop: .idle)
                }
            case .reset where command.id == latestDischargeID && dischargeMayBeActive:
                dischargeStopRequested = true
                modeAfterDischargeStop = .idle
                mode = .discharging
                controlQueue.removeAll()
            default:
                if command.id == latestControlID && !dischargeMayBeActive && mode != .heatProtection {
                    mode = .idle
                }
            }
        }
        sendNextControlOperation()
    }

    // MARK: - Helper Resync

    /// Re-send current mode's SMC commands after helper reconnects.
    private func resyncChargingState() {
        guard supportsSMCControls else { return }
        log.info("Resyncing charging state after helper reconnect (mode: \(self.mode.displayName, privacy: .public))")
        if dischargeStopRequested {
            retryDischargeStopIfNeeded()
            return
        }
        switch mode {
        case .charging, .topUp:
            enableCharging()
        case .paused, .sailing, .heatProtection:
            inhibitCharging()
        case .discharging:
            forceDischarge(true)
        case .onBattery, .idle, .calibrating:
            break
        }
        updateMagSafeLED()
    }

    // MARK: - MagSafe LED

    /// Update MagSafe LED to reflect current mode + IOKit truth.
    /// Uses `lastIsCharging` (updated every evaluateState) so LED reflects
    /// hardware reality, not just mode intent.
    /// Gated behind helper version check — calling setMagSafeLED on an old helper
    /// that doesn't implement it would disrupt the XPC connection.
    private func updateMagSafeLED() {
        guard supportsSMCControls else { return }
        guard settings.controlMagSafeLED else {
            // If disabled, reset to auto (only if we previously set something)
            if lastLEDColor != nil && lastLEDColor != HelperConstants.ledAuto {
                sendLEDColor(HelperConstants.ledAuto)
            }
            return
        }
        guard let version = helperVersion,
              version.isVersionAtLeast(HelperConstants.minVersionMagSafeLED) else {
            return
        }

        // LED reflects both mode intent AND IOKit truth:
        // - charging/topUp/discharging → always orange (we're actively controlling)
        // - system charge limit conflict → green/off (system is blocking, not actually charging)
        // - inhibited modes → orange while IOKit still reports charging (transition),
        //   then green/off once IOKit confirms charging actually stopped.
        let isCharging = lastIsCharging
        let color: UInt8
        if mode == .onBattery || mode == .idle {
            color = HelperConstants.ledAuto
        } else if systemChargeLimitConflict {
            // System is blocking — LED should reflect "not charging" despite our intent
            color = settings.magSafeLEDOffWhenInactive ? HelperConstants.ledOff : HelperConstants.ledGreen
        } else if mode == .discharging || mode == .charging || mode == .topUp {
            color = HelperConstants.ledOrange
        } else if isCharging {
            color = HelperConstants.ledOrange  // IOKit still reports charging (transition)
        } else {
            // IOKit confirms not charging
            switch mode {
            case .paused, .sailing, .heatProtection, .calibrating:
                color = settings.magSafeLEDOffWhenInactive ? HelperConstants.ledOff : HelperConstants.ledGreen
            default:
                color = HelperConstants.ledAuto
            }
        }

        sendLEDColor(color)
    }

    private func sendLEDColor(_ color: UInt8) {
        guard supportsSMCControls else { return }
        guard color != lastLEDColor else { return }
        lastLEDColor = color
        helper.setMagSafeLED(color: color) { success, error in
            if !success, let error {
                log.debug("MagSafe LED not available: \(error, privacy: .public)")
            }
        }
    }

    // MARK: - Cleanup

    /// Reset all SMC charging keys to defaults (enable charging, stop discharge)
    func resetToDefaults() {
        if usesNativePolicy {
            clearSMCTrackingForNativePolicy()
            // A reset ends app-owned operations, not the user's persistent macOS limit.
            if battery.batteryState.hasValidBatteryReading {
                evaluateNativeBatteryState(battery.batteryState)
            }
            return
        }
        // Supersede queued work; the currently executing request must finish
        // before the reset is sent. Its late reply cannot change the new intent.
        controlQueue.removeAll()
        pendingDischargeCompletion = false
        dischargeStopRequested = dischargeMayBeActive
        modeAfterDischargeStop = .idle
        automaticDischargeCancelled = false
        wakeResyncPending = false
        mode = .idle
        enqueueControl(.reset)
        // Reset LED to system default (only if helper supports it)
        if let version = helperVersion,
           version.isVersionAtLeast(HelperConstants.minVersionMagSafeLED) {
            helper.setMagSafeLED(color: HelperConstants.ledAuto, completion: nil)
        }
        lastLEDColor = nil
        sleepAssertion.allowSleep()
        isPreventingSleep = false
    }

    /// Synchronous reset for app termination
    func resetToDefaultsSync() {
        if usesNativePolicy {
            log.notice("App terminating — preserving macOS native charge limit")
            clearSMCTrackingForNativePolicy()
            return
        }
        log.notice("App terminating — resetting SMC to defaults")
        latestControlID &+= 1
        latestDischargeID = latestControlID
        controlQueue.removeAll()
        activeControlOperation = nil
        controlTimeout.cancel()
        pendingDischargeCompletion = false
        wakeResyncPending = false
        helper.resetToDefaultsSync(timeout: 2.0)
        dischargeMayBeActive = false
        dischargeStopRequested = false
        sleepAssertion.allowSleep()
        isPreventingSleep = false
        mode = .idle
    }
}
