import FileConvertCore
import Foundation
import WebKit

public struct MarkdownHTMLProvider: ConversionProvider {
    public let id = ProviderID(rawValue: "native-markdown-html")

    public init() {}

    public func health() async -> ProviderHealth { .available(version: "native-safe-subset-1") }

    public func capabilities() async -> Set<ConversionCapability> {
        [
            ConversionCapability(source: .document(.markdown), targetExtension: "html", providerID: id, defaultPolicy: .document(), lossProfile: .lossless),
            ConversionCapability(source: .document(.markdown), targetExtension: "pdf", providerID: id, defaultPolicy: .document(acceptsFidelityLoss: true), lossProfile: .potentiallyLossy),
            ConversionCapability(source: .document(.html), targetExtension: "md", providerID: id, defaultPolicy: .document(), lossProfile: .requiresChoice),
            ConversionCapability(source: .document(.html), targetExtension: "markdown", providerID: id, defaultPolicy: .document(), lossProfile: .requiresChoice),
        ]
    }

    public func convert(_ request: ConversionRequest) async throws -> ProducedArtifact {
        try Task.checkCancellation()
        guard Date() < request.deadline else { throw FileConvertError.timedOut }
        guard case let .document(version, acceptsFidelityLoss, pageIndex, imageQuality) = request.policy,
              version == 1, pageIndex == nil, imageQuality.isFinite, (0 ... 1).contains(imageQuality) else {
            throw FileConvertError.validationFailed("Markdown and HTML conversion requires a version 1 document policy without page selection and with image quality between 0 and 1")
        }
        let target = normalize(request.targetExtension)
        let input = try strictUTF8(at: request.source.url)
        switch target {
        case "html":
            let html = try DeterministicMarkdownRenderer.render(input)
            return try write(html, extension: "html", request: request)
        case "pdf":
            guard acceptsFidelityLoss else {
                throw FileConvertError.requiresChoice
            }
            let html = try DeterministicMarkdownRenderer.render(input)
            let output = request.outputDirectory.appending(path: "output.pdf")
            let data = try await IsolatedHTMLPDFRenderer.render(html: html)
            guard !data.isEmpty, UInt64(data.count) <= request.maximumOutputBytes else {
                throw FileConvertError.validationFailed("HTML-to-PDF output exceeds its byte limit")
            }
            try data.write(to: output, options: .atomic)
            return ProducedArtifact(url: output, providerID: id)
        case "md", "markdown":
            try SafeHTMLSubset.validate(input)
            let markdown = try SafeHTMLSubset.toMarkdown(input)
            return try write(markdown, extension: target, request: request)
        default:
            throw FileConvertError.unsupportedPair
        }
    }

    private func write(_ value: String, extension: String, request: ConversionRequest) throws -> ProducedArtifact {
        guard let data = value.data(using: .utf8), UInt64(data.count) <= request.maximumOutputBytes else {
            throw FileConvertError.validationFailed("Text output exceeds its byte limit")
        }
        let output = request.outputDirectory.appending(path: "output.\(`extension`)")
        guard !FileManager.default.fileExists(atPath: output.path) else { throw FileConvertError.validationFailed("Provider output already exists") }
        try data.write(to: output, options: .atomic)
        return ProducedArtifact(url: output, providerID: id)
    }

    private func strictUTF8(at url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard let value = String(data: data, encoding: .utf8), !value.contains("\u{0}") else {
            throw FileConvertError.validationFailed("Document input is not strict UTF-8")
        }
        return value
    }

    private func normalize(_ extension: String) -> String { `extension`.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
}

private enum DeterministicMarkdownRenderer {
    static func render(_ markdown: String) throws -> String {
        // Syntax acceptance and rendering are intentionally narrow, deterministic, and independent
        // of WebKit or operating-system parser behavior.
        var output = [String]()
        var inList = false
        var inCode = false
        var paragraph = [String]()

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            output.append("<p>\(inline(paragraph.joined(separator: " ")))</p>")
            paragraph.removeAll(keepingCapacity: true)
        }
        func closeList() {
            if inList { output.append("</ul>"); inList = false }
        }

        for line in markdown.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line == "```" {
                flushParagraph(); closeList()
                output.append(inCode ? "</code></pre>" : "<pre><code>")
                inCode.toggle()
                continue
            }
            if inCode { output.append(escape(line)); continue }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flushParagraph(); closeList(); continue }
            let hashes = line.prefix { $0 == "#" }.count
            if hashes > 0, hashes <= 6, line.dropFirst(hashes).first == " " {
                flushParagraph(); closeList()
                output.append("<h\(hashes)>\(inline(String(line.dropFirst(hashes + 1))))</h\(hashes)>")
            } else if line.hasPrefix("- ") {
                flushParagraph()
                if !inList { output.append("<ul>"); inList = true }
                output.append("<li>\(inline(String(line.dropFirst(2))))</li>")
            } else {
                closeList(); paragraph.append(line)
            }
        }
        guard !inCode else { throw FileConvertError.validationFailed("Unclosed Markdown code fence") }
        flushParagraph(); closeList()
        return output.joined(separator: "\n")
    }

    private static func inline(_ value: String) -> String {
        var result = escape(value)
        result = replace(result, pattern: "`([^`]+)`", template: "<code>$1</code>")
        result = replace(result, pattern: "\\*\\*([^*]+)\\*\\*", template: "<strong>$1</strong>")
        result = replace(result, pattern: "\\*([^*]+)\\*", template: "<em>$1</em>")
        result = replace(result, pattern: "\\[([^]]+)\\]\\((https?://[^ )]+)\\)", template: "<a href=\"$2\">$1</a>")
        return result
    }

    private static func replace(_ value: String, pattern: String, template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        return expression.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: template)
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// The only HTML accepted for conversion: paragraphs, headings, emphasis,
/// code/preformatted text, lists, line breaks, and absolute HTTP(S) links.
/// Active content, styling, media, forms, and resource-bearing attributes are
/// rejected rather than silently discarded.
public enum SafeHTMLSubset {
    private static let allowedTags: Set<String> = ["p", "h1", "h2", "h3", "h4", "h5", "h6", "strong", "em", "code", "pre", "ul", "ol", "li", "br", "a"]
    private static let voidTags: Set<String> = ["br"]

