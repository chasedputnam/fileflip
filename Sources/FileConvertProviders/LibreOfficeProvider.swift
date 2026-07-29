import Darwin
import FileConvertCore
import Foundation

public enum LibreOfficeSignaturePolicy: Sendable { case requireDeveloperID, skipForTesting }

public struct VerifiedLibreOffice: Sendable {
    public let applicationURL: URL
    public let executableURL: URL
    public let version: String
    public let filters: Set<String>

    public init(applicationURL: URL, executableURL: URL, version: String, filters: Set<String>) {
        self.applicationURL = applicationURL
        self.executableURL = executableURL
        self.version = version
        self.filters = filters
    }
}

/// Discovers only a signed, canonical LibreOffice application bundle. Production callers must not
/// inject an executable: the app bundle is the security boundary.
public struct LibreOfficeVerifier: Sendable {
    public static let bundleIdentifier = "org.libreoffice.script"
    public static let requiredFilters: Set<String> = [
        "Office Open XML Text", "OpenDocument Text", "writer_pdf_Export", "Text", "HTML (StarWriter)",
        "Office Open XML Spreadsheet", "calc8", "Text - txt - csv (StarCalc)"
    ]

    public let signaturePolicy: LibreOfficeSignaturePolicy
    public let runner: BoundedProcessRunner
    public let candidateApplications: [URL]

    public init(signaturePolicy: LibreOfficeSignaturePolicy = .requireDeveloperID, runner: BoundedProcessRunner = BoundedProcessRunner(), candidateApplications: [URL]? = nil) {
        self.signaturePolicy = signaturePolicy
        self.runner = runner
        self.candidateApplications = candidateApplications ?? [
            URL(fileURLWithPath: "/Applications/LibreOffice.app"),
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications/LibreOffice.app")
        ]
    }

    public func verify() async throws -> VerifiedLibreOffice {
        var lastError: Error = FileConvertError.providerUnavailable("LibreOffice is not installed")
        for candidate in candidateApplications {
            do { return try await verify(applicationURL: candidate) } catch { lastError = error }
        }
        throw lastError
    }

    public func verify(applicationURL: URL) async throws -> VerifiedLibreOffice {
        let application = try Self.canonicalDirectory(applicationURL)
        guard application.pathExtension == "app", application.lastPathComponent == "LibreOffice.app" else {
            throw FileConvertError.providerUnavailable("Invalid LibreOffice application bundle")
        }
        guard let bundle = Bundle(url: application), bundle.bundleIdentifier == Self.bundleIdentifier,
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              Self.isTested(version: version) else {
            throw FileConvertError.providerUnavailable("Unsupported LibreOffice bundle or version")
        }
        let executable = try Self.containedExecutable("Contents/MacOS/soffice", application: application)
        if signaturePolicy == .requireDeveloperID { try await verifyDeveloperID(application: application) }
        let reportedVersion = try await successfulOutput(executable, ["--version"])
        guard reportedVersion.localizedCaseInsensitiveContains(version) else {
            throw FileConvertError.providerUnavailable("LibreOffice executable version does not match its bundle")
        }
        let inventory = try await filterInventory(executable: executable)
        guard Self.requiredFilters.isSubset(of: inventory) else {
            throw FileConvertError.providerUnavailable("LibreOffice lacks an approved conversion filter")
        }
        try await startupSelfTest(executable: executable)
        return VerifiedLibreOffice(applicationURL: application, executableURL: executable, version: version, filters: inventory)
    }

    private func verifyDeveloperID(application: URL) async throws {
        let result = try await runner.run(executableURL: URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["--verify", "--strict", "--deep", application.path], timeout: .seconds(20))
        guard result.terminationStatus == 0 else { throw FileConvertError.providerUnavailable("LibreOffice signature verification failed") }
        let detail = try await runner.run(executableURL: URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["-dv", "--verbose=4", application.path], timeout: .seconds(20))
        let text = String(decoding: detail.stderr + detail.stdout, as: UTF8.self)
        guard detail.terminationStatus == 0, text.contains("Authority=Developer ID Application:") else {
            throw FileConvertError.providerUnavailable("LibreOffice is not Developer ID signed")
        }
    }

