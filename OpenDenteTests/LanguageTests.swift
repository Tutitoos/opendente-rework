import Combine
import Foundation
import Testing
@testable import OpenDente

@Suite("Languages and battery health presentation")
@MainActor
struct LanguageTests {
    @Test(arguments: ["es", "es-ES", "es-MX", "es_ES", "es-419"])
    func resolvesSpanishSystemVariants(_ identifier: String) {
        #expect(AppLanguage.resolve(.system, preferredLanguages: [identifier]) == .spanish)
    }

    @Test(arguments: ["en", "en-GB", "fr-FR", "de-DE", "ca-ES"])
    func usesEnglishForOtherSystemLanguages(_ identifier: String) {
        #expect(AppLanguage.resolve(.system, preferredLanguages: [identifier]) == .english)
    }

    @Test func persistsManualSelectionAndPublishesWithoutRestart() throws {
        let suite = "com.opendente.tests.language.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let manager = LanguageManager(settings: settings, preferredLanguages: { ["es-ES"] }, observeSystemChanges: false)
        #expect(manager.selection == .system)
        #expect(manager.language == .spanish)
        var observed: [AppLanguage] = []
        let observation = manager.$language.dropFirst().sink { observed.append($0) }
        manager.selection = .english
        #expect(manager.language == .english)
        #expect(settings.languageSelection == .english)
        manager.selection = .spanish
        #expect(observed == [.english, .spanish])
        let reloaded = LanguageManager(settings: AppSettings(defaults: defaults),
                                       preferredLanguages: { ["en-GB"] }, observeSystemChanges: false)
        #expect(reloaded.selection == .spanish)
        #expect(reloaded.language == .spanish)
        observation.cancel()
    }

    @Test func corruptPreferenceFallsBackToSystem() throws {
        let suite = "com.opendente.tests.language.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("unsupported", forKey: "languageSelection")
        #expect(AppSettings(defaults: defaults).languageSelection == .system)
    }

    @Test func bothResourceCataloguesHaveMatchingKeysAndSafeFormats() throws {
        let bundle = Bundle(for: LanguageManager.self)
        let englishURL = try #require(bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: "en.lproj"))
        let spanishURL = try #require(bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: "es.lproj"))
        let english = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: englishURL), options: [], format: nil) as? [String: String])
        let spanish = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: spanishURL), options: [], format: nil) as? [String: String])
        #expect(Set(english.keys) == Set(spanish.keys))
        #expect(L10n.localized("Battery Health", language: .english, bundle: bundle) == "Battery Health")
        #expect(L10n.localized("Battery Health", language: .spanish, bundle: bundle) == "Salud de la batería")
        #expect(L10n.localized("Native limit: %@", language: .spanish, bundle: bundle) == "Límite nativo: %@")
        for (key, value) in spanish {
            let placeholders = #/%(?:\d+\$)?[-+0#]*\d*(?:\.\d+)?(?:ll|l)?[@dfuxX]/#
            #expect(key.matches(of: placeholders).map { String($0.output) }
                    == value.matches(of: placeholders).map { String($0.output) })
            #expect(!value.isEmpty)
        }
    }

    @Test func missingHealthReadingsStaySeparateAndDoNotBecomeZero() {
        let missing = BatteryHealthPresentation(applePercentage: nil, openDentePercentage: nil)
        #expect(missing.appleLabel == "—")
        #expect(missing.openDenteLabel == "—")
        let appleOnly = BatteryHealthPresentation(applePercentage: 100, openDentePercentage: nil)
        #expect(appleOnly.appleLabel == "100%")
        #expect(appleOnly.openDenteLabel == "—")
        let ratioOnly = BatteryHealthPresentation(applePercentage: nil, openDentePercentage: 95.125)
        #expect(ratioOnly.appleLabel == "—")
        #expect(ratioOnly.openDenteLabel == L10n.format("%.1f%%", 95.125))
    }
}
