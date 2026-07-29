import FileConvertCore
import FileConvertProviders
import Foundation
import Testing

@Test
func officeValidatorRejectsMalformedAndMislabeledOutputs() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fakePDF = directory.appending(path: "output.pdf")
    try Data("not a PDF".utf8).write(to: fakePDF)
    #expect(throws: FileConvertError.self) { try OfficeArtifactValidator().validate(url: fakePDF, targetExtension: "pdf") }
    let invalidCSV = directory.appending(path: "output.csv")
    try Data([0, 1]).write(to: invalidCSV)
    #expect(throws: FileConvertError.self) { try OfficeArtifactValidator().validate(url: invalidCSV, targetExtension: "csv") }
}

@Test
func installedLibreOfficeIsNeverAdvertisedWithoutSuccessfulCertification() async {
    let provider = LibreOfficeProvider()
    let health = await provider.health()
    if case .unavailable = health {
        #expect(await provider.capabilities().isEmpty)
    }
}


@Test
func fakeLibreOfficeBundleFailsClosed() async {
    let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Fixtures/Office/fake-libreoffice/LibreOffice.app", directoryHint: .isDirectory)
    let verifier = LibreOfficeVerifier(signaturePolicy: .skipForTesting, candidateApplications: [fixture])
    await #expect(throws: FileConvertError.self) { _ = try await verifier.verify() }
}

@Test
func untestedVersionsAreRejected() {
    #expect(!LibreOfficeVerifier.isTested(version: "6.4.7"))
    #expect(LibreOfficeVerifier.isTested(version: "7.6.0"))
    #expect(!LibreOfficeVerifier.isTested(version: "26.0"))
}
