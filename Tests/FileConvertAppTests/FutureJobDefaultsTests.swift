@testable import FileConvertApp
import FileConvertCore
import Foundation
import Testing

private func customizedDefaults(behavior: ConversionBehavior = .keepOriginal) -> FutureJobDefaults {
    var defaults = FutureJobDefaults()
    defaults.image.quality = 0.42
    defaults.image.alphaBackgroundARGB = 0xFF112233
    defaults.audio.bitrate = 192_000
    defaults.audio.sampleRate = 48_000
    defaults.audio.trackIndex = 2
    defaults.video.quality = 17
    defaults.video.audioTrack = 1
    defaults.video.subtitleTrack = 3
    defaults.document.acceptsFidelityLoss = true
    defaults.document.pageIndex = 4
    defaults.document.imageQuality = 0.73
    defaults.spreadsheet.sheetIndex = 5
    defaults.spreadsheet.delimiter = "\t"
    defaults.spreadsheet.formulaValuesOnly = true
    defaults.conversionBehavior = behavior
    return defaults
}

private func encodedObject(_ defaults: FutureJobDefaults) throws -> [String: Any] {
    let data = try JSONEncoder().encode(defaults)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func decode(_ object: [String: Any]) throws -> FutureJobDefaults {
    let data = try JSONSerialization.data(withJSONObject: object)
    return try JSONDecoder().decode(FutureJobDefaults.self, from: data)
}

private func expectPolicies(_ decoded: FutureJobDefaults, match expected: FutureJobDefaults) {
    #expect(decoded.image == expected.image)
    #expect(decoded.audio == expected.audio)
    #expect(decoded.video == expected.video)
    #expect(decoded.document == expected.document)
    #expect(decoded.spreadsheet == expected.spreadsheet)
}

@Test
func futureJobDefaultsUseKeepOriginalByDefault() {
    #expect(FutureJobDefaults().conversionBehavior == .keepOriginal)
}

@Test(arguments: [ConversionBehavior.keepOriginal, .replaceWithBackup])
func futureJobDefaultsRoundTripEachConversionBehavior(_ behavior: ConversionBehavior) throws {
    let defaults = customizedDefaults(behavior: behavior)
    let decoded = try JSONDecoder().decode(FutureJobDefaults.self, from: JSONEncoder().encode(defaults))

    #expect(decoded == defaults)
}

@Test
func malformedConversionBehaviorFallsBackWithoutDiscardingPolicies() throws {
    let expected = customizedDefaults(behavior: .replaceWithBackup)
    let malformedValues: [Any?] = [nil, "futureBehavior", 42]

    for malformedValue in malformedValues {
        var object = try encodedObject(expected)
        if let malformedValue {
            object["conversionBehavior"] = malformedValue
        } else {
            object.removeValue(forKey: "conversionBehavior")
        }

        let decoded = try decode(object)
        #expect(decoded.conversionBehavior == .keepOriginal)
        expectPolicies(decoded, match: expected)
    }
}

@Test
func futureJobDefaultsPersistAcrossRelaunchSemantics() throws {
    let suiteName = "FutureJobDefaultsTests.\(UUID().uuidString)"
    let key = "futureJobDefaults"
    let storedDefaults = customizedDefaults(behavior: .replaceWithBackup)
    let firstLaunch = try #require(UserDefaults(suiteName: suiteName))
    defer { firstLaunch.removePersistentDomain(forName: suiteName) }

    firstLaunch.set(try JSONEncoder().encode(storedDefaults), forKey: key)
    let relaunched = try #require(UserDefaults(suiteName: suiteName))
    let data = try #require(relaunched.data(forKey: key))
    let restored = try JSONDecoder().decode(FutureJobDefaults.self, from: data)

    #expect(restored == storedDefaults)
}

@Test
func inFlightRequestSnapshotIgnoresLaterSettingsChanges() async {
    var futureDefaults = customizedDefaults(behavior: .keepOriginal)
    let captured = FutureJobDefaultsSnapshot(futureDefaults)
    let inFlightRequest = Task { @Sendable in
        await Task.yield()
        return captured
    }

    futureDefaults.image.quality = 0.99
    futureDefaults.conversionBehavior = .replaceWithBackup
    let requestDefaults = await inFlightRequest.value

    #expect(requestDefaults.image.quality == 0.42)
    #expect(requestDefaults.conversionBehavior == .keepOriginal)
    #expect(futureDefaults.conversionBehavior == .replaceWithBackup)
}
