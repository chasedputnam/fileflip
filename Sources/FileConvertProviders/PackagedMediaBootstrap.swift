import Darwin
import FileConvertCore
import Foundation

public struct BundledMediaToolsLocator: Sendable {
    public init() {}

    public func locate(in applicationBundle: Bundle) throws -> URL {
        guard let resourcesURL = applicationBundle.resourceURL else {
            throw FileConvertError.providerUnavailable("Application resources are unavailable")
        }
        return try locate(resourcesURL: resourcesURL)
    }

    func locate(resourcesURL: URL) throws -> URL {
        let resources = resourcesURL.resolvingSymlinksInPath().standardizedFileURL
        var resourcesInfo = stat()
        guard lstat(resources.path, &resourcesInfo) == 0,
              (resourcesInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw FileConvertError.providerUnavailable("Application resources are unavailable")
        }

        let candidate = resources.appending(path: "MediaTools", directoryHint: .isDirectory).standardizedFileURL
        var candidateInfo = stat()
        guard lstat(candidate.path, &candidateInfo) == 0,
              (candidateInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw FileConvertError.providerUnavailable("Packaged media tools are unavailable")
        }
        let canonical = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard canonical.deletingLastPathComponent() == resources else {
            throw FileConvertError.providerUnavailable("Packaged media tools escape application resources")
        }
        return canonical
    }
}

public struct PackagedMediaComponents: Sendable {
    public let tools: VerifiedMediaTools
    public let provider: FFmpegMediaProvider
    public let validator: IndependentValidator

    public init(tools: VerifiedMediaTools, provider: FFmpegMediaProvider, validator: IndependentValidator) {
        self.tools = tools
        self.provider = provider
        self.validator = validator
    }
}

public struct PackagedMediaBootstrap: Sendable {
    private let signaturePolicy: MediaToolSignaturePolicy
    private let runner: BoundedProcessRunner

    public init(
        signaturePolicy: MediaToolSignaturePolicy = .requireValid,
        runner: BoundedProcessRunner = BoundedProcessRunner()
    ) {
        self.signaturePolicy = signaturePolicy
        self.runner = runner
    }

    public func load(from directory: URL) async throws -> PackagedMediaComponents {
        let tools = try await MediaToolVerifier(
            directory: directory,
            signaturePolicy: signaturePolicy,
            runner: runner
        ).verify()
        let provider = FFmpegMediaProvider(tools: tools, runner: runner)
        let validator = FFprobeMediaValidator(tools: tools).certificationValidator()
        return PackagedMediaComponents(tools: tools, provider: provider, validator: validator)
    }
}
