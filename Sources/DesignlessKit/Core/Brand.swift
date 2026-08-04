/// The five verbs, and the rule about when a change is allowed to land.
///
/// ── FETCH THEN ACTIVATE, NOT FETCH THEN SWAP ────────────────────────────────
///
/// A brand can change while an app is open, and what an app must not do is
/// restyle itself underneath someone mid-task. On UIKit it largely cannot
/// anyway: `UIAppearance` is applied when a view is added to a window and does
/// not restyle views already on screen, so a mid-session swap gets you a
/// half-updated app rather than an updated one.
///
/// So a change arriving over the stream is fetched and held, and becomes live
/// when the caller says the moment is right — normally
/// `UIApplication.didBecomeActiveNotification`. `activate()` is that moment.
/// Until it is called, `tokens` keeps answering with what is on screen and
/// `pending` says something is waiting.

import Foundation

/// Fetch the body at `url`. Injected: this package has no HTTP dependency and
/// no opinion about the one an app already uses.
public typealias FetchData = @Sendable (URL) async throws -> Data

/// Somewhere to keep the last payload between launches, so a cold start shows
/// the brand rather than a blank screen while a request is in flight.
///
/// `UserDefaults` is the obvious implementation and is the reason this is
/// synchronous: a snapshot has to be readable before the first view is built,
/// and anything awaited has already lost that race.
public protocol SnapshotStore: Sendable {
    func read(_ key: String) -> Data?
    func write(_ key: String, _ value: Data)
}

/// What the brand is doing.
public enum BrandStatus: Sendable, Equatable {
    /// Nothing has been read yet, from disk or the network.
    case empty

    /// A persisted snapshot is showing while a fetch is in flight.
    case fromSnapshot

    /// Values fetched this session are live.
    case live

    /// The last fetch failed. Whatever was already live stays live.
    case stale
}

