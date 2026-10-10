import Foundation

/// The revoked Licences a build refuses. Release builds carry the licence service's list as
/// `Revocations.json` in the bundle (scripts/bundle.sh --revocations): `{"revoked": ["lic_…", …]}`.
public enum Revocations {
    /// The Licence IDs in the list `json`, or nil when it isn't one.
    public static func licenceIDs(in json: Data) -> Set<String>? {
        try? Set(JSONDecoder().decode(List.self, from: json).revoked)
    }

    private struct List: Decodable {
        let revoked: [String]
    }
}
