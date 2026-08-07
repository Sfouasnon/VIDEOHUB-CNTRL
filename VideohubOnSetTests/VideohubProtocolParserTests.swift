import Foundation
import Testing
@testable import VideohubOnSet

@Suite("Videohub protocol parser")
struct VideohubProtocolParserTests {
    @Test
    func protocolPreamble() {
        let events = parse("""
        PROTOCOL PREAMBLE:
        Version: 2.3

        """)

        #expect(events == [.protocolVersion("2.3")])
    }

    @Test
    func deviceInformationAndUnknownField() {
        let events = parse("""
        VIDEOHUB DEVICE:
        Device present: true
        Model name: Blackmagic Smart Videohub 40x40
        Video inputs: 40
        Video processing units: 0
        Video outputs: 40
        Video monitoring outputs: 2
        Serial ports: 0
        A future field: deliberately ignored

        """)

        #expect(
            events ==
            [
                .device(
                    VideohubDeviceInfoUpdate(
                        presence: .present,
                        modelName: "Blackmagic Smart Videohub 40x40",
                        videoInputCount: 40,
                        videoProcessingUnitCount: 0,
                        videoOutputCount: 40,
                        videoMonitoringOutputCount: 2,
                        serialPortCount: 0
                    )
                )
            ]
        )
    }

    @Test
    func deviceAbsentAndNeedsUpdateStates() {
        #expect(
            parse("VIDEOHUB DEVICE:\nDevice present: false\n\n") ==
            [.device(VideohubDeviceInfoUpdate(presence: .absent))]
        )
        #expect(
            parse("VIDEOHUB DEVICE:\nDevice present: needs_update\n\n") ==
            [.device(VideohubDeviceInfoUpdate(presence: .needsUpdate))]
        )
    }

    @Test
    func inputLabelsPreserveSpaces() {
        let events = parse("""
        INPUT LABELS:
        0 Cam 1 – Handheld
        2 Cam 3 – Steadicam
        10 Playback A  Main  

        """)

        #expect(
            events ==
            [
                .inputLabels([
                    0: "Cam 1 – Handheld",
                    2: "Cam 3 – Steadicam",
                    10: "Playback A  Main  "
                ])
            ]
        )
    }

    @Test
    func outputLabels() {
        let events = parse("""
        OUTPUT LABELS:
        0 Video Village 1
        7 Director Monitor

        """)

        #expect(
            events ==
            [.outputLabels([0: "Video Village 1", 7: "Director Monitor"])]
        )
    }

    @Test
    func videoOutputRoutingMultipleLinesUsesZeroBasedIndices() {
        let events = parse("""
        VIDEO OUTPUT ROUTING:
        0 5
        7 2
        39 10

        """)

        #expect(events == [.videoOutputRouting([0: 5, 7: 2, 39: 10])])
    }

    @Test
    func videoOutputLocks() {
        let events = parse("""
        VIDEO OUTPUT LOCKS:
        0 U
        1 O
        2 L

        """)

        #expect(
            events ==
            [
                .videoOutputLocks([
                    0: .unlocked,
                    1: .owned,
                    2: .lockedByOther
                ])
            ]
        )
    }

    @Test
    func incrementalUpdateBlock() {
        let events = parse("""
        VIDEO OUTPUT ROUTING:
        7 2

        """)

        #expect(events == [.videoOutputRouting([7: 2])])
    }

    @Test
    func unknownBlockIsIgnoredWithoutAffectingFollowingBlock() {
        let events = parse("""
        FUTURE VIDEOHUB FEATURE:
        Unknown: value
        0 Something

        OUTPUT LABELS:
        0 Program

        """)

        #expect(events == [.outputLabels([0: "Program"])])
    }

    @Test
    func unknownLinesAreIgnoredAndUnknownLockValuesArePreserved() {
        let events = parse("""
        VIDEO OUTPUT ROUTING:
        Future field: value
        not-an-index 4
        3 9

        VIDEO OUTPUT LOCKS:
        0 Z
        Future lock field: ignored
        1 L

        """)

        #expect(
            events ==
            [
                .videoOutputRouting([3: 9]),
                .videoOutputLocks([
                    0: .unknown("Z"),
                    1: .lockedByOther
                ])
            ]
        )
    }

    @Test
    func crlfAndLFLineEndings() {
        var parser = VideohubProtocolParser()

        let crlfEvents = parser.feed(
            Data("INPUT LABELS:\r\n0 Camera A\r\n\r\n".utf8)
        )
        let lfEvents = parser.feed(
            Data("OUTPUT LABELS:\n0 Monitor A\n\n".utf8)
        )

        #expect(crlfEvents == [.inputLabels([0: "Camera A"])])
        #expect(lfEvents == [.outputLabels([0: "Monitor A"])])
    }

    @Test
    func ackAndNAK() {
        let events = parse("ACK\n\nNAK\r\n\r\n")

        #expect(events == [.ack, .nak])
    }

    @Test
    func multipleBlocksCanArriveInOneChunk() {
        let events = parse("""
        PROTOCOL PREAMBLE:
        Version: 2.3

        INPUT LABELS:
        0 Camera 1
        1 Camera 2

        VIDEO OUTPUT ROUTING:
        0 1

        ACK

        """)

        #expect(
            events ==
            [
                .protocolVersion("2.3"),
                .inputLabels([0: "Camera 1", 1: "Camera 2"]),
                .videoOutputRouting([0: 1]),
                .ack
            ]
        )
    }

    @Test
    func incompleteNetworkChunksDoNotEmitEarly() {
        var parser = VideohubProtocolParser()

        #expect(parser.feed(Data("INPUT LAB".utf8)).isEmpty)
        #expect(parser.feed(Data("ELS:\r\n0 Cam".utf8)).isEmpty)
        #expect(parser.feed(Data("era 1\r".utf8)).isEmpty)
        #expect(parser.feed(Data("\n1 Camera 2\r\n".utf8)).isEmpty)

        #expect(
            parser.feed(Data("\r\n".utf8)) ==
            [.inputLabels([0: "Camera 1", 1: "Camera 2"])]
        )
    }

    @Test
    func everyByteMayArriveInItsOwnChunkIncludingUTF8Labels() {
        let message = "INPUT LABELS:\r\n2 Cam 3 – Steadicam 🎥\r\n\r\n"
        var parser = VideohubProtocolParser()
        var events: [VideohubProtocolEvent] = []

        for byte in message.utf8 {
            events.append(contentsOf: parser.feed(Data([byte])))
        }

        #expect(
            events ==
            [.inputLabels([2: "Cam 3 – Steadicam 🎥"])]
        )
    }

    @Test
    func unterminatedBlockIsNotAuthoritativeAndFinishDiscardsIt() {
        var parser = VideohubProtocolParser()

        #expect(
            parser.feed(Data("VIDEO OUTPUT ROUTING:\n7 2\n".utf8)).isEmpty
        )
        #expect(parser.finish().isEmpty)

        #expect(
            parser.feed(Data("ACK\n\n".utf8)) ==
            [.ack]
        )
    }

    private func parse(_ string: String) -> [VideohubProtocolEvent] {
        var parser = VideohubProtocolParser()
        // Swift multiline literals omit the newline immediately before their
        // closing delimiter. Complete-block fixtures therefore add the blank
        // line that the Videohub wire protocol requires.
        return parser.feed(Data((string + "\n").utf8))
    }
}
