/// Which font file to fetch, and what to call it once it is registered.
///
/// ── THE RULE THIS FILE EXISTS FOR ───────────────────────────────────────────
///
/// A registered face is reached by its PostScript name, never by its family
/// name — and the reason is not that the family name fails. It is worse than
/// that: it succeeds, at the wrong weight, every time.
///
/// Measured on macOS 26 with both Inter faces registered
/// (`CoreTextRegistrarTests` runs this against the real font manager):
///
///     ask "Inter"           -> Inter-Regular
///     ask "Inter-Regular"   -> Inter-Regular
///     ask "Inter-SemiBold"  -> Inter-SemiBold
///
/// `UIFont(name:size:)`, `Font.custom(_:size:)` and `CTFontCreateWithName` all
/// take a name and no weight. Ask for `Inter` because your heading wants
/// SemiBold and you get Regular: a real font, correctly rendered, quietly the
/// wrong one. Nothing returns nil, nothing throws, and the only tell is that
/// the headings look light.
///
/// (A `CTFontDescriptor` carrying a family plus a weight trait does select
/// correctly. That is a different API from the ones almost every call site
/// uses, and it needs a weight in Core Text's -1...1 scale rather than the
/// brand's 100...900, so it is a second conversion to get wrong.)
///
/// So this package treats `postscriptName` as the identity of a face and the
/// family name as a label for humans.

import Foundation

/// Upright or italic. The wire carries these two and nothing else.
public enum FaceStyle: String, Sendable, Codable {
    case normal
    case italic
}

/// One file: one weight, one style, one name to reach it by.
public struct FontFace: Sendable, Equatable {
    /// The family this face belongs to. A label, not an identity.
    public let family: String
    public let weight: Int
    public let style: FaceStyle

    /// What Core Text will know this face as once it is registered. The only
    /// string that reaches a face.
    public let postscriptName: String

    /// Format to url. `ttf` for Apple platforms, `woff2` for the web.
    public let sources: [String: String]

    public func source(for format: String) -> String? { sources[format] }
}

/// A family, and the roles the brand fills with it.
public struct FontFamily: Sendable, Equatable {
    public let name: String

    /// `body`, `display`, `mono`. A family with no roles is published but
    /// unused, which is legal.
    public let roles: [String]
    public let faces: [FontFace]

    /// The distinct weights and styles this family publishes, as a sentence a
    /// person reads in a console at the moment something looks wrong.
    var publishedWeights: String {
        let items = Set(faces.map { $0.style == .italic ? "\($0.weight) italic" : "\($0.weight)" })
        return FontManifest.sentence(Array(items).sorted())
    }
}

/// The whole font list for a brand.
public struct FontManifest: Sendable, Equatable {
    public let families: [FontFamily]

    /// The format to download on a platform that registers files. `ttf` today.
    public let nativeFormat: String

    /// The format a browser wants. `woff2` today.
    public let webFormat: String

    /// An empty list is a real answer, not an error: a brand may publish no
    /// downloadable face and expect the platform's own type.
    public static let empty = FontManifest(families: [], nativeFormat: "ttf", webFormat: "woff2")

    public init(families: [FontFamily], nativeFormat: String, webFormat: String) {
        self.families = families
        self.nativeFormat = nativeFormat
        self.webFormat = webFormat
    }

