/// The documents a brand serves, as things a Swift program can hold.
///
/// These keep the payload rather than flattening it into named properties. A
/// brand can add a token branch without this package shipping a release, and a
/// client reading `tokens.color("brand.primary")` keeps working when it does.
/// Naming every branch here would turn every brand-side addition into an SDK
/// upgrade, which is the opposite of the point.

import Foundation

/// The resolved token values for one brand, at one appearance and platform.
public struct BrandTokens: Sendable {
    private let tree: [String: JSONValue]

    /// The published version these values came from. `"1.0.3"`.
    public let version: String

    /// The appearance the surface resolved to.
    ///
    /// What the *payload* says, not what the app is currently showing. Those
    /// differ for as long as a fetch is in flight, and conflating them is how
    /// a light mark ends up on a dark screen.
    public let appearance: String?

    init(version: String, appearance: String?, tree: [String: JSONValue]) {
        self.version = version
        self.appearance = appearance
        self.tree = tree
    }

    public static func parse(_ data: Data) throws -> BrandTokens {
        guard let doc = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PayloadError.notAnObject
        }
        return fromJSON(doc)
    }

    public static func fromJSON(_ doc: [String: Any]) -> BrandTokens {
        BrandTokens(
            version: doc["version"] as? String ?? "",
            appearance: doc["appearance"] as? String,
            tree: (doc["tokens"] as? [String: Any] ?? [:]).mapValues(JSONValue.from)
        )
    }

    /// A value by dotted path: `color.bg.page`, `typography.fontSize.md`.
    ///
    /// Nil rather than a throw. A missing token is an ordinary state — brands
    /// differ in what they publish — and a client asking for one it did not
    /// get should fall back, not crash a screen.
    public subscript(path: String) -> JSONValue? {
        var node: JSONValue? = .object(tree)
        for segment in path.split(separator: ".") {
            guard let object = node?.objectValue else { return nil }
            node = object[String(segment)]
        }
        // A branch is not a value. Returning one would let a caller print a
        // dictionary where it expected a colour.
        return (node?.isBranch ?? true) ? nil : node
    }

    public func string(_ path: String) -> String? { self[path]?.stringValue }

    /// A colour as the `#rrggbb` string the brand published.
    ///
    /// Deliberately not parsed into a `UIColor` here: this file is
    /// Foundation-only so it builds on every platform, and inventing a colour
    /// type would put a second opinion between the brand and the screen.
    public func color(_ path: String) -> String? { string("color.\(path)") }

    public func number(_ path: String) -> Double? { self[path]?.doubleValue }

    /// A `rem` length in points, given the root size the platform uses.
    ///
    /// `rem` is a web unit and it reaches native as one, because the token
    /// tree is one document for every platform. 16 is the browser default and
    /// the right default here.
    public func length(_ path: String, rootPoints: Double = 16) -> Double? {
        guard let raw = string(path)?.trimmingCharacters(in: .whitespaces) else { return nil }
        if raw.hasSuffix("rem") {
            return Double(raw.dropLast(3)).map { $0 * rootPoints }
        }
        if raw.hasSuffix("px") {
            return Double(raw.dropLast(2))
        }
        return Double(raw)
    }

    /// The branch at `path`, for a caller walking a subtree it does not know
    /// the shape of. Empty rather than nil.
    public func branch(_ path: String) -> [String: JSONValue] {
        var node: JSONValue? = .object(tree)
        for segment in path.split(separator: ".") {
            guard let object = node?.objectValue else { return [:] }
            node = object[String(segment)]
        }
        return node?.objectValue ?? [:]
    }

    /// The top-level branch names this brand published.
    public var branches: [String] { Array(tree.keys) }
}

/// One thing a brand offers.
public struct ServeCapability: Sendable, Equatable {
    public let name: String

    /// `none` or `api-key`.
    public let auth: String
    public let description: String
}

/// An addressable mark.
public struct ServeAsset: Sendable, Equatable {
    public let role: String
    public let formats: [String]

    /// The appearances this mark has artwork for.
    public let variants: [String]
    public let url: String
}

/// A composed destination, with its geometry.
public struct ServeComposition: Sendable, Equatable {
    public let name: String
    public let url: String
    public let width: Int
    public let height: Int

    /// One sentence on why this destination looks the way it does. Written for
    /// a person deciding whether it is the one they want.
    public let rationale: String
}

/// What a brand offers, per brand, resolved. The document a client reads first.
public struct BrandContext: Sendable, Equatable {
    public let publicID: String
    public let version: String
    public let capabilities: [ServeCapability]

    /// Named addresses: `tokens`, `fonts`, `events`, `styles`, `tree`.
    public let fetch: [String: String]
    public let assets: [ServeAsset]
    public let compositions: [ServeComposition]

    /// The appearances this brand resolves.
    public let appearances: [String]

    /// Filenames that are spoken for but do not answer yet. An address claim
    /// and nothing more: no auth, no verb, no promise that anything works.
    public let reserved: [String]

    public static func parse(_ data: Data) throws -> BrandContext {
        guard let doc = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PayloadError.notAnObject
        }
        return fromJSON(doc)
    }

    public static func fromJSON(_ doc: [String: Any]) -> BrandContext {
        var fetch: [String: String] = [:]
        for (key, value) in doc["fetch"] as? [String: Any] ?? [:] {
            if let entry = value as? [String: Any], let url = entry["url"] as? String {
                fetch[key] = url
            }
        }

        return BrandContext(
            publicID: doc["public_id"] as? String ?? "",
            version: doc["version"] as? String ?? "",
            capabilities: (doc["capabilities"] as? [Any] ?? []).compactMap {
                guard let c = $0 as? [String: Any], let name = c["name"] as? String else { return nil }
                return ServeCapability(
                    name: name,
                    auth: c["auth"] as? String ?? "none",
                    description: c["description"] as? String ?? ""
                )
            },
            fetch: fetch,
            assets: (doc["assets"] as? [Any] ?? []).compactMap {
                guard let a = $0 as? [String: Any], let role = a["role"] as? String else { return nil }
                return ServeAsset(
                    role: role,
                    formats: (a["formats"] as? [Any] ?? []).compactMap { $0 as? String },
                    variants: (a["variants"] as? [Any] ?? []).compactMap { $0 as? String },
                    url: a["url"] as? String ?? ""
                )
            },
            compositions: (doc["compositions"] as? [Any] ?? []).compactMap {
                guard let c = $0 as? [String: Any], let name = c["name"] as? String else { return nil }
                return ServeComposition(
                    name: name,
                    url: c["url"] as? String ?? "",
                    width: (c["width"] as? NSNumber)?.intValue ?? 0,
                    height: (c["height"] as? NSNumber)?.intValue ?? 0,
                    rationale: c["rationale"] as? String ?? ""
                )
            },
            appearances: (doc["appearance"] as? [Any] ?? []).compactMap { $0 as? String },
            reserved: (doc["reserved"] as? [Any] ?? []).compactMap { $0 as? String }
        )
    }

    /// Whether this brand offers `name`.
    ///
    /// Read this rather than assuming. The capability list is per-brand and
    /// resolved, so it is the difference between an address that answers for
    /// this brand and one that does not.
    public func offers(_ name: String) -> Bool {
        capabilities.contains { $0.name == name }
    }

    public func asset(forRole role: String) -> ServeAsset? {
        assets.first { $0.role == role }
    }

    public func composition(named name: String) -> ServeComposition? {
        compositions.first { $0.name == name }
    }
}
