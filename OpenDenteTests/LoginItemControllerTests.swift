import Foundation
import ServiceManagement
import Testing
@testable import OpenDente

@MainActor
struct LoginItemControllerTests {
    private func withController(_ body: (LoginItemController, FakeLoginItemService, AppSettings) -> Void) {
        let name = "com.opendente.tests.login." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        let service = FakeLoginItemService()
        let controller = LoginItemController(settings: settings, service: service)
        body(controller, service, settings)
    }

    @Test func failedRegistrationDoesNotPersistSuccess() {
        withController { controller, service, settings in
            service.fails = true
            controller.setEnabled(true)
            #expect(!controller.isEnabled)
            #expect(!settings.launchAtLogin)
            #expect(controller.errorMessage != nil)
        }
    }

    @Test func failedUnregistrationKeepsEffectiveEnabledState() {
        withController { controller, service, settings in
            controller.setEnabled(true)
            service.fails = true
            controller.setEnabled(false)
            #expect(controller.isEnabled)
            #expect(settings.launchAtLogin)
            #expect(controller.errorMessage != nil)
        }
    }

    @Test func externalChangeIsReconciled() {
        withController { controller, service, settings in
            controller.setEnabled(true)
            #expect(controller.isEnabled && settings.launchAtLogin)
            service.status = .notRegistered
            controller.refresh()
            #expect(!controller.isEnabled && !settings.launchAtLogin)
        }
    }

    @Test func approvalRequiredIsNotShownAsEnabled() {
        withController { controller, service, settings in
            service.registeredStatus = .requiresApproval
            controller.setEnabled(true)
            #expect(controller.requiresApproval)
            #expect(!controller.isEnabled && !settings.launchAtLogin)
            #expect(controller.errorMessage != nil)
        }
    }

    @Test func externalApprovalClearsThePendingApprovalMessage() {
        withController { controller, service, settings in
            service.registeredStatus = .requiresApproval
            controller.setEnabled(true)
            #expect(controller.errorMessage != nil)
            controller.refresh()
            #expect(controller.errorMessage != nil)
            service.status = .enabled
            controller.refresh()
            #expect(controller.isEnabled && settings.launchAtLogin)
            #expect(!controller.requiresApproval)
            #expect(controller.errorMessage == nil)
        }
    }
}

@MainActor
private final class FakeLoginItemService: LoginItemServicing {
    var status: SMAppService.Status = .notRegistered
    var registeredStatus: SMAppService.Status = .enabled
    var fails = false
    func register() throws {
        if fails { throw NSError(domain: "test", code: 1) }
        status = registeredStatus
    }
    func unregister() throws {
        if fails { throw NSError(domain: "test", code: 2) }
        status = .notRegistered
    }
}
