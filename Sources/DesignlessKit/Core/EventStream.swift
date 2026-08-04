/// Reading the change stream.
///
/// The surface serves `text/event-stream` at `/r/<id>/events`, and this turns
/// those bytes into events. It does the parsing and nothing else: the
/// connection, the retries and the platform's idea of "the app came back"
/// belong to the caller, and a parser that also owns a socket cannot be tested
/// without one.

import Foundation

/// One frame off the stream.
public struct ServeEvent: Sendable, Equatable {
    /// The event name, or `message` when the frame did not carry one.
    public let name: String
    public let data: String

    private var json: [String: JSONValue]? {
        guard !data.isEmpty,
              let bytes = data.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: bytes)
        else { return nil }
        return JSONValue.from(any).objectValue
    }

    /// The build hash a frame carries, when it carries one.
    ///
    /// Both the opening `hello` and a change frame name one. Comparing it to
    /// the hash in hand is how a client tells "this brand changed" from "this
    /// frame is about a brand I am already showing", which matters because a
    /// reconnect replays the hello.
    ///
    /// Read under exactly the name the stream uses, and no others. Accepting
    /// spellings the surface has never sent is a guess dressed up as
    /// tolerance: it costs nothing until a field really is renamed, and then
    /// it hides the break behind a fallback that was never real.
    public var hash: String? {
        guard case let .string(s)? = json?["hash"], !s.isEmpty else { return nil }
        return s
    }

    /// The published version a frame names. `"1.0.3"`.
    public var semver: String? {
        guard case let .string(s)? = json?["semver"], !s.isEmpty else { return nil }
        return s
    }

    /// The build number a frame names.
    public var version: Int? {
        json?["version"]?.doubleValue.map(Int.init)
    }
}

/// Turns event-stream text into `ServeEvent`s.
///
/// Feed it whatever arrives. The transport may split a frame across chunks or
/// deliver several at once, and neither is unusual, so state is kept between
/// calls and a frame cut in half is still one event.
public struct EventStreamParser: Sendable {
    private var dataLines: [String] = []
    private var name: String?

    /// The tail of the last chunk, when it did not end on a line break.
    ///
    /// Without this a chunk ending mid-line is treated as a whole line:
    /// `event: chan` then `ge\n` yields an event named `chan`. Nothing stops
    /// a chunk boundary landing inside a field name.
    private var partial = ""

    /// How long the server asked to be left alone between reconnects, in
    /// milliseconds, or nil if it has not said. The surface sends `retry: 3000`.
    ///
    /// Worth honouring: a client reconnecting on its own schedule turns a
    /// brief outage into a stampede.
    public private(set) var retryMilliseconds: Int?

    public init() {}

    /// Parse `chunk` and return the frames it completed.
    ///
    /// A comment line (`: keep-alive`) completes nothing and returns nothing,
    /// which is the point of it: it holds the connection open and carries no
    /// change, so a client that treats every line as a change refetches the
    /// brand every time the server says hello.
    public mutating func add(_ chunk: String) -> [ServeEvent] {
        var out: [ServeEvent] = []

        let buffered = partial + chunk
        let endsOnBreak = buffered.hasSuffix("\n") || buffered.hasSuffix("\r")

        // Split on "\n" alone, NOT on `.newlines`. A character set splits
        // "\r\n" into two breaks, which inserts a phantom empty line between
        // every real one — and an empty line is the frame terminator, so every
        // CRLF frame ended after its first field. The trailing "\r" is dropped
        // per line below.
        var lines = buffered.components(separatedBy: "\n")

        // `components(separatedBy:)` leaves an empty last element after a
        // trailing break, which is exactly the frame terminator and must be
        // kept. Only an unterminated tail is withheld for the next chunk.
        if endsOnBreak {
            partial = ""
        } else {
            partial = lines.popLast() ?? ""
        }

        for raw in lines {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw

            if line.isEmpty {
                let body = dataLines.joined(separator: "\n")
                if !body.isEmpty || name != nil {
                    out.append(ServeEvent(name: name ?? "message", data: body))
                }
                dataLines = []
                name = nil
                continue
            }

            // Comments, including this surface's keep-alives. Redundant with
            // the dispatch below — a `:` line parses to an empty field name,
            // which falls through and is ignored — and kept because the two
            // are independent: the dispatch ignores unknown fields as a
            // courtesy, this refuses comments as a rule.
            if line.hasPrefix(":") { continue }

            let field: String
            var value: String
            if let colon = line.firstIndex(of: ":") {
                field = String(line[line.startIndex..<colon])
                value = String(line[line.index(after: colon)...])
                if value.hasPrefix(" ") { value.removeFirst() }
            } else {
                field = line
                value = ""
            }

            switch field {
            case "event": name = value
            case "data": dataLines.append(value)
            case "retry": retryMilliseconds = Int(value) ?? retryMilliseconds
            default: break // `id` and anything unknown: ignored, not an error
            }
        }

        return out
    }
}
