/// Addresses, checked against the grammar the surface publishes.
///
/// The point of these is that they read `protocol.v1.json` rather than
/// restating it. A parameter sent to an address the grammar says it does not
/// apply to is a 400 in production and a passing test here, unless the test
/// asks the grammar.

import XCTest
@testable import DesignlessKit

final class AddressTests: XCTestCase {
    private let serve = ServeAddresses(publicID: "_designless")

    private var grammar: [String: Any] { Fixtures.json("protocol.v1.json") }
    private var params: [String: Any] { grammar["params"] as? [String: Any] ?? [:] }
    private var addressPatterns: [String] {
        (grammar["addresses"] as? [Any] ?? []).compactMap { ($0 as? [String: Any])?["pattern"] as? String }
    }

    /// The grammar's key for an address. An asset is named by its template.
    private func pattern(of url: URL) -> String {
        let file = url.path.replacingOccurrences(of: "/r/_designless/", with: "")
        return file.hasPrefix("assets/") ? "assets/{role}.{format}" : file
    }

    private func query(_ url: URL) -> [String: String] {
        var out: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            out[item.name] = item.value
        }
        return out
    }

    func testEveryAddressBuiltIsOneTheGrammarPublishes() throws {
        for url in [serve.context(), serve.tokens(), serve.fonts(), serve.events()] {
            let file = url.path.replacingOccurrences(of: "/r/_designless/", with: "")
            XCTAssertTrue(
                addressPatterns.contains { $0.hasSuffix("/\(file)") },
                "\(url) is not an address the grammar publishes"
            )
        }
        XCTAssertTrue(addressPatterns.contains("/r/{public_id}/assets/{role}.{format}"))
    }

    func testNoParameterIsSentToAnAddressThatDoesNotTakeIt() throws {
        let built: [URL] = [
            serve.tokens(appearance: .dark),
            serve.tokens(platform: .ios),
            serve.tokens(version: "1.0.3"),
            serve.context(version: "1.0.3"),
            serve.fonts(version: "1.0.3"),
            try serve.asset("logo-symbol", appearance: .light),
            try serve.asset("logo-symbol", format: .png, size: .px256),
        ]

        for url in built {
            let key = pattern(of: url)
            for name in query(url).keys {
                let spec = try XCTUnwrap(params[name] as? [String: Any], "\(name) is not a published parameter")
                let appliesTo = (spec["appliesTo"] as? [Any] ?? []).compactMap { $0 as? String }
                XCTAssertTrue(
                    appliesTo.contains(key),
                    "this package sent ?\(name) to \(key), and the grammar says \(name) applies to "
                    + appliesTo.joined(separator: ", ")
                )
            }
        }
    }

    func testEveryValueSentIsOneTheGrammarAccepts() throws {
        let checks: [(URL, String)] = [
            (serve.tokens(appearance: .dark), "appearance"),
            (serve.tokens(platform: .android), "platform"),
            (try serve.asset("logo-symbol", format: .png, size: .px512), "size"),
        ]
        for (url, name) in checks {
            let spec = try XCTUnwrap(params[name] as? [String: Any])
            let values = (spec["values"] as? [Any] ?? []).map { "\($0)" }
            XCTAssertTrue(values.contains(query(url)[name] ?? ""), "\(name)")
        }
    }

    func testTheSizeLadderIsExactlyThePublishedOne() throws {
        let spec = try XCTUnwrap(params["size"] as? [String: Any])
        let published = (spec["values"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
        XCTAssertEqual(
            AssetSize.allCases.map(\.rawValue), published,
            "the ladder this package offers has drifted from the one the surface renders; "
            + "a rung that is not published is a 400"
        )
    }

    func testASizeOnAVectorIsRefusedHereRatherThan400ingThere() {
        // A 400 from a CDN reaches a caller as a blank image view with no
        // explanation. This is the same refusal, close enough to the mistake
        // to name it.
        XCTAssertThrowsError(try serve.asset("logo-symbol", size: .px256)) { error in
            XCTAssertEqual(error as? AddressError, .sizeOnVector)
        }
    }

    func testAComposedDestinationCarriesNoParameters() {
        // Not an assertion about a throw: the signature does not accept them.
        // Written down because "why can I not ask for a 512 app icon" is a
        // reasonable question, and the answer is that the destination decides.
        let url = serve.composition("app-icon")
        XCTAssertTrue(query(url).isEmpty)
        XCTAssertEqual(url.path, "/r/_designless/assets/app-icon.png")
    }

    func testAtLeastRoundsUpBecauseScalingDownStaysSharp() {
        XCTAssertEqual(AssetSize.atLeast(1), .px16)
        XCTAssertEqual(AssetSize.atLeast(16), .px16)
        XCTAssertEqual(AssetSize.atLeast(17), .px32)
        XCTAssertEqual(AssetSize.atLeast(200), .px256)
        XCTAssertEqual(AssetSize.atLeast(4096), .px1024, "past the top of the ladder takes the top rung")
    }

    func testTheSameRequestIsAlwaysTheSameString() {
        // Query order is sorted, so a cache key built from the URL is stable
        // and two callers asking the same thing get one cache entry.
        let a = serve.tokens(appearance: .dark, platform: .ios, version: "1.0.3")
        let b = serve.tokens(appearance: .dark, platform: .ios, version: "1.0.3")
        XCTAssertEqual(a.absoluteString, b.absoluteString)
        XCTAssertEqual(a.query, "appearance=dark&platform=ios&version=1.0.3")
    }
}
