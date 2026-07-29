import FileConvertCore
import Foundation
import Testing

@Test
func strictPolicyDecoderRejectsUnknownFieldsAndUnsupportedVersions() throws {
    let unknown = Data(#"{"audio":{"version":1,"bitrate":128000,"unexpected":true}}"#.utf8)
    #expect(throws: FileConvertError.self) {
        _ = try BoundaryGuards.decodePolicy(unknown)
    }
    let unsupported = Data(#"{"document":{"version":2,"acceptsFidelityLoss":false,"imageQuality":0.92}}"#.utf8)
    #expect(throws: FileConvertError.self) {
        _ = try BoundaryGuards.decodePolicy(unsupported)
    }
}

@Test
func canonicalPathGuardRejectsTraversalAndSymlinkTargets() throws {
    let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let root = base.appending(path: "root", directoryHint: .isDirectory)
    let outside = base.appending(path: "outside.txt")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("outside".utf8).write(to: outside)
    defer { try? FileManager.default.removeItem(at: base) }

    #expect(throws: FileConvertError.self) {
        _ = try BoundaryGuards.canonicalRegularFile(root: root, relativePath: "../outside.txt")
    }
    let link = root.appending(path: "link.txt")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    #expect(throws: FileConvertError.self) {
        _ = try BoundaryGuards.canonicalRegularFile(root: root, relativePath: "link.txt")
    }
}

@Test
func filesystemProbeUsesOnlyPrivateSiblingsAndPreservesDirectoryContents() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let userFile = directory.appending(path: "user-visible.txt")
    try Data("original".utf8).write(to: userFile)

    try FileSystemContractProbe().verify(directory: directory)
    #expect(try Data(contentsOf: userFile) == Data("original".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["user-visible.txt"])
}
