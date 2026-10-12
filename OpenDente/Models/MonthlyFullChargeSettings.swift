import Foundation

extension AppSettings {
    var monthlyChargeRecoveryUnknown: Bool {
        get { defaults.bool(forKey: "monthlyChargeRecoveryUnknown") }
        set { defaults.set(newValue, forKey: "monthlyChargeRecoveryUnknown") }
    }

    var monthlyCycleJournalMigrated: Bool {
        get { defaults.bool(forKey: "monthlyCycleJournalMigrated") }
        set { defaults.set(newValue, forKey: "monthlyCycleJournalMigrated") }
    }

    var monthlyFullChargeEnabled: Bool {
        get { defaults.bool(forKey: "monthlyFullChargeEnabled") }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "monthlyFullChargeEnabled") }
    }

    var monthlyFullChargeNextDate: Date? {
        get { defaults.object(forKey: "monthlyFullChargeNextDate") as? Date }
        set { defaults.set(newValue, forKey: "monthlyFullChargeNextDate") }
    }

    var monthlyLastFullChargeDate: Date? {
        get { defaults.object(forKey: "monthlyLastFullChargeDate") as? Date }
        set { defaults.set(newValue, forKey: "monthlyLastFullChargeDate") }
    }

    var monthlyPreviouslyObservedFull: Bool {
        get { defaults.bool(forKey: "monthlyPreviouslyObservedFull") }
        set { defaults.set(newValue, forKey: "monthlyPreviouslyObservedFull") }
    }

    var monthlyFullChargeCycle: MonthlyFullChargeCycle? {
        get {
            guard let data = defaults.data(forKey: "monthlyFullChargeCycle") else { return nil }
            return try? JSONDecoder().decode(MonthlyFullChargeCycle.self, from: data)
        }
        set {
            if let newValue {
                guard let data = try? JSONEncoder().encode(newValue) else { return }
                defaults.set(data, forKey: "monthlyFullChargeCycle")
            } else { defaults.removeObject(forKey: "monthlyFullChargeCycle") }
        }
    }
}
