import Foundation

/// `spacetile://activate?key=…`, the one-click link in Licence emails. The app registers the
/// `spacetile` URL scheme (scripts/bundle.sh) and stores the key the link carries.
public enum ActivationLink {
    /// The Licence key text in an activation link, unverified. Nil for any other URL.
    public static func key(in url: URL) -> String? {
        guard url.scheme?.lowercased() == "spacetile", url.host()?.lowercased() == "activate",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let key = items.first(where: { $0.name == "key" })?.value,
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return key
    }
}
