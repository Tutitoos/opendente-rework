import Combine
import Foundation
import ServiceManagement

@MainActor
protocol LoginItemServicing {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

@MainActor
private struct SystemLoginItemService: LoginItemServicing {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}

enum LoginItemControlError: LocalizedError {
    case approvalRequired, enableFailed, changeFailed(String)

    var errorDescription: String? {
        switch self {
        case .approvalRequired: "Approve OpenDente in System Settings > General > Login Items."
        case .enableFailed: "Launch at Login could not be enabled."
        case .changeFailed(let detail): "Could not change Launch at Login: \(detail)"
        }
    }
}

/// The service's effective state, rather than a persisted registration intent.
@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var requiresApproval = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var errorSource: LoginItemControlError?
    private let service: any LoginItemServicing
    private let settings: AppSettings
    private var lastObservedStatus: SMAppService.Status?

    init(settings: AppSettings, service: (any LoginItemServicing)? = nil) {
        self.settings = settings
        self.service = service ?? SystemLoginItemService()
        refresh()
    }

    func refresh() {
        let status = service.status
        if lastObservedStatus != status { errorMessage = nil; errorSource = nil }
        lastObservedStatus = status
        isEnabled = status == .enabled
        requiresApproval = status == .requiresApproval
        if settings.launchAtLogin != isEnabled { settings.launchAtLogin = isEnabled }
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        errorSource = nil
        do {
            if enabled { try service.register() } else { try service.unregister() }
            refresh()
            if enabled && !isEnabled {
                let failure: LoginItemControlError = requiresApproval ? .approvalRequired : .enableFailed
                errorSource = failure
                errorMessage = failure.localizedDescription
            }
        } catch {
            refresh()
            let failure = LoginItemControlError.changeFailed(error.localizedDescription)
            errorSource = failure
            errorMessage = failure.localizedDescription
        }
    }
}
