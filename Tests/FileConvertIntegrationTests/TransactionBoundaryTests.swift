import FileConvertCore
import Foundation
import Testing

private struct RejectingFilesystemProbe: FileSystemContractProbing {
    func verify(directory: URL) throws { throw FileConvertError.validationFailed("filesystem contract unavailable") }
}

private actor LaunchRecorder {
    private var didLaunch = false
    func record() { didLaunch = true }
    func value() -> Bool { didLaunch }
}

private func boundaryRequest(root: URL, rootID: UUID, id: UUID = UUID()) -> TransactionRequest {
    TransactionRequest(
        id: id,
        rootID: rootID,
        rootURL: root,
        oldRelativePath: "original.txt",
        newRelativePath: "renamed.html",
        sourceFormat: .document(.text),
        targetFormat: .document(.html),
        targetExtension: "html",
        providerID: ProviderID(rawValue: "mutation-test-provider"),
        providerVersion: "1",
        policy: .document(acceptsFidelityLoss: true),
        conversionBehavior: .replaceWithBackup
    )
}

@Test
func zeroExitStyleCorruptOutputCannotReachCommit() async throws {
    let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let root = base.appending(path: "root", directoryHint: .isDirectory)
    let storage = base.appending(path: "storage", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let target = root.appending(path: "renamed.html")
    let source = Data("original bytes".utf8)
    try source.write(to: target)
    let journal = try JournalStore(url: base.appending(path: "journal.sqlite"))
    let coordinator = try TransactionCoordinator(journal: journal, storageRoot: storage)
    let request = boundaryRequest(root: root, rootID: UUID())

    await #expect(throws: FileConvertError.self) {
        try await coordinator.execute(request, produce: { _, outputDirectory in
            let corrupt = outputDirectory.appending(path: "output.html")
            try Data("truncated".utf8).write(to: corrupt)
            return ProducedArtifact(url: corrupt, providerID: ProviderID(rawValue: "mutation-test-provider"))
        }, validate: { _, _ in
            throw FileConvertError.validationFailed("independent validator rejected corrupt output")
        })
    }
    let original = root.appending(path: request.oldRelativePath)
    #expect(try Data(contentsOf: original) == source)
    #expect(!FileManager.default.fileExists(atPath: target.path))
    #expect(try await journal.job(id: request.id)?.state == .failed)
}

@Test
func providerOutputOutsidePrivateJobDirectoryCannotReachValidationOrCommit() async throws {
    let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let root = base.appending(path: "root", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let target = root.appending(path: "renamed.html")
    let source = Data("original bytes".utf8)
    try source.write(to: target)
    let escapedOutput = base.appending(path: "escaped.html")
    try Data("untrusted output".utf8).write(to: escapedOutput)
    let journal = try JournalStore(url: base.appending(path: "journal.sqlite"))
    let coordinator = try TransactionCoordinator(journal: journal, storageRoot: base.appending(path: "storage"))
    let request = boundaryRequest(root: root, rootID: UUID())

    await #expect(throws: FileConvertError.self) {
        try await coordinator.execute(request, produce: { _, _ in
            ProducedArtifact(url: escapedOutput, providerID: ProviderID(rawValue: "mutation-test-provider"))
        }, validate: { _, _ in fatalError("validator must not run") })
    }
    let original = root.appending(path: request.oldRelativePath)
    #expect(try Data(contentsOf: original) == source)
    #expect(!FileManager.default.fileExists(atPath: target.path))
    #expect(try await journal.job(id: request.id)?.state == .failed)
}

@Test
func failedFilesystemContractPreventsProviderLaunchAndLeavesSourceUntouched() async throws {
    let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let root = base.appending(path: "root", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let target = root.appending(path: "renamed.html")
    let source = Data("original bytes".utf8)
    try source.write(to: target)
    let journal = try JournalStore(url: base.appending(path: "journal.sqlite"))
    let coordinator = try TransactionCoordinator(journal: journal, storageRoot: base.appending(path: "storage"), filesystemProbe: RejectingFilesystemProbe())
    let request = boundaryRequest(root: root, rootID: UUID())
    let recorder = LaunchRecorder()

    await #expect(throws: FileConvertError.self) {
        try await coordinator.execute(request, produce: { _, _ in
            await recorder.record()
            throw FileConvertError.validationFailed("provider must not run")
        }, validate: { _, _ in fatalError("validator must not run") })
    }
    #expect(!(await recorder.value()))
    #expect(try Data(contentsOf: target) == source)
    #expect(try await journal.job(id: request.id) == nil)
}
