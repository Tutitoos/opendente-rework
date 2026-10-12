import Foundation
import Darwin

/// Persistent recovery marker. Missing means no previous mutation; unreadable/corrupt means
/// recovery is required. A marker must reach disk before a potentially unsafe hardware write.
enum HelperState {
    enum ChargingState: String, Sendable {
        case normal
        case inhibited
    }

    static let store = FileHelperStateStore(directory: HelperConstants.stateDirectory)

    static func wasChargingInhibited() -> Bool {
        do { return try store.read() == .inhibited }
        catch { return true }
    }
}

struct FileHelperStateStore: HelperStateStore {
    let directory: String
    private var filename: String { "helper-state" }

    enum StateError: LocalizedError {
        case system(String, Int32)
        case insecureDirectory
        case corruptState

        var errorDescription: String? {
            switch self {
            case .system(let operation, let code): return "State \(operation) failed: \(String(cString: strerror(code)))"
            case .insecureDirectory: return "Recovery directory is not a real directory owned by the helper"
            case .corruptState: return "Recovery state is corrupt"
            }
        }
    }

    private func openDirectory(create: Bool) throws -> Int32 {
        if create {
            do {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            } catch {
                throw error
            }
        }
        var attributes = stat()
        guard lstat(directory, &attributes) == 0 else { throw StateError.system("directory stat", errno) }
        guard attributes.st_mode & S_IFMT == S_IFDIR, attributes.st_uid == geteuid() else {
            throw StateError.insecureDirectory
        }
        let fd = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw StateError.system("directory open", errno) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_mode & S_IFMT == S_IFDIR,
              opened.st_uid == geteuid() else {
            close(fd)
            throw StateError.insecureDirectory
        }
        guard fchmod(fd, 0o700) == 0 else {
            let code = errno
            close(fd)
            throw StateError.system("directory permissions", code)
        }
        return fd
    }

    func read() throws -> HelperState.ChargingState? {
        let directoryFD: Int32
        do { directoryFD = try openDirectory(create: false) }
        catch StateError.system(_, let code) where code == ENOENT { return nil }
        defer { close(directoryFD) }
        let fd = openat(directoryFD, filename, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw StateError.system("read open", errno)
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw StateError.system("file stat", errno) }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_size <= 32 else {
            throw StateError.corruptState
        }
        var bytes = [UInt8](repeating: 0, count: 33)
        let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard count >= 0 else { throw StateError.system("read", errno) }
        guard let text = String(bytes: bytes.prefix(count), encoding: .utf8),
              let state = HelperState.ChargingState(rawValue: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw StateError.corruptState
        }
        return state
    }

    func write(_ state: HelperState.ChargingState) throws {
        let directoryFD = try openDirectory(create: true)
        defer { close(directoryFD) }
        let temporary = ".helper-state-\(UUID().uuidString)"
        let fd = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StateError.system("write open", errno) }
        defer {
            close(fd)
            unlinkat(directoryFD, temporary, 0)
        }
        let bytes = Array(state.rawValue.utf8)
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw StateError.system("write", errno) }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw StateError.system("file sync", errno) }
        guard renameat(directoryFD, temporary, directoryFD, filename) == 0 else {
            throw StateError.system("atomic rename", errno)
        }
        guard fsync(directoryFD) == 0 else { throw StateError.system("directory sync", errno) }
    }
}
