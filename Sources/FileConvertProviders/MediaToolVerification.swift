import CryptoKit
import Darwin
import FileConvertCore
import Security
@preconcurrency import Foundation

enum MediaConfigurationError: Error, Equatable {
    case invalid(String)
}

enum MediaConfiguration {
    private enum Quote {
        case single
        case double
    }

    private static let allowedEscapes: Set<Character> = [" ", "\t", "'", "\"", "\\"]

    static func canonicalArguments(from output: String) throws -> [String] {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let configurationIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("configuration:")
        }) else {
            throw MediaConfigurationError.invalid("missing configuration")
        }

        var arguments: [String] = []
        let configurationLine = lines[configurationIndex].trimmingCharacters(in: .whitespaces)
        if let colon = configurationLine.firstIndex(of: ":") {
            let inline = String(configurationLine[configurationLine.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            if !inline.isEmpty {
                arguments.append(contentsOf: try tokenize(inline))
            }
        }

        for line in lines.dropFirst(configurationIndex + 1) {
            let continuation = line.trimmingCharacters(in: .whitespaces)
            if continuation.hasPrefix("--") {
                arguments.append(contentsOf: try tokenize(continuation))
            } else if !continuation.isEmpty {
                break
            }
        }
        try validate(arguments)
        return arguments
    }

    static func sha256(_ arguments: [String]) -> String {
        SHA256.hash(data: Data(arguments.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func validate(_ arguments: [String]) throws {
        guard !arguments.isEmpty, arguments.allSatisfy({ $0.hasPrefix("--") }) else {
            throw MediaConfigurationError.invalid("configuration contains a non-option token")
        }
        let keys = arguments.map { argument in
            argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? argument
        }
        guard Set(keys).count == keys.count else {
            throw MediaConfigurationError.invalid("configuration contains a duplicate option")
        }
    }

    private static func tokenize(_ text: String) throws -> [String] {
        let characters = Array(text)
        var tokens: [String] = []
        var token = ""
        var quote: Quote?
        var started = false
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if quote == nil, character.isWhitespace {
                if started {
                    tokens.append(token)
                    token = ""
                    started = false
                }
                index += 1
                continue
            }
            if character == "'" || character == "\"" {
                let candidate: Quote = character == "'" ? .single : .double
                if quote == nil {
                    quote = candidate
                    started = true
                } else if quote == candidate {
                    quote = nil
                } else {
                    token.append(character)
                }
                index += 1
                continue
            }
            if character == "\\", quote != .single {
                index += 1
                guard index < characters.count, allowedEscapes.contains(characters[index]) else {
                    throw MediaConfigurationError.invalid("unsupported escape")
                }
                token.append(characters[index])
                started = true
                index += 1
                continue
            }
            token.append(character)
            started = true
            index += 1
        }
        guard quote == nil else {
            throw MediaConfigurationError.invalid("unterminated quote")
        }
        if started {
            tokens.append(token)
        }
        return tokens
    }
}

enum MediaInventoryParser {
    static func parse(_ output: String) -> Set<String> {
        var observed: Set<String> = []
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2,
                  fields[0].allSatisfy({ $0 == "." || $0.isLetter }),
                  fields[1] != "=" else {
                continue
            }
            for name in fields[1].split(separator: ",") {
                guard name.count >= 2,
                      let first = name.first, first.isLetter || first.isNumber || first == "_",
                      name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-" }) else {
                    continue
                }
                observed.insert(String(name))
            }
        }
        return observed
    }
}

public struct MediaToolManifest: Codable, Hashable, Sendable {
    public struct Source: Codable, Hashable, Sendable {
        public let name: String
        public let version: String
        public let url: String
        public let sha256: String
        public let license: String
    }

    public struct License: Codable, Hashable, Sendable {
        public let name: String
        public let license: String
        public let source: String
        public let sha256: String
    }

    public struct Build: Codable, Hashable, Sendable {
        public let configuration: [String]
        public let configurationSHA256: String
        public let architectures: Set<String>
    }

    public struct Signature: Codable, Hashable, Sendable {
        public let mode: String
        public let identity: String?
        public let teamIdentifier: String?
    }

    public struct Artifact: Codable, Hashable, Sendable {
        public let name: String
        public let path: String
        public let sha256: String?
        public let architectures: Set<String>
        public let signature: Signature
    }