    public static func parse(_ data: Data) throws -> FontManifest {
        guard let doc = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PayloadError.notAnObject
        }
        return fromJSON(doc)
    }

    public static func fromJSON(_ doc: [String: Any]) -> FontManifest {
        let formats = doc["formats"] as? [String: Any] ?? [:]
        var families: [FontFamily] = []

        for case let raw as [String: Any] in doc["families"] as? [Any] ?? [] {
            guard let family = raw["family"] as? String, !family.isEmpty else { continue }

            var faces: [FontFace] = []
            for case let rf as [String: Any] in raw["faces"] as? [Any] ?? [] {
                // A face with no PostScript name cannot be reached once
                // registered, so it is dropped rather than carried as
                // something that looks usable. Registering it would cost the
                // download and give nothing back.
                guard let ps = rf["postscriptName"] as? String, !ps.isEmpty else { continue }

                var src: [String: String] = [:]
                for (k, v) in rf["src"] as? [String: Any] ?? [:] {
                    if let s = v as? String, !s.isEmpty { src[k] = s }
                }
                guard !src.isEmpty else { continue }

                let weight: Int
                switch rf["weight"] {
                case let n as Int: weight = n
                case let s as String: weight = Int(s) ?? 400
                default: weight = 400
                }

                faces.append(FontFace(
                    family: family,
                    weight: weight,
                    style: (rf["style"] as? String) == "italic" ? .italic : .normal,
                    postscriptName: ps,
                    sources: src
                ))
            }
            guard !faces.isEmpty else { continue }

            families.append(FontFamily(
                name: family,
                roles: (raw["roles"] as? [Any] ?? []).compactMap { $0 as? String },
                faces: faces
            ))
        }

        return FontManifest(
            families: families,
            nativeFormat: formats["native"] as? String ?? "ttf",
            webFormat: formats["web"] as? String ?? "woff2"
        )
    }

    public var isEmpty: Bool { families.isEmpty }

    /// The roles this brand publishes a family for, in the order they appear.
    ///
    /// Named so a diagnostic can say which roles exist rather than only which
    /// one was asked for. A role the brand skipped and a role the caller
    /// misspelled are the same event at the point it happens, and the second
    /// is the common one.
    public var publishedRoles: [String] { families.flatMap(\.roles) }

    public var allFaces: [FontFace] { families.flatMap(\.faces) }

    public func family(forRole role: String) -> FontFamily? {
        families.first { $0.roles.contains(role) }
    }

    /// How far from an asked-for weight a face may sit and still be used.
    ///
    /// Without a limit a family with one heavy face answers every request with
    /// it and body copy renders bold. Two rungs is close enough to read as the
    /// same voice; anything further is reported rather than substituted.
    public static let maxWeightGap = 200

    /// The best face for a role at a weight and style, or nil when nothing is
    /// close enough. Ties go to the heavier face: at equal distance, the
    /// bolder of two is what a caller asking for emphasis meant.
    public func face(forRole role: String, weight: Int = 400, style: FaceStyle = .normal) -> FontFace? {
        guard let family = family(forRole: role) else { return nil }
        return Self.closest(family.faces, weight, style)
            ?? Self.closest(family.faces, weight, style == .normal ? .italic : .normal)
    }

    static func closest(_ faces: [FontFace], _ weight: Int, _ style: FaceStyle) -> FontFace? {
        var best: FontFace?
        var bestGap = Int.max
        for f in faces where f.style == style {
            let gap = abs(f.weight - weight)
            if gap > maxWeightGap { continue }
            if gap < bestGap || (gap == bestGap && (best.map { f.weight > $0.weight } ?? false)) {
                best = f
                bestGap = gap
            }
        }
        return best
    }

    /// `"a"`, `"a" and "b"`, `"a", "b" and "c"` — a sentence, because these
    /// strings are read by a person at the moment something looks wrong.
    static func sentence(_ items: [String]) -> String {
        switch items.count {
        case 0: return "none"
        case 1: return "\"\(items[0])\""
        default:
            let quoted = items.map { "\"\($0)\"" }
            return quoted.dropLast().joined(separator: ", ") + " and " + quoted.last!
        }
    }
}

/// What happened when a role was asked for a face, and why.
///
/// Every way of ending up in the system font gets its own value, because what
/// to do about each differs: one is a build to fix, one is a request to retry,
/// one is the brand getting exactly what it published.
public enum FaceOutcome: Sendable, Equatable {
    /// A face was found and Core Text can reach it. The only outcome that puts
    /// the brand's type on the screen.
    case resolved

    /// A face was found, but not the weight or style asked for. Reported
    /// rather than passed over: a family publishing only Light answering a
    /// request for Medium looks exactly like a font that was applied.
    case substituted

    /// The font list has not been read yet. A fetch to retry, not a build to fix.
    case notLoaded

    /// The brand publishes no family for this role. Not a fault on its own,
    /// but indistinguishable at this moment from a misspelled role, so the
    /// roles that do exist are named.
    case unpublished

    /// The family is published but nothing it carries is near this weight.
    case tooFar

    /// A face exists and its file is not registered, so Core Text cannot reach
    /// it. The one outcome that is always a build to fix.
    case notRegistered
}

/// The answer to "what face fills this role", with the reason attached.
public struct FaceResolution: Sendable, Equatable {
    public let outcome: FaceOutcome

    /// The face to use. Nil unless the outcome is `.resolved` or `.substituted`.
    public let face: FontFace?

    /// One sentence a developer can act on. Nil when there is nothing to say.
    public let detail: String?

    init(_ outcome: FaceOutcome, face: FontFace? = nil, detail: String? = nil) {
        self.outcome = outcome
        self.face = face
        self.detail = detail
    }

    /// The name to hand `UIFont(name:size:)`, or nil when there is none.
    public var postscriptName: String? { face?.postscriptName }

    public var isUsable: Bool { face != nil }
}

public enum PayloadError: Error, Equatable {
    case notAnObject
}
