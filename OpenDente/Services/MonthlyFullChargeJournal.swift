import Foundation
import Darwin

@MainActor
protocol MonthlyFullChargeJournal {
    func read() throws -> MonthlyFullChargeCycle?
    func write(_ cycle: MonthlyFullChargeCycle?) throws
}

enum MonthlyChargeJournalError: LocalizedError {
    case invalidRecord
    case system(operation: String, code: Int32)
    case unavailable(operation: String, detail: String)

    var errorDescription: String? {
        switch self {
        case .invalidRecord: "The monthly charge recovery record is invalid. Temporary charging is paused."
        case .system, .unavailable: "The monthly charge recovery record could not be read or saved."
        }
    }
}

/// The cycle must reach disk before a native override can start. Preferences
/// remain a UI mirror; they are not used as the production recovery journal.
@MainActor
struct FileMonthlyFullChargeJournal: MonthlyFullChargeJournal {
    let directory: URL
    private let filename = "monthly-charge-cycle.json"

    static var applicationSupport: Self {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return Self(directory: support.appendingPathComponent("OpenDente/Charging", isDirectory: true))
    }

    private func systemError(_ operation: String, _ code: Int32 = errno) -> MonthlyChargeJournalError {
        .system(operation: operation, code: code)
    }

    private func openDirectory(create: Bool) throws -> Int32 {
        if create {
            var missingDirectories: [URL] = []
            var ancestor = directory
            while !FileManager.default.fileExists(atPath: ancestor.path) {
                missingDirectories.append(ancestor)
                let parent = ancestor.deletingLastPathComponent()
                guard parent != ancestor else { break }
                ancestor = parent
            }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            } catch { throw MonthlyChargeJournalError.unavailable(operation: "createDirectory", detail: error.localizedDescription) }
            // Sync each new directory's parent entry as well as the journal's
            // own contents, including the first creation of OpenDente/Charging.
            for child in missingDirectories.reversed() {
                let parentFD = open(child.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                guard parentFD >= 0 else { throw systemError("openParentDirectory") }
                let synced = fsync(parentFD)
                let syncError = errno
                close(parentFD)
                guard synced == 0 else { throw systemError("syncParentDirectory", syncError) }
            }
        }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw systemError("openDirectory") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid() else {
            close(fd)
            throw MonthlyChargeJournalError.invalidRecord
        }
        guard fchmod(fd, 0o700) == 0 else {
            let error = systemError("chmodDirectory")
            close(fd)
            throw error
        }
        return fd
    }

    func read() throws -> MonthlyFullChargeCycle? {
        let directoryFD: Int32
        do { directoryFD = try openDirectory(create: false) }
        catch MonthlyChargeJournalError.system(_, ENOENT) { return nil }
        defer { close(directoryFD) }
        let fd = openat(directoryFD, filename, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw systemError("readOpen")
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_size > 0, info.st_size <= 64 * 1024 else {
            throw MonthlyChargeJournalError.invalidRecord
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw systemError("read")
            }
            if count == 0 { break }
            guard data.count + count <= 64 * 1024 else { throw MonthlyChargeJournalError.invalidRecord }
            data.append(contentsOf: buffer.prefix(count))
        }
        do {
            let cycle = try JSONDecoder().decode(MonthlyFullChargeCycle.self, from: data)
            guard Self.isValid(cycle) else { throw MonthlyChargeJournalError.invalidRecord }
            return cycle
        } catch { throw MonthlyChargeJournalError.invalidRecord }
    }

    func write(_ cycle: MonthlyFullChargeCycle?) throws {
        let directoryFD = try openDirectory(create: true)
        defer { close(directoryFD) }
        guard let cycle else {
            guard unlinkat(directoryFD, filename, 0) == 0 || errno == ENOENT else { throw systemError("remove") }
            guard fsync(directoryFD) == 0 else { throw systemError("syncDirectory") }
            return
        }
        guard Self.isValid(cycle) else { throw MonthlyChargeJournalError.invalidRecord }
        let data = try JSONEncoder().encode(cycle)
        let temporary = ".monthly-charge-\(UUID().uuidString)"
        let fd = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw systemError("writeOpen") }
        defer { close(fd); unlinkat(directoryFD, temporary, 0) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw systemError("write")
                }
                guard count > 0 else { throw MonthlyChargeJournalError.unavailable(operation: "write", detail: "no progress") }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw systemError("syncFile") }
        guard renameat(directoryFD, temporary, directoryFD, filename) == 0 else { throw systemError("replace") }
        guard fsync(directoryFD) == 0 else { throw systemError("syncDirectory") }
    }

    private static func isValid(_ cycle: MonthlyFullChargeCycle) -> Bool {
        func valid(_ policy: NativeChargingPolicySnapshot) -> Bool {
            let limit = policy.chargeLimit
            return !limit.availableLimits.isEmpty && Set(limit.availableLimits).count == limit.availableLimits.count &&
                limit.availableLimits.allSatisfy({ (80...100).contains($0) }) && limit.availableLimits.contains(100) &&
                [0, 1, 3].contains(limit.nativeFeatureState) && limit.enabled == (limit.nativeFeatureState == 1) &&
                (0...100).contains(limit.limit) && (!limit.enabled || limit.availableLimits.contains(limit.limit)) &&
                (policy.optimizedChargingState.map { (0...3).contains($0) } ?? true) &&
                policy.optimizedChargingEnabled == policy.optimizedChargingState.map { $0 != 0 }
        }
        let previous = cycle.previousPolicy
        return cycle.startedAt.timeIntervalSinceReferenceDate.isFinite &&
            (cycle.reachedFullAt?.timeIntervalSinceReferenceDate.isFinite ?? true) && valid(previous) &&
            !previous.chargeLimit.isTemporaryOverride && previous.optimizedChargingState != 2 && previous.optimizedChargingState != 3 &&
            (!previous.chargeLimit.enabled || previous.chargeLimit.limit < 100) &&
            (cycle.temporaryPolicy.map(valid) ?? true)
    }
}

/// Isolated preferences are useful for deterministic tests and for migration
/// from a previously saved preference record. Malformed data is never absence.
@MainActor
struct SettingsMonthlyFullChargeJournal: MonthlyFullChargeJournal {
    let settings: AppSettings
    func read() throws -> MonthlyFullChargeCycle? {
        let cycle = settings.monthlyFullChargeCycle
        if cycle == nil, settings.defaults.object(forKey: "monthlyFullChargeCycle") != nil {
            throw MonthlyChargeJournalError.invalidRecord
        }
        return cycle
    }
    func write(_ cycle: MonthlyFullChargeCycle?) throws {
        settings.monthlyFullChargeCycle = cycle
        guard settings.monthlyFullChargeCycle == cycle else { throw MonthlyChargeJournalError.invalidRecord }
    }
}
