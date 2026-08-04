/// Getting the faces into Core Text before anything asks for them.
///
/// ── THE MOST DAMAGING MISTAKE AVAILABLE ON THIS PLATFORM ────────────────────
///
/// The order is: download, cache, register, and only then resolve a font.
/// Render before registration completes and `UIFont(name:size:)` returns nil,
/// the call site falls back to the system font, and the label keeps it — a
/// `UILabel` that has already sized itself does not re-lay-out because a font
/// arrived afterwards. The screen looks plausible. Nothing throws.
///
/// So this type does not offer a "register these" call a caller can forget to
/// await. It owns the ordering: a face comes out only after its file is
/// registered, and `.notRegistered` comes out before then. Getting the order
/// wrong means ignoring a returned value rather than forgetting a step.
///
/// The registration itself is injected. `CTFontManagerRegisterGraphicsFont` is
/// the real one and is supplied by default; a test passes its own and needs no
/// font bytes at all.

import Foundation

/// Fetch the bytes at `url`. Injected so this package needs no HTTP
/// dependency and can be driven by a test with no network.
public typealias FetchBytes = @Sendable (URL) async throws -> Data

/// Install a face into the platform under `postscriptName`.
///
/// Must return only once Core Text can actually resolve that name. A
/// registrar that returns early reintroduces exactly the race this type exists
/// to remove.
public typealias RegisterFace = @Sendable (String, Data) throws -> Void

/// Somewhere to keep a downloaded file between launches, so the second launch
/// does not repeat the first launch's downloads.
public protocol FontCache: Sendable {
    func read(_ key: String) -> Data?
    func write(_ key: String, _ bytes: Data)
}

/// What a staging run did, for a caller that wants to report it.
public struct StagingReport: Sendable, Equatable {
    /// PostScript names Core Text can now resolve.
    public let registered: [String]

    /// PostScript name to the reason it did not land. A face here is not a
    /// crash: the role it filled falls back to the system font, and `resolve`
    /// says so rather than pretending.
    public let failed: [String: String]

    /// How many faces came from the cache rather than the network.
    public let fromCache: Int

    public var isComplete: Bool { failed.isEmpty }
    public var total: Int { registered.count + failed.count }
}

/// Downloads, caches and registers the faces a brand publishes, and answers
/// which of them Core Text can actually reach.
public actor FontStaging {
    private let fetch: FetchBytes
    private let register: RegisterFace
    private let cache: FontCache?
    private let format: String?

    private var manifest: FontManifest?
    private var staged: Set<String> = []
    private var failures: [String: String] = [:]
    private var inFlight: Task<StagingReport, Never>?

    public init(
        fetch: @escaping FetchBytes,
        register: @escaping RegisterFace = CoreTextRegistrar.register,
        cache: FontCache? = nil,
        format: String? = nil
    ) {
        self.fetch = fetch
        self.register = register
        self.cache = cache
        self.format = format
    }

    /// PostScript names Core Text can resolve right now.
    public var stagedNames: Set<String> { staged }

    /// Take a font list and stage everything in it.
    ///
    /// Idempotent: a face already staged is not fetched twice, and two
    /// concurrent calls share one run rather than racing to register the same
    /// name. Core Text refuses a duplicate registration, so the race is not
    /// theoretical.
    @discardableResult
    public func stage(_ manifest: FontManifest) async -> StagingReport {
        self.manifest = manifest
        if let inFlight { return await inFlight.value }

        let task = Task<StagingReport, Never> { [self] in
            await run(manifest)
        }
        inFlight = task
        let report = await task.value
        inFlight = nil
        return report
    }

    private func run(_ manifest: FontManifest) async -> StagingReport {
        let wanted = format ?? manifest.nativeFormat
        var registered: [String] = []
        var fromCache = 0

        for face in manifest.allFaces {
            if staged.contains(face.postscriptName) {
                registered.append(face.postscriptName)
                continue
            }

            guard let source = face.source(for: wanted), let url = URL(string: source) else {
                failures[face.postscriptName] =
                    "the brand publishes no \(wanted) file for this face"
                continue
            }

            do {
                let key = "\(face.postscriptName).\(wanted)"
                let bytes: Data
                if let cached = cache?.read(key) {
                    bytes = cached
                    fromCache += 1
                } else {
                    bytes = try await fetch(url)
                    // Written after a successful fetch and before
                    // registration, so a launch that dies mid-registration
                    // still has the file next time.
                    cache?.write(key, bytes)
                }

                // The ordering, in one place. Nothing below this line runs
                // until Core Text reports the face installed.
                try register(face.postscriptName, bytes)

                staged.insert(face.postscriptName)
                failures[face.postscriptName] = nil
                registered.append(face.postscriptName)
            } catch {
                // One face failing is not the run failing. The role it filled
                // falls back to the system font and `resolve` reports why.
                failures[face.postscriptName] = "\(error)"
            }
        }

        return StagingReport(registered: registered, failed: failures, fromCache: fromCache)
    }

    /// What fills `role` at this weight and style, and whether Core Text can
    /// reach it.
    ///
    /// The only way to get a face out of this type, and it will not hand back
    /// one whose file is not registered. That is the ordering rule expressed
    /// as a return value rather than as advice in a README.
    public func resolve(
        _ role: String,
        weight: Int = 400,
        style: FaceStyle = .normal
    ) -> FaceResolution {
        guard let manifest else {
            return FaceResolution(.notLoaded, detail: """
                The font list has not been read yet, so no face can be \
                resolved. This is a fetch to retry, not a build to fix.
                """)
        }

        guard let family = manifest.family(forRole: role) else {
            let published = manifest.publishedRoles
            return FaceResolution(.unpublished, detail: published.isEmpty
                ? """
                  This brand publishes no font faces at all, so every role uses \
                  the system font.
                  """
                : """
                  This brand publishes no face for the "\(role)" role, so that \
                  text uses the system font. The roles it does publish are \
                  \(FontManifest.sentence(published)). If one of those is the \
                  one you meant, the name is the fix.
                  """)
        }

        guard let face = manifest.face(forRole: role, weight: weight, style: style) else {
            return FaceResolution(.tooFar, detail: """
                The "\(role)" role uses "\(family.name)", which publishes \
                \(family.publishedWeights) and nothing within \
                \(FontManifest.maxWeightGap) of \(weight). That text uses the \
                system font rather than a face too far from what you asked for.
                """)
        }

        guard staged.contains(face.postscriptName) else {
            if let why = failures[face.postscriptName] {
                return FaceResolution(.notRegistered, detail: """
                    The face "\(face.postscriptName)" could not be registered: \
                    \(why). The "\(role)" role uses the system font.
                    """)
            }
            return FaceResolution(.notRegistered, detail: """
                The face "\(face.postscriptName)" has not been registered yet, \
                so Core Text cannot reach it. Await stage() before building a \
                font: a label laid out before its font lands keeps the system \
                font for the life of that view.
                """)
        }

        if face.weight != weight || face.style != style {
            return FaceResolution(.substituted, face: face, detail: """
                The "\(role)" role was asked for weight \(weight) \(style.rawValue) \
                and "\(family.name)" publishes \(family.publishedWeights), so \
                "\(face.postscriptName)" is being used. It is not thickened, \
                thinned or slanted to match.
                """)
        }

        return FaceResolution(.resolved, face: face)
    }
}