    public struct Inventory: Codable, Hashable, Sendable {
        public let encoders: Set<String>
        public let muxers: Set<String>
        public let demuxers: Set<String>
    }

    public let schemaVersion: Int
    public let status: String
    public let reason: String?
    public let ffmpegVersion: String?
    public let sources: [Source]?
    public let licenses: [License]?
    public let build: Build?
    public let artifacts: [Artifact]?
    public let inventory: Inventory?

    public init(schemaVersion: Int = 1, status: String, reason: String? = nil, ffmpegVersion: String? = nil, sources: [Source]? = nil, licenses: [License]? = nil, build: Build? = nil, artifacts: [Artifact]? = nil, inventory: Inventory? = nil) {
        self.schemaVersion = schemaVersion
        self.status = status
        self.reason = reason
        self.ffmpegVersion = ffmpegVersion
        self.sources = sources
        self.licenses = licenses
        self.build = build
        self.artifacts = artifacts
        self.inventory = inventory
    }
}

public struct VerifiedMediaTools: Sendable {
    public let ffmpegURL: URL
    public let ffprobeURL: URL
    public let version: String
    public let encoders: Set<String>
    public let muxers: Set<String>
    public let demuxers: Set<String>

    public init(ffmpegURL: URL, ffprobeURL: URL, version: String, encoders: Set<String>, muxers: Set<String>, demuxers: Set<String>) {
        self.ffmpegURL = ffmpegURL
        self.ffprobeURL = ffprobeURL
        self.version = version
        self.encoders = encoders
        self.muxers = muxers
        self.demuxers = demuxers
    }
}

public enum MediaToolSignaturePolicy: Sendable {
    case requireValid
    case skipForTesting
}

public struct BoundedProcessResult: Sendable {
    public let stdout: Data
    public let stderr: Data
    public let terminationStatus: Int32
}

public final class BoundedProcessRunner: @unchecked Sendable {
    public let maximumOutputBytes: Int

    public init(maximumOutputBytes: Int = 1 << 20) {
        self.maximumOutputBytes = maximumOutputBytes
    }

    public func run(executableURL: URL, arguments: [String], environment: [String: String] = [:], timeout: Duration) async throws -> BoundedProcessResult {
        guard maximumOutputBytes > 0, timeout > .zero else { throw FileConvertError.validationFailed("Invalid process limit") }
        let child = try Self.spawnIsolated(executableURL: executableURL, arguments: arguments, environment: environment)
        let pid = child.pid
        defer {
            child.stdout.closeFile()
            child.stderr.closeFile()
        }
        do {
            return try await withTaskCancellationHandler(operation: {
                try await withThrowingTaskGroup(of: BoundedProcessResult.self) { group in
                    group.addTask {
                        let data = try Self.readBounded(child.stdout, limit: self.maximumOutputBytes)
                        return BoundedProcessResult(stdout: data, stderr: Data(), terminationStatus: Int32.min)
                    }
                    group.addTask {
                        let data = try Self.readBounded(child.stderr, limit: self.maximumOutputBytes)
                        return BoundedProcessResult(stdout: Data(), stderr: data, terminationStatus: Int32.min)
                    }
                    group.addTask {
                        let clock = ContinuousClock()
                        let deadline = clock.now.advanced(by: timeout)
                        while true {
                            var waitStatus: Int32 = 0
                            let result = waitpid(pid, &waitStatus, WNOHANG)
                            if result == pid {
                                return BoundedProcessResult(
                                    stdout: Data(),
                                    stderr: Data(),
                                    terminationStatus: Self.terminationStatus(from: waitStatus)
                                )
                            }
                            guard result == 0 else {
                                throw FileConvertError.providerUnavailable("Cannot wait for provider process")
                            }
                            try Task.checkCancellation()
                            guard clock.now < deadline else { throw FileConvertError.timedOut }
                            try await clock.sleep(for: .milliseconds(20))
                        }
                    }
                    var output = Data()
                    var errors = Data()
                    var status: Int32?
                    do {
                        for try await result in group {
                            if result.terminationStatus == Int32.min {
                                if !result.stdout.isEmpty { output = result.stdout }
                                if !result.stderr.isEmpty { errors = result.stderr }
                            } else {
                                status = result.terminationStatus
                            }
                        }
                    } catch {
                        Self.terminateProcessGroup(pid)
                        group.cancelAll()
                        throw error
                    }
                    guard let status else { throw FileConvertError.providerUnavailable("Provider did not exit") }
                    return BoundedProcessResult(stdout: output, stderr: errors, terminationStatus: status)
                }
            }, onCancel: {
                Self.terminateProcessGroup(pid)
            })
        } catch is CancellationError {
            Self.terminateProcessGroup(pid)
            Self.reap(pid)
            throw FileConvertError.cancelled
        } catch {
            Self.terminateProcessGroup(pid)
            Self.reap(pid)
            throw error
        }
    }

