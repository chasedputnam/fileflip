import Foundation
import FileConvertEvidence
import FileConvertProviders
import Testing

private let certifiedManifestURL = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appending(path: "Fixtures/Media/manifest.json")

@Test
func certifiedMediaManifestLoadsEveryReviewedFixture() throws {
    let manifest = try CertifiedMediaManifest.load(from: certifiedManifestURL)
    #expect(manifest.fixtures.count == 13)
    #expect(Set(manifest.fixtures.map(\.family)) == ["audio", "video"])
    #expect(manifest.fixtures.allSatisfy { fixture in
        FileManager.default.isReadableFile(atPath: manifest.sourceURL(for: fixture, manifestURL: certifiedManifestURL).path)
    })
    for fixture in manifest.fixtures {
        #expect(try fixture.detectedFormat == InstalledMediaContract.format(forExtension: fixture.canonicalExtension))
    }
}

@Test
func certifiedMediaManifestRejectsUnknownNestedFields() throws {
    let data = try Data(contentsOf: certifiedManifestURL)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var fixtures = try #require(object["fixtures"] as? [[String: Any]])
    var first = fixtures[0]
    var facts = try #require(first["facts"] as? [String: Any])
    var streams = try #require(facts["streams"] as? [[String: Any]])
    streams[0]["unknown"] = true
    facts["streams"] = streams
    first["facts"] = facts
    fixtures[0] = first
    object["fixtures"] = fixtures
    let malformed = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: Error.self) {
        try JSONDecoder().decode(CertifiedMediaManifest.self, from: malformed)
    }
}
