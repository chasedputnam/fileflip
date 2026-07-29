@testable import FileConvertProviders
import Foundation
import Testing

private struct ConfigurationTokenFixture: Decodable {
    struct Case: Decodable {
        let name: String
        let input: String
        let arguments: [String]?
        let error: Bool?
    }

    let schemaVersion: Int
    let cases: [Case]
}

private final class ConfigurationFixtureBundleMarker {}

private func configurationFixtureURL() -> URL? {
#if SWIFT_PACKAGE
    Bundle.module.url(
        forResource: "configuration-token-cases",
        withExtension: "json",
        subdirectory: "Fixtures"
    )
#else
    Bundle(for: ConfigurationFixtureBundleMarker.self).url(
        forResource: "configuration-token-cases",
        withExtension: "json"
    )
#endif
}

@Test
func mediaConfigurationCanonicalizationMatchesSharedFixtures() throws {
    let url = try #require(configurationFixtureURL())
    let fixture = try JSONDecoder().decode(ConfigurationTokenFixture.self, from: Data(contentsOf: url))
    #expect(fixture.schemaVersion == 1)

    for testCase in fixture.cases {
        if testCase.error == true {
            #expect(throws: MediaConfigurationError.self, "case: \(testCase.name)") {
                _ = try MediaConfiguration.canonicalArguments(from: testCase.input)
            }
        } else {
            let expected = try #require(testCase.arguments)
            #expect(try MediaConfiguration.canonicalArguments(from: testCase.input) == expected, "case: \(testCase.name)")
        }
    }
}

@Test
func semanticallyDifferentConfigurationHashesDiffer() throws {
    let first = try MediaConfiguration.canonicalArguments(from: "configuration: --enable-decoder=aac,flac\n")
    let second = try MediaConfiguration.canonicalArguments(from: "configuration: --enable-decoder=aac,opus\n")

    #expect(MediaConfiguration.sha256(first) != MediaConfiguration.sha256(second))
}

@Test
func mediaInventoryParserSplitsAliasesAndIgnoresLegend() {
    let output = """
     D..... = Decoding supported
     D  matroska,webm Matroska / WebM
     D  mov,mp4,m4a,3gp,3g2,mj2 QuickTime / MOV
    """

    #expect(MediaInventoryParser.parse(output) == [
        "matroska", "webm", "mov", "mp4", "m4a", "3gp", "3g2", "mj2",
    ])
}

@Test
func checkedInMediaToolsPassStrictVerification() async throws {
    let repositoryRoot = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let directory = repositoryRoot.appending(path: "Sources/FileConvertApp/Resources/MediaTools", directoryHint: .isDirectory)
    let manifest = try JSONDecoder().decode(
        MediaToolManifest.self,
        from: Data(contentsOf: directory.appending(path: "manifest.json"))
    )
    let expectedInventory = try #require(manifest.inventory)
    let ffmpeg = directory.appending(path: "ffmpeg")
    let runner = BoundedProcessRunner()
    for (option, expected) in [
        ("-encoders", expectedInventory.encoders),
        ("-muxers", expectedInventory.muxers),
        ("-demuxers", expectedInventory.demuxers),
    ] {
        let result = try await runner.run(
            executableURL: ffmpeg,
            arguments: ["-hide_banner", option],
            environment: ["PATH": "/usr/bin:/bin", "HOME": "/var/empty", "LANG": "C"],
            timeout: .seconds(10)
        )
        #expect(result.terminationStatus == 0)
        let output = try #require(String(data: result.stdout, encoding: .utf8))
        #expect(MediaInventoryParser.parse(output) == expected, "inventory option: \(option)")
    }

    let tools = try await MediaToolVerifier(directory: directory).verify()

    #expect(tools.version == "8.1.2")
    #expect(tools.ffmpegURL.lastPathComponent == "ffmpeg")
    #expect(tools.ffprobeURL.lastPathComponent == "ffprobe")
}
