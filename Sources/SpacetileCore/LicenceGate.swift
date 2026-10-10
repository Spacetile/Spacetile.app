/// Which builds have the Trial and the Licence check. Releases numbered below 1.0.0, the free
/// public beta and its Nightlies, don't: their users' Trial starts when they first run 1.0 or a
/// later version, so the beta doesn't count against it. Every release from 1.0.0 on has it, its
/// Betas and Nightlies included, and so does every local build. `bundle.sh --dev` builds compile
/// it out before this is asked.
public enum LicenceGate {
    /// Whether a build has the check. `version` is its CFBundleShortVersionString; `released`
    /// says whether the release pipeline made it, so carries a release date. Local builds aren't
    /// judged by version, as theirs is only a default. A release whose version doesn't start with
    /// a whole major number has the check.
    public static func applies(toVersion version: String?, released: Bool) -> Bool {
        guard released, let major = version?.split(separator: ".", omittingEmptySubsequences: false).first.flatMap({ Int($0) })
        else { return true }
        return major >= 1
    }
}