    public static func validate(_ html: String) throws {
        if html.range(of: #"<(script|style|iframe|object|embed|form|input|button|svg|math|img|video|audio|link|meta|base)\b"#, options: [.regularExpression, .caseInsensitive]) != nil ||
            html.range(of: #"\bon[a-z]+\s*="# , options: [.regularExpression, .caseInsensitive]) != nil ||
            html.range(of: #"\b(style|src|srcset|action|data)\s*="# , options: [.regularExpression, .caseInsensitive]) != nil {
            throw FileConvertError.validationFailed("HTML contains active, external-resource, or unsupported content")
        }
        let expression = try NSRegularExpression(pattern: #"</?([A-Za-z][A-Za-z0-9]*)([^>]*)>"#)
        var stack = [String]()
        var cursor = html.startIndex
        for match in expression.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range, in: html), let nameRange = Range(match.range(at: 1), in: html) else { continue }
            let text = String(html[cursor..<range.lowerBound])
            if text.contains("<") || text.contains(">") { throw FileConvertError.validationFailed("Malformed HTML text") }
            let tag = String(html[nameRange]).lowercased()
            guard allowedTags.contains(tag) else { throw FileConvertError.validationFailed("HTML tag is outside the safe subset") }
            let token = String(html[range])
            let attributes = String(html[Range(match.range(at: 2), in: html)!]).trimmingCharacters(in: .whitespacesAndNewlines)
            if token.hasPrefix("</") {
                guard attributes.isEmpty, stack.last == tag else { throw FileConvertError.validationFailed("Malformed HTML nesting") }
                _ = stack.popLast()
            } else {
                if tag == "a" {
                    guard attributes.range(of: #"^href=\"https?://[^\"<>[:space:]]+\"$"#, options: [.regularExpression, .caseInsensitive]) != nil else {
                        throw FileConvertError.validationFailed("HTML links must use a safe absolute HTTP(S) href")
                    }
                } else if !attributes.isEmpty { throw FileConvertError.validationFailed("HTML attributes are outside the safe subset") }
                if !voidTags.contains(tag) { stack.append(tag) }
            }
            cursor = range.upperBound
        }
        let trailing = String(html[cursor...])
        guard !trailing.contains("<"), !trailing.contains(">"), stack.isEmpty else { throw FileConvertError.validationFailed("Malformed HTML") }
    }

    public static func toMarkdown(_ html: String) throws -> String {
        try validate(html)
        var result = html
        result = replace(result, #"<a href=\"([^\"]+)\">([^<]*)</a>"#, "[$2]($1)")
        result = replace(result, #"<(strong)>"#, "**"); result = result.replacingOccurrences(of: "</strong>", with: "**")
        result = replace(result, #"<(em)>"#, "*"); result = result.replacingOccurrences(of: "</em>", with: "*")
        result = result.replacingOccurrences(of: "<code>", with: "`").replacingOccurrences(of: "</code>", with: "`")
        result = result.replacingOccurrences(of: "<pre>", with: "````\n").replacingOccurrences(of: "</pre>", with: "\n````\n")
        for level in 1 ... 6 { result = result.replacingOccurrences(of: "<h\(level)>", with: String(repeating: "#", count: level) + " ").replacingOccurrences(of: "</h\(level)>", with: "\n\n") }
        result = result.replacingOccurrences(of: "<p>", with: "").replacingOccurrences(of: "</p>", with: "\n\n")
        result = result.replacingOccurrences(of: "<ul>", with: "").replacingOccurrences(of: "</ul>", with: "\n")
        result = result.replacingOccurrences(of: "<ol>", with: "").replacingOccurrences(of: "</ol>", with: "\n")
        result = result.replacingOccurrences(of: "<li>", with: "- ").replacingOccurrences(of: "</li>", with: "\n")
        result = result.replacingOccurrences(of: "<br>", with: "\n")
        return decode(result).trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func replace(_ value: String, _ pattern: String, _ template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        return expression.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: template)
    }

    private static func decode(_ value: String) -> String {
        value.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&")
    }
}

@MainActor
private final class IsolatedHTMLPDFRenderer: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private let webView: WKWebView

    private override init() {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    static func render(html: String) async throws -> Data {
        try SafeHTMLSubset.validate(html)
        let renderer = IsolatedHTMLPDFRenderer()
        try await renderer.load(html)
        return try await renderer.pdfData()
    }

    private func load(_ html: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    private func pdfData() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            webView.createPDF(configuration: WKPDFConfiguration()) { result in
                continuation.resume(with: result)
            }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        decisionHandler(url == nil || url?.scheme == "about" ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume(); continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error); continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error); continuation = nil
    }
}