    private struct SpawnedProcess {
        let pid: pid_t
        let stdout: FileHandle
        let stderr: FileHandle
    }

    private static func spawnIsolated(executableURL: URL, arguments: [String], environment: [String: String]) throws -> SpawnedProcess {
        var stdoutPipe: [Int32] = [0, 0]
        var stderrPipe: [Int32] = [0, 0]
        guard pipe(&stdoutPipe) == 0 else { throw FileConvertError.providerUnavailable("Cannot create provider output pipe") }
        guard pipe(&stderrPipe) == 0 else {
            close(stdoutPipe[0]); close(stdoutPipe[1])
            throw FileConvertError.providerUnavailable("Cannot create provider error pipe")
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        let nullFD = open("/dev/null", O_RDONLY)
        guard nullFD >= 0 else {
            close(stdoutPipe[0]); close(stdoutPipe[1]); close(stderrPipe[0]); close(stderrPipe[1])
            throw FileConvertError.providerUnavailable("Cannot open null input")
        }
        posix_spawn_file_actions_adddup2(&actions, nullFD, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, stdoutPipe[0])
        posix_spawn_file_actions_addclose(&actions, stderrPipe[0])
        posix_spawn_file_actions_addclose(&actions, nullFD)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        var pid: pid_t = 0
        let argv = [executableURL.path] + arguments
        let env = environment.map { "\($0.key)=\($0.value)" }
        let spawnResult = withCStringArray(argv) { argvPointer in
            withCStringArray(env) { envPointer in
                posix_spawn(&pid, executableURL.path, &actions, &attributes, argvPointer, envPointer)
            }
        }
        close(nullFD)
        close(stdoutPipe[1])
        close(stderrPipe[1])
        guard spawnResult == 0 else {
            close(stdoutPipe[0]); close(stderrPipe[0])
            throw FileConvertError.providerUnavailable("Cannot start provider process")
        }
        return SpawnedProcess(
            pid: pid,
            stdout: FileHandle(fileDescriptor: stdoutPipe[0], closeOnDealloc: true),
            stderr: FileHandle(fileDescriptor: stderrPipe[0], closeOnDealloc: true)
        )
    }

    private static func withCStringArray<Result>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
    ) -> Result {
        let strings: [UnsafeMutablePointer<CChar>?] = strings.map { value in value.withCString { strdup($0) } }
        defer { strings.forEach { free($0) } }
        var pointers = strings + [nil]
        return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }

    private static func terminationStatus(from waitStatus: Int32) -> Int32 {
        let signal = waitStatus & 0x7f
        return signal == 0 ? (waitStatus >> 8) & 0xff : 128 + signal
    }

    private static func reap(_ pid: pid_t) {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
    }

    private static func readBounded(_ handle: FileHandle, limit: Int) throws -> Data {
        var data = Data()
        while true {
            let remaining = limit - data.count
            let chunk = handle.readData(ofLength: min(64 * 1_024, remaining + 1))
            if chunk.isEmpty { return data }
            guard chunk.count <= remaining else { throw FileConvertError.validationFailed("Provider output exceeded limit") }
            data.append(chunk)
        }
    }

    private static func terminateProcessGroup(_ pid: pid_t) {
        guard pid > 0 else { return }
        _ = kill(-pid, SIGTERM)
        usleep(100_000)
        _ = kill(-pid, SIGKILL)
    }
}

typealias MediaToolInspection = @Sendable (
    _ executableURL: URL,
    _ arguments: [String],
    _ environment: [String: String],
    _ timeout: Duration
) async throws -> BoundedProcessResult

