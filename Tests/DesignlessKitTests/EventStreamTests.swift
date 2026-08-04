/// Reading the change stream, including the frames that mean nothing.

import XCTest
@testable import DesignlessKit

final class EventStreamTests: XCTestCase {
    func testACompleteFrameParses() {
        var p = EventStreamParser()
        let out = p.add("event: hello\ndata: {\"hash\":\"abc123\"}\n\n")
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.name, "hello")
        XCTAssertEqual(out.first?.hash, "abc123")
    }

    func testAFrameSplitAcrossChunksIsStillOneFrame() {
        // The transport decides where the boundaries fall, and a client that
        // assumes one read is one frame drops changes under load.
        var p = EventStreamParser()
        XCTAssertTrue(p.add("event: chan").isEmpty)
        XCTAssertTrue(p.add("ge\ndata: {\"sem").isEmpty)
        let out = p.add("ver\":\"1.0.4\"}\n\n")
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.name, "change")
        XCTAssertEqual(out.first?.semver, "1.0.4")
    }

    func testSeveralFramesInOneChunkAllComeOut() {
        var p = EventStreamParser()
        let out = p.add(
            "event: hello\ndata: {\"hash\":\"a\"}\n\n"
            + "event: change\ndata: {\"hash\":\"b\"}\n\n"
        )
        XCTAssertEqual(out.map(\.name), ["hello", "change"])
        XCTAssertEqual(out.last?.hash, "b")
    }

    func testAKeepAliveCommentCompletesNothing() {
        // A client that treats every line as a change refetches the whole
        // brand every time the server holds the connection open.
        var p = EventStreamParser()
        XCTAssertTrue(p.add(": keep-alive\n\n").isEmpty)
        XCTAssertTrue(p.add(":\n").isEmpty)
    }

    func testAFrameWithNoEventNameIsAMessage() {
        var p = EventStreamParser()
        let out = p.add("data: plain\n\n")
        XCTAssertEqual(out.first?.name, "message")
        XCTAssertEqual(out.first?.data, "plain")
    }

    func testMultiLineDataIsJoinedWithNewlines() {
        var p = EventStreamParser()
        XCTAssertEqual(p.add("data: one\ndata: two\n\n").first?.data, "one\ntwo")
    }

    func testCarriageReturnsAreTolerated() {
        var p = EventStreamParser()
        XCTAssertEqual(p.add("event: hello\r\ndata: {\"hash\":\"a\"}\r\n\r\n").first?.hash, "a")
    }

    func testAnUnknownFieldIsIgnoredRatherThanTreatedAsAnError() {
        var p = EventStreamParser()
        XCTAssertEqual(p.add("id: 7\nevent: change\ndata: {}\n\n").first?.name, "change")
    }

    func testTheRetryIntervalTheServerAskedForIsCarried() {
        var p = EventStreamParser()
        _ = p.add("retry: 3000\n\n")
        XCTAssertEqual(p.retryMilliseconds, 3000)
    }

    func testNoRetryLineIsNilNotAGuess() {
        // A client inventing its own interval turns a brief outage into a
        // stampede. Nil means "the server has not said".
        XCTAssertNil(EventStreamParser().retryMilliseconds)
    }

    func testAMalformedRetryKeepsTheLastGoodValue() {
        var p = EventStreamParser()
        _ = p.add("retry: 3000\n\n")
        _ = p.add("retry: soon\n\n")
        XCTAssertEqual(p.retryMilliseconds, 3000)
    }

    func testDataThatIsNotJsonCarriesNothing() {
        var p = EventStreamParser()
        let out = p.add("event: change\ndata: not json\n\n")
        XCTAssertNil(out.first?.hash)
        XCTAssertNil(out.first?.semver)
        XCTAssertNil(out.first?.version)
    }

    func testARealHelloFrameParsesFieldForField() {
        // Copied from the wire, not invented: this is what
        // GET /r/_designless/events sends on connect.
        var p = EventStreamParser()
        let out = p.add(
            "retry: 3000\n\n"
            + "event: hello\n"
            + "data: {\"hash\":\"38475d3cbc90c923282b801016601d23a374b3f9bdc3c2133ac98833d4016316\","
            + "\"semver\":\"1.0.3\",\"version\":4}\n\n"
        )
        XCTAssertEqual(p.retryMilliseconds, 3000)
        XCTAssertEqual(out.last?.name, "hello")
        XCTAssertEqual(out.last?.hash?.count, 64)
        XCTAssertEqual(out.last?.semver, "1.0.3")
        XCTAssertEqual(out.last?.version, 4)
    }
}
