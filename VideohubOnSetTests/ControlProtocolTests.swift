import Foundation
import Testing
@testable import VideohubOnSet

@Suite("Control command decoding")
struct ControlCommandDecodingTests {
    private func decode(_ json: String) throws -> ControlCommand {
        try ControlCommand.decode(from: Data(json.utf8))
    }

    @Test
    func routeCarriesEveryCrosspointInOrder() throws {
        let command = try decode(
            #"{"type":"route","id":"7","crosspoints":[{"output":1,"input":0},{"output":4,"input":3}]}"#
        )
        #expect(
            command == .route(
                id: "7",
                crosspoints: [
                    ControlCrosspoint(output: 1, input: 0),
                    ControlCrosspoint(output: 4, input: 3)
                ]
            )
        )
    }

    @Test
    func requestIDIsOptionalSoAFireAndForgetKeyStillWorks() throws {
        let command = try decode(#"{"type":"route","crosspoints":[{"output":0,"input":0}]}"#)
        #expect(command.requestID == nil)
    }

    /// A key with no crosspoints would silently do nothing, which on set reads
    /// as a dead deck rather than a misconfiguration.
    @Test
    func emptyCrosspointListIsRejected() {
        #expect(throws: ControlCommandDecodingError.emptyCrosspoints) {
            try decode(#"{"type":"route","crosspoints":[]}"#)
        }
    }

    @Test
    func negativePortIndexIsRejected() {
        #expect(throws: ControlCommandDecodingError.invalidCrosspoint) {
            try decode(#"{"type":"route","crosspoints":[{"output":-1,"input":0}]}"#)
        }
    }

    @Test
    func unknownTypeNamesItselfSoTheSurfaceCanReportIt() {
        #expect(throws: ControlCommandDecodingError.unknownType("teleport")) {
            try decode(#"{"type":"teleport"}"#)
        }
    }

    @Test
    func nonObjectFrameIsRejected() {
        #expect(throws: ControlCommandDecodingError.notAnObject) {
            try decode("[1,2,3]")
        }
    }

    @Test
    func salvoRequiresAnIdentifier() {
        #expect(throws: ControlCommandDecodingError.missingField("salvoID")) {
            try decode(#"{"type":"salvo"}"#)
        }
    }

    @Test
    func refreshAndPingDecode() throws {
        #expect(try decode(#"{"type":"refresh","id":"a"}"#) == .refresh(id: "a"))
        #expect(try decode(#"{"type":"ping"}"#) == .ping(id: nil))
    }
}

@Suite("Control event encoding")
struct ControlEventEncodingTests {
    private func encode(_ event: ControlEvent) throws -> [String: Any] {
        let data = try JSONEncoder().encode(event)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test
    func helloAdvertisesTheProtocolVersion() throws {
        let object = try encode(.hello(protocolVersion: 1, app: "Videohub On-Set", appVersion: "0.1"))
        #expect(object["type"] as? String == "hello")
        #expect(object["protocolVersion"] as? Int == 1)
    }

    @Test
    func successfulAckOmitsTheErrorKey() throws {
        let object = try encode(.ack(id: "3", ok: true, error: nil))
        #expect(object["ok"] as? Bool == true)
        #expect(object["error"] == nil)
    }

    @Test
    func refusedAckCarriesTheReason() throws {
        let object = try encode(.ack(id: "3", ok: false, error: "Destination 2 is locked"))
        #expect(object["ok"] as? Bool == false)
        #expect(object["error"] as? String == "Destination 2 is locked")
    }

    /// Frames are newline-delimited on the wire, so a literal newline inside an
    /// encoded string would split one frame into two unparseable halves.
    @Test
    func newlinesInLabelsAreEscapedNotEmitted() throws {
        let snapshot = ControlSnapshot(
            connection: "connected",
            router: ControlRouterInfo(
                identity: "10.0.0.5",
                name: "Smart Videohub 40x40",
                inputCount: 40,
                outputCount: 40,
                isReady: true
            ),
            inputs: [
                ControlPortInfo(
                    index: 0,
                    number: 1,
                    routerLabel: "CAM\nA",
                    name: "CAM\nA",
                    color: "blue",
                    icon: "camera",
                    group: nil,
                    format: nil,
                    routedInput: nil,
                    lock: nil
                )
            ],
            outputs: [],
            routes: [:],
            salvos: []
        )
        let data = try JSONEncoder().encode(ControlEvent.snapshot(snapshot))
        #expect(!data.contains(0x0A))
    }
}

@Suite("Control line framing")
struct ControlLineParserTests {
    private func lines(_ parser: inout ControlLineParser, _ text: String) -> [String] {
        parser.append(Data(text.utf8)).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test
    func splitsCoalescedFrames() {
        var parser = ControlLineParser()
        #expect(lines(&parser, "{\"a\":1}\n{\"b\":2}\n") == ["{\"a\":1}", "{\"b\":2}"])
    }

    /// TCP has no message boundaries, so a burst of key presses can arrive as
    /// one read and a single command can arrive split across several.
    @Test
    func reassemblesAFrameSplitAcrossReads() {
        var parser = ControlLineParser()
        #expect(lines(&parser, "{\"ty").isEmpty)
        #expect(lines(&parser, "pe\":\"ping\"}").isEmpty)
        #expect(lines(&parser, "\n") == ["{\"type\":\"ping\"}"])
    }

    @Test
    func trailingPartialFrameIsHeldBack() {
        var parser = ControlLineParser()
        #expect(lines(&parser, "{\"a\":1}\n{\"b\"") == ["{\"a\":1}"])
    }

    @Test
    func emptyLinesAreSkipped() {
        var parser = ControlLineParser()
        #expect(lines(&parser, "\n\n{\"a\":1}\n") == ["{\"a\":1}"])
    }

    /// A peer that never sends a newline must not grow the buffer without
    /// bound, and the truncated remainder must not be parsed as a command.
    @Test
    func overlongLineIsDiscardedWithoutStrandingTheParser() {
        var parser = ControlLineParser()
        let flood = String(repeating: "x", count: ControlLineParser.maximumLineLength + 16)
        #expect(lines(&parser, flood).isEmpty)
        // Remainder of the poisoned line, then a good frame.
        #expect(lines(&parser, "still-the-bad-line\n") == [])
        #expect(lines(&parser, "{\"type\":\"ping\"}\n") == ["{\"type\":\"ping\"}"])
    }
}
