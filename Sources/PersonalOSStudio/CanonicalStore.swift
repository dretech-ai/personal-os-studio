import Foundation
import Combine

/// Reads the canonical Agent OS repo (the "personal OS") and groups its
/// Markdown files by layer.
final class CanonicalStore: ObservableObject {
    @Published var rootURL: URL
    @Published var filesByLayer: [Layer: [CanonicalFile]] = [:]
    @Published var loadError: String?

    /// Whether fictional example files (examples/, `sample: true`) are loaded.
    /// Off by default so the app starts as a fresh install — only real content and
    /// templates (to be defined) appear, never the sample personas (e.g. Casey Rivera).
    let includeExamples: Bool

    private let fm = FileManager.default

    init(rootURL: URL, includeExamples: Bool = false) {
        self.rootURL = rootURL
        self.includeExamples = includeExamples
        reload()
    }

    func setRoot(_ url: URL) {
        rootURL = url
        reload()
    }

    var isValidRoot: Bool {
        // A plausible Agent OS repo has at least an identity/ and adapters/ dir.
        fm.fileExists(atPath: rootURL.appendingPathComponent("adapters").path)
    }

    func reload() {
        var result: [Layer: [CanonicalFile]] = [:]
        loadError = nil

        for layer in Layer.allCases {
            let layerDir = rootURL.appendingPathComponent(layer.rawValue)
            var files: [CanonicalFile] = []
            guard let en = fm.enumerator(at: layerDir,
                                         includingPropertiesForKeys: nil,
                                         options: [.skipsHiddenFiles]) else {
                result[layer] = []
                continue
            }
            for case let url as URL in en {
                guard url.pathExtension == "md" else { continue }
                let name = url.lastPathComponent
                // Skip the layer-level backlog scaffolds from the build set but still list them.
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                let fields = Frontmatter.fields(of: text)
                let isTemplate = name.contains(".template.")
                    || name == "backlog.template.md"
                    || name.hasSuffix("template.md")
                let isExample = url.path.contains("/examples/")
                    || (fields["sample"]?.lowercased() == "true")
                // Fresh-install default: don't surface fictional sample data.
                if isExample && !includeExamples { continue }
                let file = CanonicalFile(url: url,
                                         layer: layer,
                                         frontmatter: fields,
                                         isTemplate: isTemplate,
                                         isExample: isExample)
                files.append(file)
            }
            files.sort { a, b in
                // Real content first, then examples, then templates; alpha within.
                func rank(_ f: CanonicalFile) -> Int {
                    if f.isTemplate { return 2 }
                    if f.isExample { return 1 }
                    return 0
                }
                if rank(a) != rank(b) { return rank(a) < rank(b) }
                return a.filename.localizedCaseInsensitiveCompare(b.filename) == .orderedAscending
            }
            result[layer] = files
        }
        filesByLayer = result
    }

    func files(_ layer: Layer) -> [CanonicalFile] {
        filesByLayer[layer] ?? []
    }

    /// Find a loaded file by its path relative to the canonical root.
    /// Symlink-insensitive: Foundation normalizes /tmp vs /private/tmp (and /var)
    /// inconsistently between constructed and enumerated URLs — resolve both sides.
    func file(atRelativePath relativePath: String) -> CanonicalFile? {
        let path = rootURL.appendingPathComponent(relativePath).resolvingSymlinksInPath().path
        for layer in Layer.allCases {
            if let f = files(layer).first(where: { $0.url.resolvingSymlinksInPath().path == path }) {
                return f
            }
        }
        return nil
    }

    /// All files currently flagged for inclusion in a build.
    func includedFiles(_ layer: Layer) -> [CanonicalFile] {
        files(layer).filter { $0.include }
    }

    func read(_ file: CanonicalFile) -> String {
        (try? String(contentsOf: file.url, encoding: .utf8)) ?? ""
    }

    func write(_ text: String, to file: CanonicalFile) throws {
        try text.write(to: file.url, atomically: true, encoding: .utf8)
    }

    /// Create (or overwrite) a file at `relativePath` under the canonical root,
    /// creating intermediate directories. Returns the written URL.
    @discardableResult
    func createFile(relativePath: String, contents: String) throws -> URL {
        let dest = rootURL.appendingPathComponent(relativePath)
        try fm.createDirectory(at: dest.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try contents.write(to: dest, atomically: true, encoding: .utf8)
        return dest
    }

    /// True if a file already exists at `relativePath` under the canonical root.
    func fileExists(relativePath: String) -> Bool {
        fm.fileExists(atPath: rootURL.appendingPathComponent(relativePath).path)
    }

    /// Summary counts for the header.
    var contentCount: Int {
        Layer.allCases.reduce(0) { $0 + files($1).filter { !$0.isTemplate && !$0.isExample }.count }
    }
    var exampleCount: Int {
        Layer.allCases.reduce(0) { $0 + files($1).filter { $0.isExample }.count }
    }
    var templateCount: Int {
        Layer.allCases.reduce(0) { $0 + files($1).filter { $0.isTemplate }.count }
    }
}
