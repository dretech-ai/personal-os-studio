import Foundation

/// Machine-local eval history: definitions are portable canonical content, but
/// measurements describe THIS machine's runs — they live under Application Support
/// (700) and never enter the repo. One JSON file per harness.
struct EvalStore {

    struct CaseResult: Codable, Equatable {
        let name: String
        let verdict: String     // pass / fail / partial
        let reason: String
        let source: String
    }

    struct RunRecord: Codable {
        let date: Date
        let harness: String
        let results: [CaseResult]
        /// artifact relativePath → provenance version at run time.
        let sourceVersions: [String: String]

        var passCount: Int { results.filter { $0.verdict == "pass" }.count }
    }

    /// Injectable for tests; the app uses `.standard`.
    let baseDir: URL

    static let standard = EvalStore(
        baseDir: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PersonalOSStudio/evals"))

    func append(_ run: RunRecord) {
        var runs = history(harness: run.harness)
        runs.insert(run, at: 0)
        let fm = FileManager.default
        try? fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: baseDir.path)
        if let data = try? JSONEncoder().encode(Array(runs.prefix(100))) {
            try? data.write(to: fileURL(harness: run.harness))
        }
    }

    /// Newest first.
    func history(harness: String) -> [RunRecord] {
        guard let data = try? Data(contentsOf: fileURL(harness: harness)),
              let runs = try? JSONDecoder().decode([RunRecord].self, from: data)
        else { return [] }
        return runs
    }

    /// Case names that passed in `previous` but not in `latest` — the regressions.
    static func regressions(latest: RunRecord, previous: RunRecord) -> [String] {
        let passedBefore = Set(previous.results.filter { $0.verdict == "pass" }.map(\.name))
        return latest.results
            .filter { $0.verdict != "pass" && passedBefore.contains($0.name) }
            .map(\.name)
            .sorted()
    }

    private func fileURL(harness: String) -> URL {
        baseDir.appendingPathComponent("evals-\(harness).json")
    }
}
