import Foundation

extension AppSettings {
    /// The old app preference is retained during native-policy adoption. It is
    /// never automatically written back to macOS at startup or reconnect.
    var legacySMCChargeLimit: Int? {
        get { defaults.object(forKey: "legacySMCChargeLimit") as? Int }
        set { defaults.set(newValue, forKey: "legacySMCChargeLimit") }
    }
}
