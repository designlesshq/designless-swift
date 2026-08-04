/// The one line that actually installs a font, and the check that it worked.
///
/// `CTFontManagerRegisterGraphicsFont` is the runtime registration path on
/// every Apple platform. It takes a `CGFont`, not bytes, and it reports
/// failure through a `CFError` out-parameter rather than by throwing — so the
/// easy way to write this is to ignore the return value and never find out.
///
/// The name a face registers under is the name baked into the file, which is
/// why this verifies rather than assumes: if the downloaded file's PostScript
/// name is not the one the brand advertised, every later lookup misses and
/// nothing says why. Catching it here turns a silent system-font substitution
/// into an error at the moment of registration, which is the only moment where
/// the answer is still cheap.

import CoreGraphics
import CoreText
import Foundation

public enum FontRegistrationError: Error, CustomStringConvertible {
    /// The bytes are not a font Core Graphics can open.
    case unreadable

    /// Core Text refused the registration.
    case refused(String)

    /// The file registered, but under a different name than the brand
    /// advertised, so nothing would ever find it.
    case nameMismatch(expected: String, actual: String)

    public var description: String {
        switch self {
        case .unreadable:
            return "the downloaded bytes are not a font file Core Graphics can open"
        case let .refused(why):
            return "Core Text refused the registration: \(why)"
        case let .nameMismatch(expected, actual):
            return """
            the file registered as "\(actual)" but the brand advertises \
            "\(expected)", so every lookup by the advertised name would miss
            """
        }
    }
}

/// Registers a face with Core Text under the name baked into the file.
public enum CoreTextRegistrar {
    /// The default registrar for `FontStaging`.
    ///
    /// Returns only once Core Text can resolve the face, which is what makes
    /// the ordering rule hold on this platform.
    @Sendable
    public static func register(_ postscriptName: String, _ bytes: Data) throws {
        guard let provider = CGDataProvider(data: bytes as CFData),
              let font = CGFont(provider)
        else {
            throw FontRegistrationError.unreadable
        }

        // What the file calls itself. This, not the argument, is what Core
        // Text will answer to.
        let actual = (font.postScriptName as String?) ?? ""
        guard actual == postscriptName else {
            throw FontRegistrationError.nameMismatch(expected: postscriptName, actual: actual)
        }

        // ── WHY THE DEPRECATED CALL ──────────────────────────────────────
        //
        // `CTFontManagerRegisterGraphicsFont` is deprecated on macOS 15+, and
        // the suggested replacement is
        // `CTFontManagerCreateFontDescriptorsFromData` +
        // `CTFontManagerRegisterFontDescriptors`. That replacement was tried
        // here and does not work for this job: at `.process` scope with
        // descriptors built from in-memory data it reports
        // CTFontManagerErrorDomain code 303 and registers nothing, so every
        // later lookup falls through to Helvetica. Measured, not assumed —
        // the whole CoreTextRegistrar suite went red on it.
        //
        // The deprecation is macOS-only; on iOS, tvOS and visionOS, which is
        // what this package is for, the call is current. Swapping a working
        // registration for a newer one that leaves the app in the system font
        // is exactly the trade this package exists to prevent, so it stays,
        // and this comment is here so nobody "modernises" it without running
        // the tests.
        var error: Unmanaged<CFError>?
        guard CTFontManagerRegisterGraphicsFont(font, &error) else {
            let why = error.map { String(describing: $0.takeRetainedValue()) } ?? "no reason given"
            // Already registered is success from a caller's point of view: the
            // face is reachable, which is the only thing being asked for. It
            // happens whenever two screens stage on the same launch, and
            // treating it as failure would report a working font as broken.
            if why.contains("already been registered") || why.contains("already registered") { return }
            throw FontRegistrationError.refused(why)
        }
    }
}
