/// The one claim the other SDKs cannot make.
///
/// Every client in this family says "a face is reached by its PostScript name,
/// and registration must complete before anything renders". On React Native
/// and Flutter that is asserted through a stub: the real font manager is not
/// reachable from a test process. Here it is.
///
/// These run against a real Inter TTF and the real
/// `CTFontManagerRegisterGraphicsFont`, and then ask Core Text for the face by
/// name. If the rule this whole family is built around were wrong, this is
/// where it would show.

import CoreGraphics
import CoreText
import XCTest
@testable import DesignlessKit

final class CoreTextRegistrarTests: XCTestCase {
    private var interBytes: Data { Fixtures.data("Inter-Regular.ttf") }

    func testARealFaceRegistersAndCoreTextThenAnswersToItsPostScriptName() throws {
        try CoreTextRegistrar.register("Inter-Regular", interBytes)

        // The claim, made against the actual font manager: the name the brand
        // advertises is the name that resolves.
        let font = CTFontCreateWithName("Inter-Regular" as CFString, 16, nil)
        XCTAssertEqual(CTFontCopyPostScriptName(font) as String, "Inter-Regular")
    }

    func testTheFamilyNameResolvesToRegularWhicheverWeightYouMeant() throws {
        // The reason the whole family keys on PostScript names, measured
        // rather than assumed.
        //
        // An earlier version of this test asserted that a family name does not
        // resolve at all, and it failed: it does resolve. That was worth
        // finding, because the truth is a stronger argument. The family name
        // gives you Regular no matter which weight you wanted, and every
        // name-taking API — UIFont(name:size:), Font.custom, this one — has
        // nowhere to say otherwise. A heading asking for SemiBold gets a real
        // font, correctly rendered, quietly the wrong one.
        try? CoreTextRegistrar.register("Inter-Regular", interBytes)
        try? CoreTextRegistrar.register("Inter-SemiBold", Fixtures.data("Inter-SemiBold.ttf"))

        let byFamily = CTFontCreateWithName("Inter" as CFString, 16, nil)
        XCTAssertEqual(CTFontCopyPostScriptName(byFamily) as String, "Inter-Regular")

        // The PostScript name is the only string that picks between them
        // through this API.
        let bySemiBold = CTFontCreateWithName("Inter-SemiBold" as CFString, 16, nil)
        XCTAssertEqual(CTFontCopyPostScriptName(bySemiBold) as String, "Inter-SemiBold")
    }

    func testAWeightTraitCanSelectButIsADifferentApiAndADifferentScale() throws {
        // Recorded so the docblock's parenthetical is checked rather than
        // asserted. A descriptor carrying family plus weight does select
        // correctly — but it needs Core Text's -1...1 scale, not the brand's
        // 100...900, so it is a second conversion to get wrong, and it is not
        // the API almost any call site reaches for.
        try? CoreTextRegistrar.register("Inter-Regular", interBytes)
        try? CoreTextRegistrar.register("Inter-SemiBold", Fixtures.data("Inter-SemiBold.ttf"))

        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontFamilyNameAttribute: "Inter",
            kCTFontTraitsAttribute: [kCTFontWeightTrait: 0.3],
        ] as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, 16, nil)
        XCTAssertEqual(CTFontCopyPostScriptName(font) as String, "Inter-SemiBold")
    }

    func testBytesThatAreNotAFontAreRefusedRatherThanRegistered() {
        XCTAssertThrowsError(try CoreTextRegistrar.register("Whatever", Data("not a font".utf8))) { error in
            guard case FontRegistrationError.unreadable = error else {
                return XCTFail("expected .unreadable, got \(error)")
            }
        }
    }

    func testAFileWhoseNameDisagreesWithTheBrandIsRefused() {
        // The check that turns a silent system-font substitution into an error
        // at the moment of registration. If the CDN ever served the wrong file
        // under a name, this is what catches it — and the alternative is every
        // later lookup missing with no explanation.
        XCTAssertThrowsError(try CoreTextRegistrar.register("Inter-SemiBold", interBytes)) { error in
            guard case let FontRegistrationError.nameMismatch(expected, actual) = error else {
                return XCTFail("expected .nameMismatch, got \(error)")
            }
            XCTAssertEqual(expected, "Inter-SemiBold")
            XCTAssertEqual(actual, "Inter-Regular")
        }
    }

    func testRegisteringTheSameFaceTwiceIsNotAFailure() throws {
        // Already-registered is success from a caller's point of view: the
        // face is reachable, which is the only thing being asked for.
        // Reporting it as failure would mark a working font broken on the
        // second call in a process.
        try? CoreTextRegistrar.register("Inter-Regular", interBytes)
        XCTAssertNoThrow(try CoreTextRegistrar.register("Inter-Regular", interBytes))
    }

    func testStagingWithTheRealRegistrarResolvesARealFace() async throws {
        // End to end on the one platform where it can be: the manifest names
        // a face, the real registrar installs it, and `resolve` hands back a
        // name Core Text answers to.
        let bytes = interBytes
        let staging = FontStaging(
            fetch: { _ in bytes },
            register: CoreTextRegistrar.register
        )

        let manifest = FontManifest(
            families: [FontFamily(
                name: "Inter",
                roles: ["body"],
                faces: [FontFace(
                    family: "Inter",
                    weight: 400,
                    style: .normal,
                    postscriptName: "Inter-Regular",
                    sources: ["ttf": "https://cdn.designless.app/fonts/google/inter/400-normal.ttf"]
                )]
            )],
            nativeFormat: "ttf",
            webFormat: "woff2"
        )

        await staging.stage(manifest)
        let resolved = await staging.resolve("body")

        XCTAssertEqual(resolved.outcome, .resolved)
        let name = try XCTUnwrap(resolved.postscriptName)
        let font = CTFontCreateWithName(name as CFString, 16, nil)
        XCTAssertEqual(CTFontCopyPostScriptName(font) as String, name,
                       "resolve() returned a name Core Text does not answer to")
    }
}
