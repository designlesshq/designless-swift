/// When a change is allowed to land, what a caller reads while it waits, and
/// what the discovery document is trusted for.

import XCTest
@testable import DesignlessKit

final class MemoryStore: SnapshotStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    private(set) var writes = 0

    init(_ value: Data? = nil) { self.value = value }

    func read(_ key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func write(_ key: String, _ data: Data) {
        lock.lock(); value = data; writes += 1; lock.unlock()
    }
}

/// Serves a named fixture, and can be repointed to simulate a republish.
final class FakeServer: @unchecked Sendable {
    private let lock = NSLock()
    private var body: String
    private var broken = false

    init(_ body: String) { self.body = body }

    func republish(_ next: String) { lock.lock(); body = next; lock.unlock() }
    func breakIt() { lock.lock(); broken = true; lock.unlock() }

    func fetch(_ url: URL) async throws -> Data {
        lock.lock(); let isBroken = broken; let current = body; lock.unlock()
        if isBroken { throw NSError(domain: "test", code: 1) }
        return Fixtures.data(current)
    }
}

final class BrandTests: XCTestCase {
    // ── A cold start ─────────────────────────────────────────────────────

    func testAPersistedSnapshotIsShowingBeforeAnythingIsAwaited() async {
        let brand = Brand(
            publicID: "_designless",
            fetch: FakeServer("tokens.dark.json").fetch,
            store: MemoryStore(Fixtures.data("tokens.dark.json"))
        )

        // No await between constructing and reading. That is the requirement:
        // a launch that waits on a round trip shows an unbranded first frame,
        // and that frame is the one a person judges the app by.
        let status = await brand.status
        let page = await brand.tokens?.color("bg.page")
        XCTAssertEqual(status, .fromSnapshot)
        XCTAssertEqual(page, "#060608")
    }

    func testASnapshotThatDoesNotParseIsDroppedRatherThanThrown() async {
        let brand = Brand(
            publicID: "_designless",
            fetch: FakeServer("tokens.dark.json").fetch,
            store: MemoryStore(Data("{ not json".utf8))
        )
        let status = await brand.status
        let tokens = await brand.tokens
        XCTAssertEqual(status, .empty)
        XCTAssertNil(tokens)
    }

    // ── Fetch then activate ──────────────────────────────────────────────

    func testARefreshHoldsTheNewPayloadInsteadOfSwappingIt() async throws {
        let server = FakeServer("tokens.dark.json")
        let brand = Brand(publicID: "_designless", fetch: server.fetch)
        try await brand.initialize()

        // The brand republishes while someone is reading the screen.
        server.republish("tokens.light.json")
        try await brand.refresh()

        let pending = await brand.pending
        let onScreen = await brand.tokens?.color("bg.page")
        XCTAssertNotNil(pending, "the new payload should be held")
        XCTAssertEqual(onScreen, "#060608", "what is on screen must not move until activate()")
    }

    func testActivatePromotesItOnceAndSaysWhetherItDid() async throws {
        let server = FakeServer("tokens.dark.json")
        let brand = Brand(publicID: "_designless", fetch: server.fetch)
        try await brand.initialize()
        server.republish("tokens.light.json")
        try await brand.refresh()

        let moved = await brand.activate()
        let appearance = await brand.tokens?.appearance
        let again = await brand.activate()

        XCTAssertTrue(moved)
        XCTAssertEqual(appearance, "light")
        XCTAssertFalse(again, "nothing left to promote")
    }

    func testObserversHearThePromotionAndNotTheArrival() async throws {
        let server = FakeServer("tokens.dark.json")
        let brand = Brand(publicID: "_designless", fetch: server.fetch)
        try await brand.initialize()

        let heard = Heard()
        await brand.observe { tokens in heard.append(tokens.appearance) }

        server.republish("tokens.light.json")
        try await brand.refresh()
        XCTAssertTrue(heard.values.isEmpty,
                      "nothing a caller can see changed when the payload arrived")

        await brand.activate()
        XCTAssertEqual(heard.values, ["light"])
    }

    func testTheFirstPayloadActivatesWhateverTheCallerAskedFor() async throws {
        // Holding the very first payload would leave the app with nothing to
        // render. "Do not restyle underneath someone" needs something to be
        // styled first.
        let brand = Brand(publicID: "_designless", fetch: FakeServer("tokens.dark.json").fetch)
        try await brand.refresh()
        let tokens = await brand.tokens
        let pending = await brand.pending
        XCTAssertNotNil(tokens)
        XCTAssertNil(pending)
    }

    // ── The address and the payload never disagree ───────────────────────

    func testAMarkUsesTheAppearanceThatIsLiveNotTheOneRequested() async throws {
        let server = FakeServer("tokens.dark.json")
        let brand = Brand(publicID: "_designless", fetch: server.fetch)
        try await brand.initialize()

        // Someone switches to light. The request goes out; nothing has landed.
        await brand.setAppearance(.light)
        let midFlight = try await brand.assetURL("logo-symbol")
        XCTAssertTrue(midFlight.query?.contains("appearance=dark") ?? false,
                      "a light mark on a screen still painted dark is the exact failure "
                      + "the appearance rule exists to prevent")

        server.republish("tokens.light.json")
        try await brand.refresh(activateNow: true)
        let landed = try await brand.assetURL("logo-symbol")
        XCTAssertTrue(landed.query?.contains("appearance=light") ?? false)
    }

