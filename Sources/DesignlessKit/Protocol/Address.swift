/// Where to ask for a thing.
///
/// Every address this package builds comes from here, and every one honours
/// the grammar the surface publishes at `/serve/protocol.v1.json` rather than
/// being assembled at the call site. A parameter sent to an address that does
/// not take it is not harmless: the surface answers 400 on a value it refuses,
/// and one that is silently dropped is worse, because the caller believes it
/// asked for something it did not get.

import Foundation

/// The published appearance values.
public enum Appearance: String, Sendable, CaseIterable {
    case light
    case dark
}

/// The published platform values.
///
/// `web` is what the surface applies when the parameter is absent, so asking
/// for it and leaving it off give the same payload.
public enum ServePlatform: String, Sendable, CaseIterable {
    case web
    case ios
    case android
}

/// The published asset formats.
public enum AssetFormat: String, Sendable, CaseIterable {
    case svg
    case png
}

/// The closed size ladder for a raster asset.
///
/// A value off this ladder is a 400, not a resize: the surface renders at the
/// sizes it has decided are legible and refuses the rest. Modelled as an enum
/// so a caller cannot express the request that fails.
public enum AssetSize: Int, Sendable, CaseIterable {
    case px16 = 16
    case px32 = 32
    case px48 = 48
    case px64 = 64
    case px128 = 128
    case px192 = 192
    case px256 = 256
    case px512 = 512
    case px1024 = 1024

    /// The nearest published size at or above `wanted`, or the largest there is.
    ///
    /// Rounds up rather than down: a mark drawn larger than its box and scaled
    /// down stays sharp, and one drawn smaller and scaled up does not.
    public static func atLeast(_ wanted: Int) -> AssetSize {
        AssetSize.allCases.first { $0.rawValue >= wanted } ?? .px1024
    }
}

/// What went wrong building an address, before anything was sent.
public enum AddressError: Error, Equatable, CustomStringConvertible {
    /// A size was asked for on a vector, which has no size to pick.
    case sizeOnVector

    public var description: String {
        switch self {
        case .sizeOnVector:
            return """
            An svg has no size to pick. Ask for .png to use the ladder, or \
            drop the size and let the vector scale.
            """
        }
    }
}

/// A brand's address space. Holds no state and makes no requests.
public struct ServeAddresses: Sendable, Equatable {
    /// Where the brand path lives. Overridable for a proxy or a test double,
    /// not for pointing at a different product.
    public static let defaultOrigin = "https://cdn.designless.app"

    public let publicID: String
    public let origin: String

    public init(publicID: String, origin: String = ServeAddresses.defaultOrigin) {
        self.publicID = publicID
        self.origin = origin
    }

    private var base: String { "\(origin)/r/\(publicID)" }

    /// What this brand offers and where. The document a client reads first.
    public func context(version: String? = nil) -> URL {
        build("context.json", [:], version)
    }

    /// Resolved token values, for mapping onto a platform theme.
    public func tokens(
        appearance: Appearance? = nil,
        platform: ServePlatform? = nil,
        version: String? = nil
    ) -> URL {
        var q: [String: String] = [:]
        if let appearance { q["appearance"] = appearance.rawValue }
        if let platform { q["platform"] = platform.rawValue }
        return build("tokens.json", q, version)
    }

    /// The font files to download and register.
    public func fonts(version: String? = nil) -> URL {
        build("fonts.json", [:], version)
    }

    /// The stream that signals when this brand changes.
    ///
    /// Takes no version: pinning a stream to a past version would mean
    /// subscribing to something that can no longer change.
    public func events() -> URL {
        URL(string: "\(base)/events")!
    }

    /// A mark, by the role it fills.
    ///
    /// Throws rather than sending a request the surface will refuse. A 400
    /// from a CDN reaches a caller as a blank image view with no explanation
    /// attached; this is the same refusal, close enough to the mistake to name
    /// it.
    public func asset(
        _ role: String,
        format: AssetFormat = .svg,
        appearance: Appearance? = nil,
        size: AssetSize? = nil
    ) throws -> URL {
        if size != nil, format == .svg { throw AddressError.sizeOnVector }
        var q: [String: String] = [:]
        if let appearance { q["appearance"] = appearance.rawValue }
        if let size { q["size"] = String(size.rawValue) }
        return build("assets/\(role).\(format.rawValue)", q, nil)
    }

    /// A composed destination — an app icon, a social card — by its name.
    ///
    /// These carry their own geometry, so they take neither a size nor an
    /// appearance: the destination decides both, and passing either would be
    /// asking a question the address does not answer.
    public func composition(_ name: String, format: AssetFormat = .png) -> URL {
        build("assets/\(name).\(format.rawValue)", [:], nil)
    }

    private func build(_ file: String, _ params: [String: String], _ version: String?) -> URL {
        var q = params
        if let version { q["version"] = version }
        var components = URLComponents(string: "\(base)/\(file)")!
        if !q.isEmpty {
            // Sorted so the same request is the same string every time, which
            // matters for cache keys and for a test that compares URLs.
            components.queryItems = q.sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url!
    }
}