public struct MediaToolVerifier: Sendable {
    public let directory: URL
    public let signaturePolicy: MediaToolSignaturePolicy
    private let inspection: MediaToolInspection

    public init(directory: URL, signaturePolicy: MediaToolSignaturePolicy = .requireValid, runner: BoundedProcessRunner = BoundedProcessRunner()) {
        self.directory = directory
        self.signaturePolicy = signaturePolicy
        self.inspection = runner.run
    }

    init(directory: URL, signaturePolicy: MediaToolSignaturePolicy = .requireValid, inspection: @escaping MediaToolInspection) {
        self.directory = directory
        self.signaturePolicy = signaturePolicy
        self.inspection = inspection
    }

    public func verify() async throws -> VerifiedMediaTools {
        let root = try Self.canonicalDirectory(directory)
        let manifestURL = try Self.containedRegularFile(relativePath: "manifest.json", in: root)
        let manifestData = try Data(contentsOf: manifestURL)
        try Self.validateManifestShape(manifestData)
        let manifest: MediaToolManifest
        do {
            manifest = try JSONDecoder().decode(MediaToolManifest.self, from: manifestData)
        } catch {
            throw FileConvertError.providerUnavailable("Media tool manifest is invalid")
        }
        guard manifest.schemaVersion == 1, manifest.status == "available",
              let version = manifest.ffmpegVersion,
              let build = manifest.build,
              let artifacts = manifest.artifacts,
              let inventory = manifest.inventory,
              let sources = manifest.sources, !sources.isEmpty,
              let licenses = manifest.licenses, !licenses.isEmpty,
              !version.isEmpty, !build.configuration.isEmpty,
              !build.configuration.contains("--enable-gpl"),
              !build.configuration.contains("--enable-nonfree"),
              build.architectures == ["arm64"], artifacts.count == 2,
              Set(artifacts.map(\.name)) == ["ffmpeg", "ffprobe"],
              Set(artifacts.map(\.path)).count == artifacts.count,
              Set(sources.map(\.name)).count == sources.count,
              Set(licenses.map(\.source)).count == licenses.count,
              artifacts.allSatisfy({ Self.validArtifactIdentity($0, architectures: build.architectures) }) else {
            throw FileConvertError.providerUnavailable("Invalid media tool manifest")
        }
        let ffmpegArtifact = artifacts.first { $0.name == "ffmpeg" }!
        let ffprobeArtifact = artifacts.first { $0.name == "ffprobe" }!
        let ffmpeg = try Self.containedRegularFile(relativePath: ffmpegArtifact.path, in: root, requiresExecutable: true)
        let ffprobe = try Self.containedRegularFile(relativePath: ffprobeArtifact.path, in: root, requiresExecutable: true)
        for (artifact, executable) in [(ffmpegArtifact, ffmpeg), (ffprobeArtifact, ffprobe)] {
            if let expectedHash = artifact.sha256 {
                guard try Self.sha256(executable) == expectedHash.lowercased() else {
                    throw FileConvertError.providerUnavailable("Media tool hash mismatch")
                }
            }
        }
        for license in licenses {
            let notice = try Self.containedRegularFile(relativePath: license.source, in: root)
            guard try Self.sha256(notice) == license.sha256.lowercased() else {
                throw FileConvertError.providerUnavailable("Media tool license hash mismatch")
            }
        }
        if signaturePolicy == .requireValid {
            try verifySignature(ffmpeg, signature: ffmpegArtifact.signature)
            try verifySignature(ffprobe, signature: ffprobeArtifact.signature)
        }
        try await verifyArchitectures(ffmpeg, expected: build.architectures)
        try await verifyArchitectures(ffprobe, expected: build.architectures)
        let ffmpegVersion = try await successfulOutput(ffmpeg, ["-version"])
        let ffprobeVersion = try await successfulOutput(ffprobe, ["-version"])
        guard Self.reports(version: version, tool: "ffmpeg", output: ffmpegVersion),
              Self.reports(version: version, tool: "ffprobe", output: ffprobeVersion) else {
            throw FileConvertError.providerUnavailable("Media tool version mismatch")
        }
        let observedFFmpegConfiguration: [String]
        let observedFFprobeConfiguration: [String]
        do {
            try MediaConfiguration.validate(build.configuration)
            observedFFmpegConfiguration = try MediaConfiguration.canonicalArguments(
                from: try await successfulOutput(ffmpeg, ["-hide_banner", "-buildconf"])
            )
            observedFFprobeConfiguration = try MediaConfiguration.canonicalArguments(
                from: try await successfulOutput(ffprobe, ["-hide_banner", "-buildconf"])
            )
        } catch {
            throw FileConvertError.providerUnavailable("Media tool build configuration mismatch")
        }
        let forbiddenConfiguration: Set<String> = ["--enable-gpl", "--enable-nonfree", "--enable-version3"]
        guard MediaConfiguration.sha256(build.configuration) == build.configurationSHA256.lowercased(),
              observedFFmpegConfiguration == build.configuration,
              observedFFprobeConfiguration == build.configuration,
              forbiddenConfiguration.isDisjoint(with: observedFFmpegConfiguration),
              forbiddenConfiguration.isDisjoint(with: observedFFprobeConfiguration) else {
            throw FileConvertError.providerUnavailable("Media tool build configuration mismatch")
        }
        let encoders = MediaInventoryParser.parse(try await successfulOutput(ffmpeg, ["-encoders"]))
        let muxers = MediaInventoryParser.parse(try await successfulOutput(ffmpeg, ["-muxers"]))
        let demuxers = MediaInventoryParser.parse(try await successfulOutput(ffmpeg, ["-demuxers"]))
        guard encoders == inventory.encoders, muxers == inventory.muxers, demuxers == inventory.demuxers,
              Self.supportedInventory(encoders: encoders, muxers: muxers, demuxers: demuxers) else {
            throw FileConvertError.providerUnavailable("Media tool inventory mismatch")
        }
        let selfTest = try await inspection(ffmpeg, ["-hide_banner", "-nostdin", "-v", "error", "-f", "lavfi", "-i", "anullsrc=r=8000:cl=mono", "-t", "0.01", "-f", "null", "-"], Self.sanitizedEnvironment, .seconds(10))
        guard selfTest.terminationStatus == 0 else { throw FileConvertError.providerUnavailable("Media tool startup self-test failed") }
        return VerifiedMediaTools(ffmpegURL: ffmpeg, ffprobeURL: ffprobe, version: version, encoders: encoders, muxers: muxers, demuxers: demuxers)
    }