    // ── A failed fetch ───────────────────────────────────────────────────

    func testAFailedFetchLeavesWhatIsLiveExactlyAsItWas() async throws {
        let server = FakeServer("tokens.dark.json")
        let brand = Brand(publicID: "_designless", fetch: server.fetch)
        try await brand.initialize()

        server.breakIt()
        do {
            try await brand.refresh()
            XCTFail("expected the fetch to throw")
        } catch {}

        let status = await brand.status
        let page = await brand.tokens?.color("bg.page")
        XCTAssertEqual(status, .stale)
        XCTAssertEqual(page, "#060608", "an app showing the brand goes on showing it")
    }

    func testAMalformedBodyNeverReplacesASnapshotThatWorks() async {
        let store = MemoryStore(Fixtures.data("tokens.dark.json"))
        let brand = Brand(
            publicID: "_designless",
            fetch: { _ in Data("not json at all".utf8) },
            store: store
        )
        do {
            try await brand.initialize()
            XCTFail("expected a parse failure")
        } catch {}
        XCTAssertEqual(store.writes, 0)
    }

    // ── Reading tokens ───────────────────────────────────────────────────

    func testReadingTokens() async throws {
        let brand = Brand(publicID: "_designless", fetch: FakeServer("tokens.dark.json").fetch)
        try await brand.initialize()
        let held = await brand.tokens
        let tokens = try XCTUnwrap(held)

        XCTAssertEqual(tokens.color("bg.page"), "#060608")
        XCTAssertTrue(tokens.string("typography.fontFamily.body")?.hasPrefix("Inter,") ?? false)

        XCTAssertNil(tokens["color.bg.nonesuch"], "a missing token is nil, not a crash")
        XCTAssertNil(tokens["color.bg"], "a branch is not a value")
        XCTAssertFalse(tokens.branch("color.bg").isEmpty)

        let md = try XCTUnwrap(tokens.string("typography.fontSize.md"))
        let rem = try XCTUnwrap(Double(md.replacingOccurrences(of: "rem", with: "")))
        XCTAssertEqual(try XCTUnwrap(tokens.length("typography.fontSize.md")), rem * 16, accuracy: 0.001)
        XCTAssertEqual(
            try XCTUnwrap(tokens.length("typography.fontSize.md", rootPoints: 10)),
            rem * 10, accuracy: 0.001
        )

        // The reason tokens are not flattened into named properties: a brand
        // adding a branch must not need an SDK release.
        XCTAssertTrue(tokens.branches.contains("color"))
        XCTAssertTrue(tokens.branches.contains("component"))
    }

    // ── The discovery document ───────────────────────────────────────────

    func testEveryCapabilityOfferedHasAnAddressInTheDocument() throws {
        // The client half of a guard that also exists on the server. A
        // capability is a promise that something works now, so the document
        // making the promise has to say where.
        //
        // This is the test that catches the failure it was written for:
        // `context.json` advertised a `compose` capability with
        // `auth: "api-key"` and no address anywhere in the document, while
        // POST answered 405 and GET answered 404. A client author reads the
        // capability list and builds against it.
        let context = try BrandContext.parse(Fixtures.data("context.json"))

        let addressed: [String: Bool] = [
            "tokens": context.fetch["tokens"] != nil,
            "assets": !context.assets.isEmpty || !context.compositions.isEmpty,
            "fonts": context.fetch["fonts"] != nil,
            "events": context.fetch["events"] != nil,
            "styles": context.fetch["styles"] != nil,
        ]

        for capability in context.capabilities {
            XCTAssertEqual(
                addressed[capability.name], true,
                "this brand advertises a \"\(capability.name)\" capability "
                + "(auth: \(capability.auth)) and this document gives no address for it"
            )
        }
    }

    func testAReservedEntryIsAnAddressClaimAndNothingMore() throws {
        let context = try BrandContext.parse(Fixtures.data("context.json"))
        let served = Set(context.fetch.values.compactMap { $0.split(separator: "/").last.map(String.init) })

        for name in context.reserved {
            XCTAssertTrue(
                name.range(of: "^[a-z0-9.-]+$", options: .regularExpression) != nil,
                "\(name) is not a bare filename"
            )
            XCTAssertFalse(served.contains(name), "\(name) is reserved and served at the same time")
        }
    }

    func testACompositionCarriesItsGeometryAndItsReason() throws {
        let context = try BrandContext.parse(Fixtures.data("context.json"))
        XCTAssertFalse(context.compositions.isEmpty)
        for composition in context.compositions {
            XCTAssertGreaterThan(composition.width, 0)
            XCTAssertGreaterThan(composition.height, 0)
            XCTAssertFalse(
                composition.rationale.isEmpty,
                "a destination with no stated reason cannot be chosen between by anyone reading the list"
            )
        }
    }
}

/// Collects observer callbacks across actor boundaries.
final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String?] = []

    func append(_ value: String?) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [String?] { lock.lock(); defer { lock.unlock() }; return storage }
}
