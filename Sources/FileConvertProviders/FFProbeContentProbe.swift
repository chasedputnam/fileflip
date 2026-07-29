import FileConvertCore
import Foundation

public struct FFProbeContentProbe: MediaContentProbing, Sendable {
    private struct Payload: Decodable {
        struct Stream: Decodable { let codec_name: String?; let codec_type: String? }
        struct Format: Decodable {
            struct Tags: Decodable { let major_brand: String? }
            let format_name: String?
            let tags: Tags?
        }
        let streams: [Stream]
        let format: Format?
    }

    public let executableURL: URL
    public let timeout: Duration

    public init(executableURL: URL, timeout: Duration = .seconds(5)) {
        self.executableURL = executableURL
        self.timeout = timeout
    }

    public func probe(_ url: URL, maximumOutputBytes: Int) async throws -> DetectedFormat? {
        guard maximumOutputBytes > 0 else { throw FileConvertError.validationFailed("ffprobe output limit is zero") }
        let directory = FileManager.default.temporaryDirectory.appending(path: "fileconvert-probe-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appending(path: "probe.json")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw FileConvertError.validationFailed("cannot create ffprobe output") }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["-v", "error", "-show_entries", "format=format_name:format_tags=major_brand:stream=codec_type,codec_name", "-of", "json", "--", url.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while process.isRunning && clock.now < deadline {
            let size = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.intValue ?? 0
            if size > maximumOutputBytes {
                process.terminate()
                process.waitUntilExit()
                throw FileConvertError.validationFailed("ffprobe output exceeded limit")
            }
            try await clock.sleep(for: .milliseconds(20))
        }
        guard !process.isRunning else {
            process.terminate()
            process.waitUntilExit()
            throw FileConvertError.timedOut
        }
        guard process.terminationStatus == 0 else { return nil }
        try output.synchronize()
        let data = try Data(contentsOf: outputURL, options: .mappedIfSafe)
        guard data.count <= maximumOutputBytes else { throw FileConvertError.validationFailed("ffprobe output exceeded limit") }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return Self.detect(payload)
    }

    private static func detect(_ payload: Payload) -> DetectedFormat? {
        let streams = payload.streams
        return InstalledMediaContract.detectedFormat(
            formatNames: Set((payload.format?.format_name ?? "").split(separator: ",").map(String.init)),
            codecs: Set(streams.compactMap(\.codec_name)),
            majorBrand: payload.format?.tags?.major_brand,
            hasAudio: streams.contains { $0.codec_type == "audio" },
            hasVideo: streams.contains { $0.codec_type == "video" }
        )
    }
}
