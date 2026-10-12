import Foundation

/// Error sources remain untranslated in services and persisted event records.
/// Views render them again when the selected language changes.
@MainActor
extension ChargingManager {
    var localizedNativeChargeLimitError: String? {
        nativeChargeLimitErrorSource.map { L10n.error($0) }
            ?? nativeChargeLimitError.map { L10n.tr($0) }
    }

    var localizedOptimizedChargingError: String? {
        optimizedChargingErrorSource.map { L10n.error($0) }
            ?? optimizedChargingError.map { L10n.tr($0) }
    }
}

@MainActor
extension MonthlyFullChargeService {
    var localizedErrorMessage: String? {
        errorSource.map { L10n.error($0) } ?? errorMessage.map { L10n.tr($0) }
    }
}
