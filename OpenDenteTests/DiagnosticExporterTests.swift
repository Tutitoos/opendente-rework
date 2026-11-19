import Foundation
import Testing
@testable import OpenDente

struct DiagnosticExporterTests {
    @MainActor @Test func collectsOffMainAndPropagatesWriteFailures() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let exporter = DiagnosticExporter()
        let written = try await exporter.writeReport("Snapshot\n", to: url) { report in
            #expect(!Thread.isMainThread)
            report += "Log entry"
        }
        #expect(written && !exporter.isExporting)
        #expect(try String(contentsOf: url, encoding: .utf8) == "Snapshot\nLog entry")
        await #expect(throws: (any Error).self) {
            _ = try await exporter.writeReport("", to: url.appendingPathComponent("missing")) { _ in }
        }
        #expect(!exporter.isExporting)
    }

    @MainActor @Test func secondExportIsIgnoredWhileWriting() async throws {
        let exporter = DiagnosticExporter()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let finish = DispatchSemaphore(value: 0)
        let started = AsyncStream<Void>.makeStream()
        let first = Task {
            try await exporter.writeReport("first", to: url) { _ in
                started.continuation.yield(())
                _ = finish.wait(timeout: .now() + 5)
            }
        }
        var signals = started.stream.makeAsyncIterator()
        _ = await signals.next()
        #expect(exporter.isExporting)
        let duplicate = try await exporter.writeReport("second", to: url) { _ in }
        finish.signal()
        #expect(!duplicate)
        #expect(try await first.value)
        #expect(!exporter.isExporting)
        #expect(try String(contentsOf: url, encoding: .utf8) == "first")
    }
}
