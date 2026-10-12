import AppKit
import Foundation
import UserNotifications
import os.log

private let log = Logger(subsystem: "com.opendente.app", category: "Notifications")

@MainActor
protocol NotificationDelivering {
    func add(_ request: UNNotificationRequest, completion: @escaping @MainActor (Error?) -> Void)
}

@MainActor
private struct SystemNotificationDelivery: NotificationDelivering {
    func add(_ request: UNNotificationRequest, completion: @escaping @MainActor (Error?) -> Void) {
        UNUserNotificationCenter.current().add(request) { error in
            Task { @MainActor in completion(error) }
        }
    }
}

/// Sends macOS notifications for key charging events.
/// Anti-spam: blocks the same event from firing twice in a row.
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {

    static let shared = NotificationService()

    private let sender: any NotificationDelivering
    private var deliveryGeneration = 0

    init(sender: (any NotificationDelivering)? = nil) {
        self.sender = sender ?? SystemNotificationDelivery()
        super.init()
        if sender == nil { UNUserNotificationCenter.current().delegate = self }
    }

    /// Show banner + play sound even when the app is frontmost.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    enum Event: String, Equatable {
        case chargeLimitReached
        case topUpComplete
        case heatProtection
        case dischargeComplete
        case systemChargeLimitConflict
        case inhibitFailed
    }

    /// Last event sent — used to prevent duplicate notifications.
    /// Internal for testability.
    var lastEvent: Event?

    func requestPermission() {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()

            guard settings.authorizationStatus == .notDetermined else {
                if settings.authorizationStatus == .denied {
                    log.info("Notification permission previously denied — user must enable in System Settings")
                }
                return
            }

            // Menu bar apps (.accessory) can't show the permission dialog
            // unless temporarily brought to the foreground as a regular app.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)

            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                log.info("Notification permission: \(granted ? "granted" : "denied", privacy: .public)")
            } catch {
                log.error("Notification permission error: \(error.localizedDescription, privacy: .public)")
            }

            NSApp.setActivationPolicy(.accessory)
        }
    }

    func send(_ event: Event, settings: AppSettings) {
        guard settings.showNotifications else { return }
        guard isEnabled(event, settings: settings) else { return }
        guard event != lastEvent else { return }
        lastEvent = event
        deliveryGeneration += 1
        let generation = deliveryGeneration

        let content = UNMutableNotificationContent()
        switch event {
        case .chargeLimitReached:
            content.title = L10n.tr("Charge Limit Reached")
            content.body = L10n.tr("Battery has reached your charge limit. Charging paused.")
        case .topUpComplete:
            content.title = L10n.tr("Top Up Complete")
            content.body = L10n.tr("Battery is fully charged at 100%.")
        case .heatProtection:
            content.title = L10n.tr("Heat Protection Active")
            content.body = L10n.tr("Charging paused due to high battery temperature.")
        case .dischargeComplete:
            content.title = L10n.tr("Discharge Complete")
            content.body = L10n.tr("Battery has discharged to your charge limit.")
        case .systemChargeLimitConflict:
            content.title = L10n.tr("System Charge Limit Active")
            content.body = L10n.tr("macOS Charge Limit is preventing charging. Raise it to your requested target or turn it off in System Settings > Battery.")
        case .inhibitFailed:
            content.title = L10n.tr("Charging Control Failed")
            content.body = L10n.tr("Unable to stop charging. Try unplugging and re-plugging the charger.")
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "com.opendente.\(event.rawValue)",
            content: content,
            trigger: nil
        )
        sender.add(request) { [weak self] error in
            if let error {
                log.error("Failed to deliver notification: \(error.localizedDescription, privacy: .public)")
                // A failed delivery may be retried, but must not clear a later session's event.
                if self?.deliveryGeneration == generation { self?.lastEvent = nil }
            }
        }
    }

    func clearLastEvent() {
        deliveryGeneration += 1
        lastEvent = nil
    }

    func handleModeChange(from previous: ChargingMode, to mode: ChargingMode, settings: AppSettings,
                          controlAvailable: Bool = true) {
        guard controlAvailable, previous != mode else { return }
        if mode == .charging || mode == .onBattery || mode == .discharging {
            clearLastEvent()
        }
        switch (previous, mode) {
        case (.charging, .paused), (.sailing, .paused): send(.chargeLimitReached, settings: settings)
        case (_, .heatProtection): send(.heatProtection, settings: settings)
        default: break
        }
    }

    func handleChargingEvent(_ event: ChargingEvent, settings: AppSettings, controlAvailable: Bool = true) {
        guard controlAvailable else { return }
        switch event {
        case .dischargeCompleted: send(.dischargeComplete, settings: settings)
        case .topUpStarted: clearLastEvent()
        }
    }

    func handleBatteryState(_ state: BatteryState, mode: ChargingMode, settings: AppSettings,
                            controlAvailable: Bool = true) {
        guard controlAvailable, state.hasValidBatteryReading else { return }
        if mode == .topUp && state.effectivePercentage(useHardware: settings.useHardwareBatteryPercentage) >= 100 {
            send(.topUpComplete, settings: settings)
        }
    }

    private func isEnabled(_ event: Event, settings: AppSettings) -> Bool {
        switch event {
        case .chargeLimitReached: return settings.notifyChargeLimitReached
        case .topUpComplete:      return settings.notifyTopUpComplete
        case .heatProtection:     return settings.notifyHeatProtection
        case .dischargeComplete:  return settings.notifyDischargeComplete
        case .systemChargeLimitConflict: return true  // always notify — important warning
        case .inhibitFailed:            return true  // always notify — safety critical
        }
    }
}
