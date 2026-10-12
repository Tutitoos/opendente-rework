import Foundation
import Testing
@testable import OpenDente

@Suite("Monthly journal error languages")
@MainActor
struct MonthlyJournalLocalizationTests {
    @Test func journalErrorsTranslateWithoutChangingTheirSourceOrPersistedFailure() throws {
        let bundle = Bundle(for: LanguageManager.self)
        let cases: [(MonthlyChargeJournalError, String, String)] = [
            (.invalidRecord,
             "The monthly charge recovery record is invalid. Temporary charging is paused.",
             "El registro de recuperación de la carga mensual no es válido. La carga temporal está pausada."),
            (.system(operation: "read", code: 5),
             "The monthly charge recovery record could not be read or saved.",
             "El registro de recuperación de la carga mensual no se ha podido leer o guardar."),
            (.unavailable(operation: "createDirectory", detail: "Denied"),
             "The monthly charge recovery record could not be read or saved.",
             "El registro de recuperación de la carga mensual no se ha podido leer o guardar.")
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for (error, english, spanish) in cases {
            let failure = ChargingPolicyFailure(error: error)
            let event = LocalActivityEvent(category: .monthlyCharge, severity: .error,
                code: "monthly.failed", values: failure.values.merging(["failureCode": failure.code]) { _, new in new })
            let persisted = try encoder.encode(event)

            #expect(error.localizedDescription == english)
            #expect(L10n.localized(error.localizedDescription, language: .english, bundle: bundle) == english)
            #expect(L10n.localized(error.localizedDescription, language: .spanish, bundle: bundle) == spanish)
            #expect(error.localizedDescription == english)
            #expect(ChargingPolicyFailure(error: error) == failure)
            #expect(try encoder.encode(event) == persisted)
        }
    }
}
