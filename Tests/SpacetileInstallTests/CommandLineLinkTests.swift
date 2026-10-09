import AppKit
import Foundation
import SpacetileInstall
import Testing

struct CommandLineLinkTests {
    private func withLink(_ body: (CommandLineLink, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Exercise both shell and AppleScript quoting, including text that must never execute.
        let app = root.appendingPathComponent("Spacetile's \"test\" \\ $(touch INJECTED) `touch INJECTED`\n.app")
        try Data("executable".utf8).write(to: app)
        let link = CommandLineLink(executable: app.path, destination: root.appendingPathComponent("bin/spacetile").path)
        try body(link, root)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("INJECTED").path))
    }

    @Test func installsAndCanRepeat() throws {
        try withLink { link, _ in
            #expect(link.status == .missing)
            try link.install()
            #expect(link.status == .installed)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.destination) == link.executable)
            try link.install()
            #expect(link.status == .installed)
        }
    }

    @Test(arguments: ["file", "directory", "brokenLink", "otherLink"])
    func leavesExistingCommandsUntouched(kind: String) throws {
        try withLink { link, root in
            let files = FileManager.default
            try files.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
            switch kind {
            case "file": try Data("existing command".utf8).write(to: URL(fileURLWithPath: link.destination))
            case "directory": try files.createDirectory(atPath: link.destination, withIntermediateDirectories: false)
            case "otherLink": try files.createSymbolicLink(atPath: link.destination, withDestinationPath: root.path)
            default: try files.createSymbolicLink(atPath: link.destination, withDestinationPath: "/missing/spacetile")
            }
            #expect(link.status == .conflict)
            #expect(throws: (any Error).self) { try link.install() }
            #expect(try runShell(link.installShellScript, directory: root) != 0)
            #expect(link.status == .conflict)
            if kind == "file" {
                #expect(try String(contentsOfFile: link.destination, encoding: .utf8) == "existing command")
            } else if kind == "directory" {
                #expect(try files.contentsOfDirectory(atPath: link.destination).isEmpty)
            } else {
                #expect(try files.destinationOfSymbolicLink(atPath: link.destination) == (kind == "otherLink" ? root.path : "/missing/spacetile"))
            }
        }
    }

    @Test func privilegedShellPayloadQuotesPathsAndIsIdempotent() throws {
        try withLink { link, root in
            let first = try runShell(link.installShellScript, directory: root)
            #expect(first == 0)
            #expect(link.status == .installed)
            let repeated = try runShell(link.installShellScript, directory: root)
            #expect(repeated == 0)
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: link.destination)
            #expect(target == link.executable)
        }
    }

    @Test @MainActor func appleScriptPayloadPreservesPaths() throws {
        try withLink { link, _ in
            // Execute the same payload in a temporary directory, without prompting for elevation.
            let source = link.installAppleScript.replacingOccurrences(of: " with administrator privileges", with: "")
            let script = try #require(NSAppleScript(source: source))
            var error: NSDictionary?
            script.executeAndReturnError(&error)
            #expect(error == nil)
            #expect(link.status == .installed)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.destination) == link.executable)
        }
    }

    private func runShell(_ script: String, directory: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.currentDirectoryURL = directory
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
