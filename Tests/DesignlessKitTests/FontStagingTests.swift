/// The ordering rule, and what it refuses to let a caller do.
///
/// These are the tests that matter most in this package. Everything else here
/// is data mapping; this is the one place where being wrong produces a screen
/// that looks fine and is not, for the life of the view.

import XCTest
@testable import DesignlessKit

/// Records the order things happened in, so a test can assert on sequence
/// rather than only on outcome.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var events: [String] = []
    var failFetch: Set<String> = []
    var failRegister: Set<String> = []

    func fetch(_ url: URL) async throws -> Data {
        lock.lock(); events.append("fetch \(url.absoluteString)"); lock.unlock()
        if failFetch.contains(url.absoluteString) {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "network said no"])
        }
        return Data("bytes for \(url.absoluteString)".utf8)
    }

    func register(_ name: String, _ bytes: Data) throws {
        lock.lock(); events.append("register \(name)"); lock.unlock()
        if failRegister.contains(name) {
            throw NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: "platform said no"])
        }
    }

    var registrations: [String] { events.filter { $0.hasPrefix("register ") } }
}

final class MemoryCache: FontCache, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var entries: [String: Data] = [:]

    func read(_ key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return entries[key]
    }

    func write(_ key: String, _ bytes: Data) {
        lock.lock(); entries[key] = bytes; lock.unlock()
    }
}

final class FontStagingTests: XCTestCase {
    private func manifest() throws -> FontManifest {
        try FontManifest.parse(Fixtures.data("fonts.json"))
    }

    private func staged(failing: Set<String> = []) async throws -> FontStaging {
        let r = Recorder()
        r.failRegister = failing
        let staging = FontStaging(fetch: r.fetch, register: r.register)
        await staging.stage(try manifest())
        return staging
    }

    // ── The ordering rule ────────────────────────────────────────────────

    func testNoFaceComesOutBeforeItsFileIsRegistered() async throws {
        let r = Recorder()
        let staging = FontStaging(fetch: r.fetch, register: r.register)

        let cold = await staging.resolve("body")
        XCTAssertEqual(cold.outcome, .notLoaded)
        XCTAssertNil(cold.face, "a face before any load would be a lie")

        await staging.stage(try manifest())

        let warm = await staging.resolve("body")
        XCTAssertEqual(warm.outcome, .resolved)
        XCTAssertEqual(warm.postscriptName, "Inter-Regular")
    }

    func testRegisterHappensAfterFetchForEveryFace() async throws {
        let r = Recorder()
        let staging = FontStaging(fetch: r.fetch, register: r.register)
        await staging.stage(try manifest())

        // At the moment each face was registered, its bytes had already been
        // fetched. Asserting the pairs rather than a whole order, because
        // faces may interleave.
        var fetched: Set<String> = []
        for event in r.events {
            if event.hasPrefix("fetch ") {
                fetched.insert(String(event.dropFirst(6)))
            } else {
                let name = String(event.dropFirst("register ".count))
                let slug = name.hasSuffix("Regular") ? "400-normal" : "600-normal"
                XCTAssertTrue(
                    fetched.contains { $0.contains(slug) },
                    "\(name) was registered before its file was fetched"
                )
            }
        }
        XCTAssertEqual(r.registrations.count, 6)
    }

    func testAFaceThatIsNotStagedIsReportedNotHandedOut() async throws {
        let staging = try await staged(failing: ["EBGaramond-Regular"])
        let display = await staging.resolve("display")

        XCTAssertEqual(display.outcome, .notRegistered)
        XCTAssertNil(display.face)
        XCTAssertTrue(display.detail?.contains("platform said no") ?? false)
        XCTAssertTrue(display.detail?.contains("system font") ?? false)
    }

    func testOneFaceFailingDoesNotStopTheOthers() async throws {
        let r = Recorder()
        r.failFetch = ["https://cdn.designless.app/fonts/google/eb-garamond/400-normal.ttf"]
        let staging = FontStaging(fetch: r.fetch, register: r.register)
        let report = await staging.stage(try manifest())

        XCTAssertEqual(report.failed.count, 1)
        let body = await staging.resolve("body")
        XCTAssertEqual(body.outcome, .resolved, "a display face failing must not take body copy with it")
        let mono = await staging.resolve("mono")
        XCTAssertEqual(mono.outcome, .resolved)
    }

    func testStagingTwiceDoesNotRepeatWork() async throws {
        let r = Recorder()
        let staging = FontStaging(fetch: r.fetch, register: r.register)
        let m = try manifest()

        await staging.stage(m)
        let firstRun = r.events.count
        await staging.stage(m)

        XCTAssertEqual(r.events.count, firstRun, "a second stage() re-downloaded faces already installed")
    }

