import Combine
import Foundation

enum LanguageSelection: String, CaseIterable, Identifiable, Codable, Sendable {
    case system, english, spanish

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "System"
        case .english: "English"
        case .spanish: "Español"
        }
    }
}

enum AppLanguage: String, Sendable {
    case english = "en"
    case spanish = "es"

    static func resolve(_ selection: LanguageSelection, preferredLanguages: [String]) -> Self {
        switch selection {
        case .english: .english
        case .spanish: .spanish
        case .system:
            preferredLanguages.first?.lowercased().replacingOccurrences(of: "_", with: "-")
                .split(separator: "-").first == "es" ? .spanish : .english
        }
    }

    var locale: Locale { Locale(identifier: self == .spanish ? "es_ES" : "en_US") }
}

/// Owns the language for both SwiftUI and the retained AppKit windows.
/// Explicit bundle selection allows changing language without restarting the process.
@MainActor
final class LanguageManager: ObservableObject {
    static let shared = LanguageManager(settings: .shared)

    @Published private(set) var language: AppLanguage
    @Published var selection: LanguageSelection {
        didSet {
            settings.languageSelection = selection
            refreshSystemLanguage()
        }
    }

    private let settings: AppSettings
    private let preferredLanguages: () -> [String]
    private var localeObserver: AnyCancellable?

    init(settings: AppSettings, preferredLanguages: @escaping () -> [String] = { Locale.preferredLanguages },
         observeSystemChanges: Bool = true) {
        self.settings = settings
        self.preferredLanguages = preferredLanguages
        let initialSelection = settings.languageSelection
        selection = initialSelection
        language = AppLanguage.resolve(initialSelection, preferredLanguages: preferredLanguages())
        if observeSystemChanges {
            localeObserver = NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.refreshSystemLanguage() }
        }
    }

    var locale: Locale { language.locale }

    func refreshSystemLanguage() {
        let resolved = AppLanguage.resolve(selection, preferredLanguages: preferredLanguages())
        if language != resolved { language = resolved }
    }
}

@MainActor
enum L10n {
    static var locale: Locale { LanguageManager.shared.locale }

    static func tr(_ english: String) -> String {
        localized(english, language: LanguageManager.shared.language)
    }

    static func format(_ english: String, _ arguments: CVarArg...) -> String {
        String(format: tr(english), locale: locale, arguments: arguments)
    }

    static func localized(_ english: String, language: AppLanguage, bundle: Bundle = .main) -> String {
        guard let path = bundle.path(forResource: language.rawValue, ofType: "lproj"),
              let languageBundle = Bundle(path: path) else { return english }
        return languageBundle.localizedString(forKey: english, value: english, table: "Localizable")
    }

    static func error(_ error: Error) -> String {
        if let login = error as? LoginItemControlError {
            switch login {
            case .approvalRequired: return tr("Approve OpenDente in System Settings > General > Login Items.")
            case .enableFailed: return tr("Launch at Login could not be enabled.")
            case .changeFailed(let detail): return format("Could not change Launch at Login: %@", detail)
            }
        }
        if let monthly = error as? MonthlyFullChargeError {
            switch monthly {
            case .unavailable: return tr("Native temporary full charging is unavailable.")
            case .invalidNextDate: return tr("Choose a valid next full-charge date.")
            case .policyChangedExternally: return tr("Monthly charging was cancelled because the charging policy changed.")
            case .restoreFailed(let detail):
                return format("The previous charging policy could not be restored: %@", errorMessage(detail))
            case .interrupted: return tr("Monthly charging was interrupted; the previous policy has been restored.")
            }
        }
        guard let native = error as? NativeChargeLimitError else { return errorMessage(error.localizedDescription) }
        switch native {
        case .unavailable:
            return tr("The native macOS charge limit is unavailable.")
        case .invalidState(let detail):
            return format("The native charge limit returned invalid data: %@.", errorMessage(detail))
        case .unsupportedLimit(let limit):
            return format("macOS does not support a native charge limit of %d%%.", limit)
        case .verificationFailed(let requested, let actual, let enabled):
            return format("macOS did not confirm the requested %d%% limit (effective limit: %d%%, %@).", requested, actual,
                          tr(enabled ? "Enabled" : "Disabled"))
        case .optimizedUnavailable:
            return tr("Native optimized battery charging is unavailable.")
        case .optimizedVerificationFailed(let requested, let actual):
            return format("macOS did not confirm optimized battery charging (requested: %@, actual: %@).",
                          tr(requested ? "Enabled" : "Disabled"), tr(actual ? "Enabled" : "Disabled"))
        case .temporaryUnavailable:
            return tr("Native temporary full charging is unavailable.")
        case .temporaryVerificationFailed(let detail):
            return format("macOS did not confirm temporary full charging: %@.", errorMessage(detail))
        }
    }

    /// Translates our own structured messages while preserving framework method names
    /// and opaque error details supplied by macOS.
    private static func errorMessage(_ english: String) -> String {
        let translated = tr(english)
        if translated != english { return translated }
        if english.hasPrefix("PowerUI's ") {
            for suffix in [" method is unavailable or has changed.", " argument types have changed."] {
                if english.hasSuffix(suffix) {
                    let method = String(english.dropFirst("PowerUI's ".count).dropLast(suffix.count))
                    return format("PowerUI's %@" + suffix, method)
                }
            }
        }
        if english.hasPrefix("PowerUI raised "),
           let separator = english.range(of: ": ", range: english.index(english.startIndex, offsetBy: "PowerUI raised ".count)..<english.endIndex) {
            let name = String(english[english.index(english.startIndex, offsetBy: "PowerUI raised ".count)..<separator.lowerBound])
            return format("PowerUI raised %@: %@", name, tr(String(english[separator.upperBound...])))
        }
        for suffix in [" is not an integer", " is outside its valid range"] {
            if english.hasSuffix(suffix) { return format("%@" + suffix, tr(String(english.dropLast(suffix.count)))) }
        }
        return translated
    }

    static func number(_ value: Double, fractionDigits: Int = 1) -> String {
        value.formatted(.number.locale(locale)
            .precision(.fractionLength(fractionDigits)))
    }

    static func date(_ date: Date, includeTime: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = includeTime ? .short : .none
        return formatter.string(from: date)
    }

    static func temperature(_ celsius: Double, fractionDigits: Int = 1) -> String {
        number(TemperatureDisplay.toDisplay(celsius), fractionDigits: fractionDigits) + TemperatureDisplay.unitSuffix
    }

    static func statusBarText(_ state: BatteryState, settings: AppSettings) -> String {
        var values: [String] = []
        if settings.statusBarShowPercentage {
            values.append(state.hasValidBatteryReading
                ? "\(state.effectivePercentage(useHardware: settings.useHardwareBatteryPercentage))%" : "—")
        }
        if settings.statusBarShowTemperature, let value = state.temperature {
            values.append(temperature(value, fractionDigits: 0))
        }
        if settings.statusBarShowPower, let value = state.systemPower, value > 0 {
            values.append(format("%.0fW", value))
        }
        return values.joined(separator: " ")
    }
}