    private func successfulOutput(_ executable: URL, _ arguments: [String]) async throws -> String {
        let result = try await inspection(executable, arguments, Self.sanitizedEnvironment, .seconds(10))
        guard result.terminationStatus == 0, let text = String(data: result.stdout, encoding: .utf8) else {
            throw FileConvertError.providerUnavailable("Media tool inspection failed")
        }
        return text
    }

    private func verifySignature(_ executable: URL, signature: MediaToolManifest.Signature) throws {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else {
            throw FileConvertError.providerUnavailable("Media tool code signature is unavailable")
        }
        var requirement: SecRequirement?
        if signature.mode == "identity" {
            let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(Self.expectedTeamIdentifier)\""
            guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else {
                throw FileConvertError.providerUnavailable("Media tool code requirement is invalid")
            }
        }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        guard SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess else {
            throw FileConvertError.providerUnavailable("Media tool code signature is invalid")
        }
    }

    private func verifyArchitectures(_ executable: URL, expected: Set<String>) async throws {
        let result = try await inspection(URL(filePath: "/usr/bin/lipo"), ["-archs", executable.path], Self.sanitizedEnvironment, .seconds(10))
        guard result.terminationStatus == 0, let text = String(data: result.stdout, encoding: .utf8) else { throw FileConvertError.providerUnavailable("Cannot inspect media tool architectures") }
        let observed = Set(text.split(whereSeparator: \.isWhitespace).map(String.init))
        guard observed == expected else { throw FileConvertError.providerUnavailable("Media tool architecture mismatch") }
    }

    private static let expectedTeamIdentifier = "C5C4W9B7FS"