    func testConcurrentStagingRegistersEachFaceOnce() async throws {
        // Core Text refuses a duplicate registration, so this race is not
        // theoretical: two screens calling stage() on launch is the ordinary
        // case, not a contrived one.
        let r = Recorder()
        let staging = FontStaging(fetch: r.fetch, register: r.register)
        let m = try manifest()

        async let a: StagingReport = staging.stage(m)
        async let b: StagingReport = staging.stage(m)
        _ = await (a, b)

        XCTAssertEqual(Set(r.registrations).count, r.registrations.count,
                       "the same face was registered twice by racing callers")
    }

    // ── The cache ────────────────────────────────────────────────────────

    func testACachedFaceIsNotFetchedAgainButIsStillRegistered() async throws {
        let cache = MemoryCache()
        let first = Recorder()
        await FontStaging(fetch: first.fetch, register: first.register, cache: cache)
            .stage(try manifest())
        XCTAssertEqual(first.events.filter { $0.hasPrefix("fetch") }.count, 6)

        // A second launch: new staging, same cache.
        let second = Recorder()
        let report = await FontStaging(fetch: second.fetch, register: second.register, cache: cache)
            .stage(try manifest())

        XCTAssertEqual(second.events.filter { $0.hasPrefix("fetch") }.count, 0)
        XCTAssertEqual(report.fromCache, 6)
        XCTAssertEqual(report.registered.count, 6,
                       "a cached file still has to be registered every launch — the cache "
                       + "survives the process, the Core Text registration does not")
    }

    func testAFileIsCachedBeforeItIsRegistered() async throws {
        let cache = MemoryCache()
        let r = Recorder()
        r.failRegister = ["Inter-Regular"]
        await FontStaging(fetch: r.fetch, register: r.register, cache: cache).stage(try manifest())

        XCTAssertNotNil(cache.entries["Inter-Regular.ttf"],
                        "the download should survive a failed registration")
    }

    // ── What a caller is told when there is no face ──────────────────────

    func testAnUnpublishedRoleNamesTheRolesThatExist() async throws {
        let staging = try await staged()
        let r = await staging.resolve("caption")

        XCTAssertEqual(r.outcome, .unpublished)
        for named in ["\"body\"", "\"display\"", "\"mono\"", "the name is the fix"] {
            XCTAssertTrue(r.detail?.contains(named) ?? false, "missing: \(named)")
        }
    }

    func testABrandWithNoFacesSaysSoDifferently() async {
        let r = Recorder()
        let staging = FontStaging(fetch: r.fetch, register: r.register)
        await staging.stage(.empty)
        let res = await staging.resolve("body")

        XCTAssertEqual(res.outcome, .unpublished)
        XCTAssertTrue(res.detail?.contains("no font faces at all") ?? false)
    }

    func testAWeightNothingIsNearIsNamedWithWhatExists() async throws {
        let staging = try await staged()
        let r = await staging.resolve("body", weight: 900)

        XCTAssertEqual(r.outcome, .tooFar)
        XCTAssertNil(r.face)
        XCTAssertTrue(r.detail?.contains("\"400\"") ?? false)
        XCTAssertTrue(r.detail?.contains("\"600\"") ?? false)
    }

    func testASubstitutionIsSaidOutLoud() async throws {
        let staging = try await staged()
        let r = await staging.resolve("body", weight: 450)

        XCTAssertEqual(r.outcome, .substituted)
        XCTAssertEqual(r.postscriptName, "Inter-Regular")
        XCTAssertTrue(r.detail?.contains("asked for weight 450") ?? false)
        XCTAssertTrue(r.detail?.contains("not thickened") ?? false)
    }

    func testAnEquidistantWeightTakesTheHeavierFace() async throws {
        // 500 sits exactly between Inter's 400 and 600. At equal distance the
        // bolder of two is what a caller asking for more emphasis meant, and
        // a rule this easy to get backwards should fail a test rather than be
        // rediscovered.
        let staging = try await staged()
        let r = await staging.resolve("body", weight: 500)

        XCTAssertEqual(r.outcome, .substituted)
        XCTAssertEqual(r.postscriptName, "Inter-SemiBold")
    }

    func testAnExactMatchSaysNothing() async throws {
        let staging = try await staged()
        let r = await staging.resolve("body", weight: 600)

        XCTAssertEqual(r.outcome, .resolved)
        XCTAssertNil(r.detail, "nothing happened, so nothing is reported")
        XCTAssertEqual(r.postscriptName, "Inter-SemiBold")
    }
}
