/// The one call that actually installs a font, and the check that it worked.
///
/// ── WHY THIS REGISTERS FROM A FILE AND NOT FROM MEMORY ──────────────────────
///
/// There are two runtime registration paths on Apple platforms and they are
/// not equivalent.
///
/// `CTFontManagerRegisterGraphicsFont` takes a `CGFont` built from bytes. It
/// is what every tutorial reaches for, it works, and it is deprecated as of
/// macOS 15.
///
/// `CTFontManagerRegisterFontsForURL` takes a file on disk. It is current
/// everywhere, carries no deprecation on any platform, and is what this
/// package uses. Measured 2026-08-05: registers, resolves by PostScript name,
/// and the face stays reachable afterwards.
///
/// The third option — `CTFontManagerCreateFontDescriptorsFromData` plus
/// `CTFontManagerRegisterFontDescriptors`, which is what the deprecation
/// notice suggests — was tried and does not do this job: at `.process` scope
/// with descriptors built from in-memory data it reports
/// `CTFontManagerErrorDomain` code 303 and registers nothing, so every
/// subsequent lookup falls through to Helvetica. That is recorded here because
/// following the deprecation notice looks like the responsible move and
/// silently breaks every custom font in the app.
///
/// Needing a file is not a cost here. The bytes are already being written to a
/// cache so the second launch does not repeat the first launch's downloads,
/// and a font that lives on disk is one the next launch can register without a
/// network at all.
///
/// ── AND THE CHECK ───────────────────────────────────────────────────────────
///
/// The name a face registers under is the name baked into the file, so this
/// verifies rather than assumes. If a downloaded file's PostScript name is not
/// the one the brand advertised, every later lookup misses and nothing says
/// why. Catching it at registration is the only moment where the answer is
/// still cheap.

import CoreGraphics
import CoreText
import Foundation

public enum FontRegistrationError: Error, CustomStringConvertible {
    /// The bytes are not a font Core Graphics can open.
    case unreadable

    /// The bytes could not be staged to disk for registration.
    case notWritable(String)

    /// Core Text refused the registration.
    case refused(String)

    /// The file registered, but under a different name than the brand
    /// advertised, so nothing would ever find it.
    case nameMismatch(expected: String, actual: String)

    public var description: String {
        switch self {
        case .unreadable:
            return "the downloaded bytes are not a font file Core Graphics can open"
        case let .notWritable(why):
            return "the font could not be written to disk for registration: \(why)"
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
    /// Where staged font files live for the lifetime of the process.
    ///
    /// Kept rather than deleted after registration. Core Text resolves a
    /// deleted file's face in the moment — it has what it needs already — but
    /// glyph data is loaded lazily, and betting an app's typography on when
    /// that happens is not a bet worth taking for the sake of one file in a
    /// temp directory the system reclaims anyway.
    static let stagingDirectory: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("designless-fonts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// The default registrar for `FontStaging`.
    ///
    /// Returns only once Core Text can resolve the face, which is what makes
    /// the ordering rule hold on this platform.
    @Sendable
    public static func register(_ postscriptName: String, _ bytes: Data) throws {
        // Read the name out of the bytes before anything is written, so a file
        // that disagrees with the brand never reaches disk or Core Text.
        guard let provider = CGDataProvider(data: bytes as CFData),
              let font = CGFont(provider)
        else {
            throw FontRegistrationError.unreadable
        }

        let actual = (font.postScriptName as String?) ?? ""
        guard actual == postscriptName else {
            throw FontRegistrationError.nameMismatch(expected: postscriptName, actual: actual)
        }

        let file = stagingDirectory.appendingPathComponent("\(postscriptName).font")
        do {
            try bytes.write(to: file, options: .atomic)
        } catch {
            throw FontRegistrationError.notWritable("\(error)")
        }

        var error: Unmanaged<CFError>?
        guard CTFontManagerRegisterFontsForURL(file as CFURL, .process, &error) else {
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