/// One brand, and everything a client asks of it.
public actor Brand {
    public let publicID: String
    public let addresses: ServeAddresses

    private let fetcher: FetchData
    private let store: SnapshotStore?

    /// The appearance to ask for, or nil to take the brand's own default.
    public var appearance: Appearance?

    /// The platform to resolve for. Defaults to `.ios`, which is the point of
    /// this package: the payload carries native font stacks, safe-area insets
    /// and a 44pt minimum touch target rather than their web equivalents.
    public var platform: ServePlatform

    private var liveTokens: BrandTokens?
    private var pendingTokens: BrandTokens?
    private var fontManifest: FontManifest?
    private var brandContext: BrandContext?
    private var currentStatus: BrandStatus = .empty

    private var observers: [UUID: @Sendable (BrandTokens) -> Void] = [:]

    public init(
        publicID: String,
        fetch: @escaping FetchData,
        store: SnapshotStore? = nil,
        origin: String = ServeAddresses.defaultOrigin,
        appearance: Appearance? = nil,
        platform: ServePlatform = .ios
    ) {
        self.publicID = publicID
        self.addresses = ServeAddresses(publicID: publicID, origin: origin)
        self.fetcher = fetch
        self.store = store
        self.appearance = appearance
        self.platform = platform

        if let raw = store?.read(Self.snapshotKey(publicID)),
           let restored = try? BrandTokens.parse(raw) {
            // A snapshot that does not parse is one from an older shape or a
            // half-written file. Neither is worth failing a launch over; the
            // fetch that follows replaces it.
            self.liveTokens = restored
            self.currentStatus = .fromSnapshot
        }
    }

    public var status: BrandStatus { currentStatus }

    /// The values a caller should be rendering with, or nil before anything
    /// has been read.
    public var tokens: BrandTokens? { liveTokens }

    /// The font list, or nil before it has been read.
    public var fonts: FontManifest? { fontManifest }

    /// What this brand offers, or nil before `context.json` has been read.
    public var context: BrandContext? { brandContext }

    /// A fetched payload waiting for `activate()`, or nil.
    ///
    /// Non-nil is the honest signal that the brand on screen is one publish
    /// behind. A caller can surface it, ignore it, or activate on the spot.
    public var pending: BrandTokens? { pendingTokens }

    /// The appearance the LIVE payload resolved to.
    ///
    /// Not the appearance that was asked for. Between asking and landing they
    /// differ, and every address this brand builds uses this one, so a mark
    /// and the screen it sits on cannot disagree about which appearance is
    /// showing.
    public var liveAppearance: String? { liveTokens?.appearance }

    // ── The five verbs ────────────────────────────────────────────────────

    /// Read the tokens and make them live.
    ///
    /// A persisted snapshot is already showing by the time this is awaited,
    /// because the initialiser restores one synchronously.
    public func initialize() async throws {
        try await refresh(activateNow: true)
    }

    /// Fetch the current payload and hold it until `activate()`, unless
    /// `activateNow` is set.
    public func refresh(activateNow: Bool = false) async throws {
        let url = addresses.tokens(appearance: appearance, platform: platform)
        do {
            let body = try await fetcher(url)
            let next = try BrandTokens.parse(body)

            if activateNow || liveTokens == nil {
                liveTokens = next
                pendingTokens = nil
                currentStatus = .live
                notify(next)
            } else {
                pendingTokens = next
            }

            // Written after parsing, so a malformed body never replaces a
            // snapshot that works.
            store?.write(Self.snapshotKey(publicID), body)
        } catch {
            // A failed fetch leaves whatever is live exactly as it is. An app
            // that was showing the brand goes on showing it.
            currentStatus = liveTokens == nil ? .empty : .stale
            throw error
        }
    }

    /// Promote a held payload to live, and tell observers.
    ///
    /// Call this when the app is in a state where restyling is acceptable —
    /// normally on `didBecomeActive`. Returns whether anything moved.
    @discardableResult
    public func activate() -> Bool {
        guard let next = pendingTokens else { return false }
        liveTokens = next
        pendingTokens = nil
        currentStatus = .live
        notify(next)
        return true
    }

    /// Read `fonts.json`. Separate from `initialize` because a caller that
    /// renders no text this launch should not pay for it.
    @discardableResult
    public func loadFonts() async throws -> FontManifest {
        let manifest = try FontManifest.parse(try await fetcher(addresses.fonts()))
        fontManifest = manifest
        return manifest
    }

    /// Read `context.json`.
    @discardableResult
    public func loadContext() async throws -> BrandContext {
        let context = try BrandContext.parse(try await fetcher(addresses.context()))
        brandContext = context
        return context
    }

    /// The address of a mark.
    ///
    /// Uses `liveAppearance` rather than the requested appearance, for the
    /// reason on that property.
    public func assetURL(
        _ role: String,
        format: AssetFormat = .png,
        size: AssetSize? = nil,
        appearance: Appearance? = nil
    ) throws -> URL {
        let resolved = appearance ?? Appearance(rawValue: liveAppearance ?? "") ?? self.appearance
        return try addresses.asset(role, format: format, appearance: resolved, size: size)
    }

    /// The address of a composed destination.
    public func compositionURL(_ name: String, format: AssetFormat = .png) -> URL {
        addresses.composition(name, format: format)
    }

    // ── Observing ─────────────────────────────────────────────────────────

    /// Called whenever what a caller would read has changed: after a fetch
    /// lands and is activated, and after `activate()` promotes a held payload.
    ///
    /// It does not fire when a payload arrives and is held. Nothing a caller
    /// can see changed at that moment, and waking every observer to say so is
    /// how a stream turns into a re-render storm.
    ///
    /// Returns a token; pass it to `removeObserver` to stop.
    @discardableResult
    public func observe(_ body: @escaping @Sendable (BrandTokens) -> Void) -> UUID {
        let id = UUID()
        observers[id] = body
        return id
    }

    public func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func notify(_ tokens: BrandTokens) {
        for observer in observers.values { observer(tokens) }
    }

    static func snapshotKey(_ publicID: String) -> String { "designless.\(publicID)" }
}

public extension Brand {
    /// Change the appearance to ask for on the next fetch.
    ///
    /// A setter rather than a mutable property because `Brand` is an actor:
    /// `brand.appearance = .light` from outside would be a cross-actor write,
    /// which Swift refuses. Nothing changes on screen until a payload for the
    /// new appearance lands and is activated, which is the whole point.
    func setAppearance(_ next: Appearance?) {
        appearance = next
    }

    /// Change the platform to resolve for.
    func setPlatform(_ next: ServePlatform) {
        platform = next
    }
}