    private static func validArtifactIdentity(
        _ artifact: MediaToolManifest.Artifact,
        architectures: Set<String>
    ) -> Bool {
        guard artifact.architectures == architectures else { return false }
        switch artifact.signature.mode {
        case "adhoc":
            return artifact.sha256 != nil && artifact.signature.teamIdentifier == nil
        case "identity":
            return artifact.sha256 == nil && artifact.signature.teamIdentifier == expectedTeamIdentifier
        default:
            return false
        }
    }
    private static let sanitizedEnvironment = ["PATH": "/usr/bin:/bin", "HOME": "/var/empty", "LANG": "C"]

    private static func canonicalDirectory(_ directory: URL) throws -> URL {
        let canonical = directory.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FileConvertError.providerUnavailable("Media tool directory is unavailable")
        }
        return canonical
    }

    private static func containedRegularFile(
        relativePath: String,
        in directory: URL,
        requiresExecutable: Bool = false
    ) throws -> URL {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw FileConvertError.providerUnavailable("Unsafe media tool path")
        }
        let candidate = directory.appending(path: relativePath).standardizedFileURL
        var candidateInfo = stat()
        guard lstat(candidate.path, &candidateInfo) == 0, (candidateInfo.st_mode & S_IFMT) == S_IFREG,
              !requiresExecutable || candidateInfo.st_mode & 0o111 != 0 else {
            throw FileConvertError.providerUnavailable("Media tool is not an executable regular file")
        }
        let canonical = candidate.resolvingSymlinksInPath().standardizedFileURL
        let rootComponents = directory.pathComponents
        guard canonical == candidate, canonical.pathComponents.count > rootComponents.count,
              canonical.pathComponents.prefix(rootComponents.count).elementsEqual(rootComponents) else {
            throw FileConvertError.providerUnavailable("Media tool escapes directory")
        }
        return canonical
    }

    private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func validateManifestShape(_ data: Data) throws {
        guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FileConvertError.providerUnavailable("Media tool manifest is not an object")
        }
        try validateObject(manifest, allowed: ["schemaVersion", "status", "reason", "ffmpegVersion", "sources", "licenses", "build", "artifacts", "inventory"])
        if let build = manifest["build"] as? [String: Any] { try validateObject(build, allowed: ["configuration", "configurationSHA256", "architectures"]) }
        if let inventory = manifest["inventory"] as? [String: Any] { try validateObject(inventory, allowed: ["encoders", "muxers", "demuxers"]) }
        if let artifacts = manifest["artifacts"] as? [[String: Any]] {
            for artifact in artifacts {
                try validateObject(artifact, allowed: ["name", "path", "sha256", "architectures", "signature"])
                if let signature = artifact["signature"] as? [String: Any] { try validateObject(signature, allowed: ["mode", "identity", "teamIdentifier"]) }
            }
        }
        if let sources = manifest["sources"] as? [[String: Any]] { for source in sources { try validateObject(source, allowed: ["name", "version", "url", "sha256", "license"]) } }
        if let licenses = manifest["licenses"] as? [[String: Any]] { for license in licenses { try validateObject(license, allowed: ["name", "license", "source", "sha256"]) } }
    }

    private static func validateObject(_ object: [String: Any], allowed: Set<String>) throws {
        guard Set(object.keys).isSubset(of: allowed) else { throw FileConvertError.providerUnavailable("Media tool manifest has unknown fields") }
    }
    private static func reports(version: String, tool: String, output: String) -> Bool {
        output.split(separator: "\n", maxSplits: 1).first?.hasPrefix("\(tool) version \(version) ") == true
    }



    private static func supportedInventory(encoders: Set<String>, muxers: Set<String>, demuxers: Set<String>) -> Bool {
        let requiredEncoders: Set<String> = ["aac", "libopus", "libvorbis", "flac", "pcm_s16le", "pcm_s16be", "libmp3lame", "mpeg4", "libvpx-vp9"]
        let requiredMuxers: Set<String> = ["mp3", "ipod", "adts", "wav", "aiff", "flac", "ogg", "opus", "mp4", "mov", "matroska", "webm"]
        let requiredDemuxers: Set<String> = ["aac", "mp3", "mov", "wav", "aiff", "flac", "ogg", "matroska"]
        return requiredEncoders.isSubset(of: encoders) && requiredMuxers.isSubset(of: muxers) && requiredDemuxers.isSubset(of: demuxers)
    }
}
