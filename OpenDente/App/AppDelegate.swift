import AppKit
import Combine
import SwiftUI
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var settingsWindowController: NSWindowController?
    private var eventMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var lastIconName: String?
    private var isTerminating = false
    private var terminationReplySent = false
    private var terminationDrain: Task<Void, Never>?
    private var terminationTimeout: Task<Void, Never>?

    private let battery = BatteryService.shared
    private let charging = ChargingManager.shared
    private let settings = AppSettings.shared

    private var canControlCharging: Bool {
        charging.canControlChargeLimit
    }

    // MARK: - App Lifecycle

    /// True when the app is launched as a test host by Xcode.
    /// Tests load into the app process for symbol access, but we skip real services
    /// to avoid SMC commands and UserDefaults pollution from the test host.
    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        guard !Self.isRunningTests else { return }

        battery.start()
        LocalActivityRecorder.shared.start()
        MonthlyFullChargeService.shared.start()
        charging.start()

        setupStatusItem()
        setupPopover()
        updateApplicationMenu()
        setupEventMonitor()
        setupSleepWakeNotifications()

        // Check helper status and prompt for registration if needed
        checkHelperStatus()

        // Update status bar reactively when battery state or mode changes
        battery.$batteryState
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusBarText() }
            .store(in: &cancellables)

        charging.$mode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusBarText() }
            .store(in: &cancellables)

        LanguageManager.shared.$language
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.lastIconName = nil
                self.updateStatusBarText()
                self.settingsWindowController?.window?.title = L10n.tr("OpenDente Settings")
                self.updateApplicationMenu()
            }
            .store(in: &cancellables)

        // Notifications
        NotificationService.shared.requestPermission()
        setupNotifications()
        if CommandLine.arguments.contains("--show-settings") {
            showSettingsWindow()
        } else if CommandLine.arguments.contains("--show-popover") {
            togglePopover()
        }
    }

    private func setupNotifications() {
        var previousMode: ChargingMode = charging.mode

        charging.$mode
            .sink { [weak self] newMode in
                guard let self else { return }
                let canNotifyMode: Bool
                if self.charging.isUsingNativeChargeLimit {
                    canNotifyMode = newMode == .charging || newMode == .onBattery
                        || (newMode == .paused && Self.canNotifyNativeLimitReached(
                            state: self.battery.batteryState,
                            requestedLimit: self.settings.chargeLimit,
                            effectiveLimit: self.charging.effectiveNativeChargeLimit,
                            error: self.charging.nativeChargeLimitError
                        ))
                } else {
                    canNotifyMode = self.charging.supportsSMCControls
                }
                NotificationService.shared.handleModeChange(from: previousMode, to: newMode, settings: self.settings,
                                                           controlAvailable: self.canControlCharging && canNotifyMode)
                previousMode = newMode
            }
            .store(in: &cancellables)

        battery.$batteryState
            .sink { [weak self] state in
                guard let self else { return }
                NotificationService.shared.handleBatteryState(state, mode: self.charging.mode, settings: self.settings,
                                                             controlAvailable: self.charging.supportsSMCControls)
            }
            .store(in: &cancellables)

        charging.events
            .sink { [weak self] event in
                guard let self else { return }
                NotificationService.shared.handleChargingEvent(event, settings: self.settings,
                                                              controlAvailable: self.charging.supportsSMCControls)
            }
            .store(in: &cancellables)
    }

    /// Native pauses can also come from optimized charging or other macOS policies.
    /// Only report our confirmed limit reached when telemetry supports that claim.
    static func canNotifyNativeLimitReached(state: BatteryState, requestedLimit: Int,
                                           effectiveLimit: Int?, error: String?) -> Bool {
        guard error == nil, let effectiveLimit, effectiveLimit == requestedLimit else { return false }
        return state.hasValidBatteryReading && state.isPluggedIn && !state.isCharging
            && state.percentage >= effectiveLimit
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !Self.isRunningTests else { return .terminateNow }
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        MonthlyFullChargeService.shared.stop()
        LocalActivityRecorder.shared.stop()
        terminationDrain = Task { [weak self] in
            await LocalActivityRecorder.shared.flush()
            guard !Task.isCancelled else { return }
            self?.finishTermination()
        }
        terminationTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) }
            catch { return }
            self?.finishTermination()
        }
        return .terminateLater
    }

    private func finishTermination() {
        guard !terminationReplySent else { return }
        terminationReplySent = true
        terminationTimeout?.cancel()
        terminationDrain?.cancel()
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        // Reset temporary SMC controls before exit; the native macOS charge limit persists.
        MonthlyFullChargeService.shared.stop()
        LocalActivityRecorder.shared.stop()
        charging.resetToDefaultsSync()
        HelperClient.shared.disconnect()
        battery.stop()
        cancellables.removeAll()
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        // Remove sleep/wake observers to avoid stale callbacks
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Status Bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.action = #selector(togglePopover)
            button.target = self
            updateStatusBarText()
        }
    }

    private func updateStatusBarText() {
        guard let button = statusItem?.button else { return }

        let state = battery.batteryState
        let pct = state.effectivePercentage(useHardware: settings.useHardwareBatteryPercentage)

        let displayedMode: ChargingMode = canControlCharging ? charging.mode : .idle
        let iconName = !state.hasValidBatteryReading ? "battery.0percent" : settings.statusBarShowMode
            ? displayedMode.batteryIconName(percentage: pct, isCharging: state.isCharging)
            : ChargingMode.idle.batteryIconName(percentage: pct, isCharging: false)
        if iconName != lastIconName {
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            let description = state.hasValidBatteryReading ? L10n.format("Battery %d%%", pct) : L10n.tr("Battery reading unavailable")
            button.image = NSImage(systemSymbolName: iconName, accessibilityDescription: description)?.withSymbolConfiguration(config)
            lastIconName = iconName
        }

        button.setAccessibilityLabel(state.hasValidBatteryReading
            ? L10n.format("OpenDente: battery %d%%, %@", pct, L10n.tr(displayedMode.displayName))
            : L10n.tr("Battery reading unavailable"))
        let text = L10n.statusBarText(state, settings: settings)
        button.title = text.isEmpty ? "" : " " + text
    }

    // MARK: - Popover

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 420)
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: PopoverView(onOpenSettings: { [weak self] in
            self?.showSettingsWindow()
        }))
    }

    /// The popover is hosted outside a SwiftUI scene, so its settings action must
    /// open a retained AppKit window rather than use the scene's openSettings environment.
    @objc private func showSettingsWindow() {
        popover?.performClose(nil)
        if settingsWindowController == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = L10n.tr("OpenDente Settings")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 680, height: 720))
            window.contentMinSize = NSSize(width: 640, height: 460)
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindowController = NSWindowController(window: window)
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func updateApplicationMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "OpenDente")
        let about = NSMenuItem(title: L10n.tr("About OpenDente"),
                              action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        about.target = NSApp
        appMenu.addItem(about)
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: L10n.tr("Settings…"), action: #selector(showSettingsWindow), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: L10n.tr("Quit OpenDente"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem(title: L10n.tr("Edit"), action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: L10n.tr("Edit"))
        editMenu.addItem(NSMenuItem(title: L10n.tr("Undo"), action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: L10n.tr("Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: L10n.tr("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: L10n.tr("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: L10n.tr("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: L10n.tr("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            battery.popoverDidOpen()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - Event Monitor

    private func setupEventMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if let self = self, self.popover.isShown {
                self.popover.performClose(nil)
            }
        }
    }

    // MARK: - Helper

    private func checkHelperStatus() {
        let status = HelperInstaller.status
        NSLog("[OpenDente] Helper status: \(HelperInstaller.statusDescription) (raw: \(String(describing: status)))")

        switch status {
        case .notRegistered:
            guard !charging.isUsingNativeChargeLimit else {
                NSLog("[OpenDente] Native charge limit does not require helper registration")
                charging.isHelperInstalled = false
                return
            }
            NSLog("[OpenDente] Attempting to register helper daemon...")
            if HelperInstaller.register() {
                charging.connectToHelper()
            }
        case .requiresApproval:
            // Don't call register() — it always fails. User must toggle in System Settings.
            NSLog("[OpenDente] Helper needs approval in System Settings > Login Items")
        case .enabled:
            NSLog("[OpenDente] Helper is enabled")
        case .notFound:
            NSLog("[OpenDente] Helper binary not found in app bundle")
        @unknown default:
            break
        }

        charging.isHelperInstalled = HelperInstaller.isRegistered
        NSLog("[OpenDente] Helper registered: \(charging.isHelperInstalled)")
    }

    // MARK: - Sleep/Wake

    private func setupSleepWakeNotifications() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(
            self,
            selector: #selector(willSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        ws.addObserver(
            self,
            selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc private func willSleep(_ notification: Notification) {
        charging.handleWillSleep()
        HelperClient.shared.suspendWatchdog()
    }

    @objc private func didWake(_ notification: Notification) {
        HelperClient.shared.sendHeartbeat()
        // Refresh battery state immediately — it may have changed during sleep
        // (e.g. charger unplugged, battery drained).
        battery.update()
        // Call handleDidWake directly for immediate response — the Combine publisher
        // from battery.update() delivers on the next RunLoop iteration via .receive(on:),
        // but we need to re-evaluate NOW (e.g. resume charging if below limit).
        // The subsequent Combine-triggered evaluateState is redundant but harmless (idempotent).
        charging.handleDidWake(battery.batteryState)
    }

}
