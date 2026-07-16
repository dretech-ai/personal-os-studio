import Foundation

/// Tiny semver (x.y.z) parse / bump / compare — the deterministic backbone of the
/// refine flow's version guardrail (never trust a model with version math).
struct SemVer: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ string: String) {
        let parts = string.trimmingCharacters(in: .whitespaces).components(separatedBy: ".")
        guard parts.count == 3,
              let a = Int(parts[0]), let b = Int(parts[1]), let c = Int(parts[2]),
              a >= 0, b >= 0, c >= 0 else { return nil }
        major = a; minor = b; patch = c
    }

    init(major: Int, minor: Int, patch: Int) {
        self.major = major; self.minor = minor; self.patch = patch
    }

    var bumpedMinor: SemVer { SemVer(major: major, minor: minor + 1, patch: 0) }
    var bumpedPatch: SemVer { SemVer(major: major, minor: minor, patch: patch + 1) }

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (a: SemVer, b: SemVer) -> Bool {
        if a.major != b.major { return a.major < b.major }
        if a.minor != b.minor { return a.minor < b.minor }
        return a.patch < b.patch
    }
}
