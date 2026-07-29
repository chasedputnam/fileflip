import FileConvertCore
import Foundation
import Testing

@Test
func secondInstanceIsExcluded() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let lockURL = directory.appending(path: "instance.lock")

    let first = try SingleInstanceLock(url: lockURL)
    #expect(throws: FileConvertError.anotherInstanceIsRunning) {
        _ = try SingleInstanceLock(url: lockURL)
    }
    _ = first
}

@Test
func applicationStorageIsOwnerOnly() throws {
    let identifier = "app.fileconvert.tests.\(UUID().uuidString)"
    let url = try ApplicationStorage.prepare(bundleIdentifier: identifier)
    defer { try? FileManager.default.removeItem(at: url) }
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
}