    private func filterInventory(executable: URL) async throws -> Set<String> {
        let result = try await runner.run(executableURL: executable, arguments: ["--headless", "--convert-to", "?"], environment: Self.sanitizedEnvironment, timeout: .seconds(30))
        guard result.terminationStatus == 0 else { throw FileConvertError.providerUnavailable("Unable to inspect LibreOffice filters") }
        let output = String(decoding: result.stdout + result.stderr, as: UTF8.self)
        let known = Self.requiredFilters.filter { output.contains($0) }
        return Set(known)
    }

    private func startupSelfTest(executable: URL) async throws {
        let profile = try Self.makeProfile()
        defer { try? FileManager.default.removeItem(at: profile) }
        let result = try await runner.run(executableURL: executable, arguments: Self.startupArguments(profile: profile) + ["--version"], environment: Self.sanitizedEnvironment, timeout: .seconds(30))
        guard result.terminationStatus == 0 else { throw FileConvertError.providerUnavailable("LibreOffice isolated startup self-test failed") }
    }

    static let sanitizedEnvironment = ["HOME": "/var/empty", "PATH": "/usr/bin:/bin"]
    static func startupArguments(profile: URL) -> [String] { ["--headless", "--nologo", "--nodefault", "--nofirststartwizard", "-env:UserInstallation=\(profile.absoluteString)"] }
    static func makeProfile() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "file-flip-lo-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }
    public static func isTested(version: String) -> Bool {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard let major = parts.first else { return false }
        return (7 ... 25).contains(major)
    }
    static func canonicalDirectory(_ url: URL) throws -> URL {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        var status = stat()
        guard lstat(canonical.path, &status) == 0, (status.st_mode & S_IFMT) == S_IFDIR, (status.st_mode & S_IFMT) != S_IFLNK else { throw FileConvertError.providerUnavailable("LibreOffice path is not a real directory") }
        return canonical
    }
    static func containedExecutable(_ relative: String, application: URL) throws -> URL {
        let candidate = application.appending(path: relative).resolvingSymlinksInPath().standardizedFileURL
        guard candidate.path.hasPrefix(application.path + "/") else { throw FileConvertError.providerUnavailable("LibreOffice executable escapes its bundle") }
        var status = stat()
        guard lstat(candidate.path, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG, access(candidate.path, X_OK) == 0 else { throw FileConvertError.providerUnavailable("LibreOffice executable is not executable") }
        return candidate
    }
    private func successfulOutput(_ executable: URL, _ arguments: [String]) async throws -> String {
        let result = try await runner.run(executableURL: executable, arguments: arguments, environment: Self.sanitizedEnvironment, timeout: .seconds(30))
        guard result.terminationStatus == 0 else { throw FileConvertError.providerUnavailable("LibreOffice executable failed verification") }
        return String(decoding: result.stdout + result.stderr, as: UTF8.self)
    }
}

private actor LibreOfficeGate {
    static let shared = LibreOfficeGate()
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if !occupied {
            occupied = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            occupied = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        return try await body()
    }
}

public struct LibreOfficeProvider: ConversionProvider {
    public let id = ProviderID(rawValue: "installed-libreoffice")
    private let verifier: LibreOfficeVerifier
    private let verified: VerifiedLibreOffice?

    public init(verifier: LibreOfficeVerifier = LibreOfficeVerifier(), verifiedInstallation: VerifiedLibreOffice? = nil) {
        self.verifier = verifier
        self.verified = verifiedInstallation
    }

