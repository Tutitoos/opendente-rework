import Foundation
import Testing
@testable import OpenDente

@Suite("Event presentation languages")
@MainActor
struct LocalActivityLocalizationTests {
    @Test func changingPresentationLanguageDoesNotRewriteTheEvent() throws {
        let event = LocalActivityEvent(category: .nativePolicy, code: "native.limitConfirmed",
                                       values: ["limit": "80", "external": "false"])
        let before = try JSONEncoder().encode(event)
        let english = event.localizedSummary(language: .english)
        let spanish = event.localizedSummary(language: .spanish)
        #expect(english != spanish)
        #expect(english.contains("80%"))
        #expect(spanish.contains("80%"))
        #expect(try JSONEncoder().encode(event) == before)
        #expect(event.code == "native.limitConfirmed")
    }

    @Test func monthlyFailureAndPendingCauseAreTranslatedFromStableCodes() throws {
        let event = LocalActivityEvent(category: .monthlyCharge, severity: .error, code: "monthly.failed",
                                       values: ["failureCode": "monthlyInterrupted"])
        let english = try #require(event.localizedExplanation(language: .english))
        let spanish = try #require(event.localizedExplanation(language: .spanish))
        #expect(english != spanish)
        #expect(english.contains("restored"))
        #expect(!spanish.contains("restored"))
        let pending = LocalActivityEvent(category: .monthlyCharge, code: "monthly.pending", values: ["reason": "power"])
        #expect(pending.localizedExplanation(language: .english) != pending.localizedExplanation(language: .spanish))
    }

    @Test func verificationFailureUsesStableNumericValuesInBothLanguages() throws {
        let event = LocalActivityEvent(category: .nativePolicy, severity: .error, code: "native.operationFailed",
            values: ["operation": "chargeLimit", "failureCode": "nativeVerificationFailed",
                     "requested": "90", "actual": "80", "enabled": "true"])
        let english = try #require(event.localizedExplanation(language: .english))
        let spanish = try #require(event.localizedExplanation(language: .spanish))
        #expect(english != spanish)
        #expect(english.contains("90%") && english.contains("80%"))
        #expect(spanish.contains("90%") && spanish.contains("80%"))
    }
}
