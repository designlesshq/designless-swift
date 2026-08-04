/// The captured payloads every test reads.
///
/// Real responses, pulled from the live brand rather than written by hand. A
/// test that fails against one of them is reporting something about the
/// surface, not only about this package. Re-capture with:
///
///   curl -sS "https://cdn.designless.app/r/_designless/tokens.json?appearance=dark" \
///     -o Tests/DesignlessKitTests/Fixtures/tokens.dark.json
///
/// Do not hand-edit them. A fixture edited to suit a test stops being evidence
/// of anything, and the edit is invisible at the point it matters.

import Foundation

enum Fixtures {
    static func data(_ name: String) -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"),
              let bytes = try? Data(contentsOf: url)
        else {
            fatalError("fixture \(name) is missing from the test bundle")
        }
        return bytes
    }

    static func json(_ name: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data(name))) as? [String: Any] ?? [:]
    }
}