    public func health() async -> ProviderHealth {
        do { return .available(version: try await installation().version) }
        catch { return .unavailable(reason: "LibreOffice verification failed") }
    }

    public func capabilities() async -> Set<ConversionCapability> {
        guard (try? await installation()) != nil else { return [] }
        return Set(Self.routes.map { route in ConversionCapability(source: route.source, targetExtension: route.target, providerID: id, defaultPolicy: route.policy, lossProfile: route.loss) })
    }

    public func convert(_ request: ConversionRequest) async throws -> ProducedArtifact {
        try await LibreOfficeGate.shared.run {
            try Task.checkCancellation()
            guard Date() < request.deadline else { throw FileConvertError.timedOut }
            let installation = try await self.installation()
            guard let route = Self.routes.first(where: { $0.source == Self.formatFor(request.source.url) && $0.target == Self.normalized(request.targetExtension) }) else { throw FileConvertError.unsupportedPair }
            try Self.validatePolicy(request.policy, route: route)
            try OfficePackageInspector.rejectUnsafeInput(request.source.url, format: route.source)
            if case .spreadsheet = route.source { try OfficePackageInspector.requireSheetPolicy(request.source.url, policy: request.policy) }
            try FileManager.default.createDirectory(at: request.outputDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let outputDirectory = try LibreOfficeVerifier.canonicalDirectory(request.outputDirectory)
            let profile = try LibreOfficeVerifier.makeProfile()
            defer { try? FileManager.default.removeItem(at: profile) }
            let work = outputDirectory.appending(path: ".office-\(request.jobID.uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: work) }
            let args = LibreOfficeVerifier.startupArguments(profile: profile) + ["--convert-to", Self.filterRequest(route: route, policy: request.policy), "--outdir", work.path, request.source.url.path]
            let seconds = max(1, min(900, Int(request.deadline.timeIntervalSinceNow)))
            let result = try await self.verifier.runner.run(executableURL: installation.executableURL, arguments: args, environment: LibreOfficeVerifier.sanitizedEnvironment, timeout: .seconds(seconds))
            guard result.terminationStatus == 0 else { throw FileConvertError.validationFailed("LibreOffice conversion failed") }
            let generated = work.appending(path: request.source.url.deletingPathExtension().lastPathComponent + ".\(route.target)")
            let output = outputDirectory.appending(path: "output.\(route.target)")
            try Self.requireContainedRegularFile(generated, in: work)
            guard !FileManager.default.fileExists(atPath: output.path) else { throw FileConvertError.validationFailed("Provider output already exists") }
            let size = try generated.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, UInt64(size) <= request.maximumOutputBytes else { throw FileConvertError.validationFailed("LibreOffice output exceeds its byte limit") }
            try FileManager.default.moveItem(at: generated, to: output)
            return ProducedArtifact(url: output, providerID: self.id)
        }
    }

    private func installation() async throws -> VerifiedLibreOffice { if let verified { return verified }; return try await verifier.verify() }
    private static func normalized(_ ext: String) -> String { ext.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
    private static func formatFor(_ url: URL) -> DetectedFormat? {
        switch normalized(url.pathExtension) { case "docx": .document(.docx); case "odt": .document(.odt); case "rtf": .document(.rtf); case "xlsx": .spreadsheet(.xlsx); case "ods": .spreadsheet(.ods); case "csv": .spreadsheet(.csv); default: nil }
    }
    private static func validatePolicy(_ policy: ConversionPolicy, route: Route) throws {
        guard policy.version > 0 else { throw FileConvertError.validationFailed("Unsupported office policy") }
        switch route.source {
        case .document:
            guard case let .document(_, acceptsFidelityLoss, _, _) = policy else { throw FileConvertError.validationFailed("Document route requires document policy") }
            guard route.loss != .potentiallyLossy || acceptsFidelityLoss else { throw FileConvertError.requiresChoice }
        case .spreadsheet:
            guard case let .spreadsheet(_, _, delimiter, _) = policy,
                  delimiter.count == 1,
                  delimiter.unicodeScalars.allSatisfy({ !$0.properties.isWhitespace && $0.value < 128 }) else {
                throw FileConvertError.validationFailed("Spreadsheet route requires safe spreadsheet policy")
            }
        default:
            throw FileConvertError.unsupportedPair
        }
    }
    private static func filterRequest(route: Route, policy: ConversionPolicy) -> String {
        guard route.target == "csv", case let .spreadsheet(_, _, delimiter, formulaValuesOnly) = policy,
              let delimiterScalar = delimiter.unicodeScalars.first else { return "\(route.target):\(route.filter)" }
        // LibreOffice's CSV filter options are numeric and originate solely from the typed policy.
        return "\(route.target):\(route.filter):\(delimiterScalar.value),34,76,1,,\(formulaValuesOnly ? "0" : "1")"
    }
    private static func requireContainedRegularFile(_ url: URL, in directory: URL) throws {
        let canonicalDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        var status = stat()
        guard canonical.path.hasPrefix(canonicalDirectory.path + "/"),
              lstat(url.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              (status.st_mode & S_IFMT) != S_IFLNK else {
            throw FileConvertError.validationFailed("LibreOffice output is not a contained regular file")
        }
    }

    private struct Route: Sendable { let source: DetectedFormat; let target: String; let filter: String; let policy: ConversionPolicy; let loss: LossProfile }
    private static let routes: [Route] = [
        .init(source: .document(.docx), target: "odt", filter: "OpenDocument Text", policy: .document(), loss: .potentiallyLossy),
        .init(source: .document(.odt), target: "docx", filter: "Office Open XML Text", policy: .document(), loss: .potentiallyLossy),
        .init(source: .document(.docx), target: "pdf", filter: "writer_pdf_Export", policy: .document(), loss: .potentiallyLossy), .init(source: .document(.odt), target: "pdf", filter: "writer_pdf_Export", policy: .document(), loss: .potentiallyLossy), .init(source: .document(.rtf), target: "pdf", filter: "writer_pdf_Export", policy: .document(), loss: .potentiallyLossy),
        .init(source: .document(.docx), target: "txt", filter: "Text", policy: .document(), loss: .potentiallyLossy), .init(source: .document(.odt), target: "txt", filter: "Text", policy: .document(), loss: .potentiallyLossy), .init(source: .document(.rtf), target: "txt", filter: "Text", policy: .document(), loss: .potentiallyLossy),
        .init(source: .document(.docx), target: "html", filter: "HTML (StarWriter)", policy: .document(), loss: .potentiallyLossy), .init(source: .document(.odt), target: "html", filter: "HTML (StarWriter)", policy: .document(), loss: .potentiallyLossy), .init(source: .document(.rtf), target: "html", filter: "HTML (StarWriter)", policy: .document(), loss: .potentiallyLossy),
        .init(source: .spreadsheet(.xlsx), target: "ods", filter: "calc8", policy: .spreadsheet(), loss: .potentiallyLossy), .init(source: .spreadsheet(.ods), target: "xlsx", filter: "Office Open XML Spreadsheet", policy: .spreadsheet(), loss: .potentiallyLossy),
        .init(source: .spreadsheet(.csv), target: "xlsx", filter: "Office Open XML Spreadsheet", policy: .spreadsheet(), loss: .lossless), .init(source: .spreadsheet(.csv), target: "ods", filter: "calc8", policy: .spreadsheet(), loss: .lossless),
        .init(source: .spreadsheet(.xlsx), target: "csv", filter: "Text - txt - csv (StarCalc)", policy: .spreadsheet(), loss: .requiresChoice), .init(source: .spreadsheet(.ods), target: "csv", filter: "Text - txt - csv (StarCalc)", policy: .spreadsheet(), loss: .requiresChoice)
    ]
}
