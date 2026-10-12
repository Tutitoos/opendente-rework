import Foundation

/// Event payloads contain stable codes and values, never presentation text.
/// The recorder can translate them in the language selected when they are read.
struct ChargingPolicyFailure: Equatable, Sendable {
    let code: String
    let values: [String: String]

    init(error: Error) {
        switch error {
        case NativeChargeLimitError.unavailable:
            code = "nativeUnavailable"; values = [:]
        case NativeChargeLimitError.invalidState(let detail):
            code = "nativeInvalidState"; values = ["detail": detail]
        case NativeChargeLimitError.unsupportedLimit(let limit):
            code = "nativeUnsupportedLimit"; values = ["limit": String(limit)]
        case NativeChargeLimitError.verificationFailed(let requested, let actual, let enabled):
            code = "nativeVerificationFailed"
            values = ["requested": String(requested), "actual": String(actual), "enabled": String(enabled)]
        case NativeChargeLimitError.optimizedUnavailable:
            code = "optimizedUnavailable"; values = [:]
        case NativeChargeLimitError.optimizedVerificationFailed(let requested, let actual):
            code = "optimizedVerificationFailed"
            values = ["requested": String(requested), "actual": String(actual)]
        case NativeChargeLimitError.temporaryUnavailable:
            code = "temporaryUnavailable"; values = [:]
        case NativeChargeLimitError.temporaryVerificationFailed(let detail):
            code = "temporaryVerificationFailed"; values = ["detail": detail]
        case MonthlyFullChargeError.unavailable:
            code = "monthlyUnavailable"; values = [:]
        case MonthlyFullChargeError.invalidNextDate:
            code = "monthlyInvalidNextDate"; values = [:]
        case MonthlyFullChargeError.policyChangedExternally:
            code = "monthlyPolicyChangedExternally"; values = [:]
        case MonthlyFullChargeError.restoreFailed(let detail):
            code = "monthlyRestoreFailed"; values = ["detail": detail]
        case MonthlyFullChargeError.interrupted:
            code = "monthlyInterrupted"; values = [:]
        case MonthlyChargeJournalError.invalidRecord:
            code = "monthlyJournalInvalid"; values = [:]
        case MonthlyChargeJournalError.unavailable(let operation, let detail):
            code = "monthlyJournalUnavailable"; values = ["operation": operation, "detail": detail]
        case MonthlyChargeJournalError.system(let operation, let systemCode):
            code = "monthlyJournalUnavailable"; values = ["operation": operation, "systemCode": String(systemCode)]
        default:
            let underlying = error as NSError
            code = "chargingPolicyError"
            values = ["domain": underlying.domain, "code": String(underlying.code),
                      "detail": underlying.localizedDescription]
        }
    }
}
