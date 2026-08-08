import Foundation

/// A parsed, partial update from a `VIDEOHUB DEVICE:` block.
///
/// All fields are optional because the protocol can add fields over time and
/// because keeping this as an update makes it safe to consume incremental
/// device blocks without clearing values that were not present in the block.
public struct VideohubDeviceInfoUpdate: Equatable, Sendable {
    public var presence: VideohubDevicePresence?
    public var modelName: String?
    public var videoInputCount: Int?
    public var videoProcessingUnitCount: Int?
    public var videoOutputCount: Int?
    public var videoMonitoringOutputCount: Int?
    public var serialPortCount: Int?

    public init(
        presence: VideohubDevicePresence? = nil,
        modelName: String? = nil,
        videoInputCount: Int? = nil,
        videoProcessingUnitCount: Int? = nil,
        videoOutputCount: Int? = nil,
        videoMonitoringOutputCount: Int? = nil,
        serialPortCount: Int? = nil
    ) {
        self.presence = presence
        self.modelName = modelName
        self.videoInputCount = videoInputCount
        self.videoProcessingUnitCount = videoProcessingUnitCount
        self.videoOutputCount = videoOutputCount
        self.videoMonitoringOutputCount = videoMonitoringOutputCount
        self.serialPortCount = serialPortCount
    }

    fileprivate var containsRecognizedField: Bool {
        presence != nil
            || modelName != nil
            || videoInputCount != nil
            || videoProcessingUnitCount != nil
            || videoOutputCount != nil
            || videoMonitoringOutputCount != nil
            || serialPortCount != nil
    }
}

public enum VideohubDevicePresence: Equatable, Sendable {
    case present
    case absent
    case needsUpdate
    case unknown(String)
}

public enum VideohubOutputLock: Equatable, Sendable {
    /// The output is available to route.
    case unlocked

    /// The output is locked by this client/address.
    case owned

    /// The output is locked by a different client/address.
    case lockedByOther

    /// A syntactically valid lock line whose state is not understood by this
    /// client. Keeping the index lets the state layer fail closed while still
    /// remaining forward-compatible with later protocol versions.
    case unknown(String)
}

/// Typed messages emitted by ``VideohubProtocolParser``.
///
/// Dictionary keys are protocol indices and therefore remain zero-based.
/// Conversion to the one-based chassis/UI port number belongs in `PortNumber`.
public enum VideohubProtocolEvent: Equatable, Sendable {
    case protocolVersion(String)
    case device(VideohubDeviceInfoUpdate)
    case inputLabels([Int: String])
    case outputLabels([Int: String])
    case videoOutputRouting([Int: Int])
    case videoOutputLocks([Int: VideohubOutputLock])
    case ack
    case nak
}

/// Incrementally parses the line-oriented Blackmagic Videohub Ethernet
/// Protocol without making assumptions about TCP packet boundaries.
public struct VideohubProtocolParser: Sendable {
    private var byteBuffer = Data()
    private var blockLines: [String] = []

    public init() {}

    /// Feeds any number of bytes into the parser and returns only events whose
    /// complete, blank-line-terminated blocks were received by this call.
    public mutating func feed(_ data: Data) -> [VideohubProtocolEvent] {
        byteBuffer.append(data)

        var events: [VideohubProtocolEvent] = []

        while let newlineIndex = byteBuffer.firstIndex(of: 0x0A) {
            var lineBytes = Data(byteBuffer[..<newlineIndex])
            byteBuffer.removeSubrange(byteBuffer.startIndex...newlineIndex)

            // A CR immediately before LF is the line-ending delimiter, not
            // part of a label or field value.
            if lineBytes.last == 0x0D {
                lineBytes.removeLast()
            }

            let line = String(decoding: lineBytes, as: UTF8.self)
            if line.isEmpty {
                guard !blockLines.isEmpty else { continue }

                if let event = Self.parseBlock(blockLines) {
                    events.append(event)
                }
                blockLines.removeAll(keepingCapacity: true)
            } else {
                blockLines.append(line)
            }
        }

        return events
    }

    /// Ends the current stream and discards any incomplete line or block.
    /// Videohub blocks are authoritative only after their terminating blank
    /// line, so an unterminated block must never be emitted on disconnect.
    public mutating func finish() -> [VideohubProtocolEvent] {
        reset()
        return []
    }

    public mutating func reset() {
        byteBuffer.removeAll(keepingCapacity: true)
        blockLines.removeAll(keepingCapacity: true)
    }

    private static func parseBlock(_ lines: [String]) -> VideohubProtocolEvent? {
        guard let firstLine = lines.first else { return nil }

        // ACK and NAK are complete one-line message blocks rather than
        // all-caps headers followed by data lines.
        if lines.count == 1 {
            switch firstLine {
            case "ACK":
                return .ack
            case "NAK":
                return .nak
            default:
                break
            }
        }

        let payloadLines = lines.dropFirst()

        switch firstLine {
        case "PROTOCOL PREAMBLE:":
            return parseProtocolPreamble(payloadLines)
        case "VIDEOHUB DEVICE:":
            return parseDevice(payloadLines)
        case "INPUT LABELS:":
            return .inputLabels(parseLabels(payloadLines))
        case "OUTPUT LABELS:":
            return .outputLabels(parseLabels(payloadLines))
        case "VIDEO OUTPUT ROUTING:":
            return .videoOutputRouting(parseRouting(payloadLines))
        case "VIDEO OUTPUT LOCKS:":
            return .videoOutputLocks(parseLocks(payloadLines))
        default:
            // Future protocol versions may add blocks. The protocol requires
            // clients to ignore an unrecognized block through its blank line.
            return nil
        }
    }

    private static func parseProtocolPreamble(
        _ lines: ArraySlice<String>
    ) -> VideohubProtocolEvent? {
        for line in lines {
            guard let (field, value) = parseField(line) else { continue }
            if field == "Version" {
                return .protocolVersion(value)
            }
        }
        return nil
    }

    private static func parseDevice(
        _ lines: ArraySlice<String>
    ) -> VideohubProtocolEvent? {
        var update = VideohubDeviceInfoUpdate()

        for line in lines {
            guard let (field, value) = parseField(line) else { continue }

            switch field {
            case "Device present":
                update.presence = parsePresence(value)
            case "Model name":
                update.modelName = value
            case "Video inputs":
                update.videoInputCount = parseCount(value)
            case "Video processing units":
                update.videoProcessingUnitCount = parseCount(value)
            case "Video outputs":
                update.videoOutputCount = parseCount(value)
            case "Video monitoring outputs":
                update.videoMonitoringOutputCount = parseCount(value)
            case "Serial ports":
                update.serialPortCount = parseCount(value)
            default:
                // Unknown fields are deliberately ignored for forward
                // compatibility with later protocol versions.
                continue
            }
        }

        guard update.containsRecognizedField else { return nil }
        return .device(update)
    }

    private static func parseLabels(
        _ lines: ArraySlice<String>
    ) -> [Int: String] {
        var labels: [Int: String] = [:]
        for line in lines {
            guard let (index, label) = parseIndexedPayload(line) else { continue }
            labels[index] = label
        }
        return labels
    }

    private static func parseRouting(
        _ lines: ArraySlice<String>
    ) -> [Int: Int] {
        var routes: [Int: Int] = [:]
        for line in lines {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count >= 2,
                  let outputIndex = Int(fields[0]), outputIndex >= 0,
                  let inputIndex = Int(fields[1]), inputIndex >= 0 else {
                continue
            }
            routes[outputIndex] = inputIndex
        }
        return routes
    }

    private static func parseLocks(
        _ lines: ArraySlice<String>
    ) -> [Int: VideohubOutputLock] {
        var locks: [Int: VideohubOutputLock] = [:]
        for line in lines {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count >= 2,
                  let outputIndex = Int(fields[0]), outputIndex >= 0 else {
                continue
            }
            let rawState = String(fields[1]).uppercased()
            let lock: VideohubOutputLock
            switch rawState {
            case "U": lock = .unlocked
            case "O": lock = .owned
            case "L": lock = .lockedByOther
            default: lock = .unknown(rawState)
            }
            locks[outputIndex] = lock
        }
        return locks
    }

    private static func parseField(_ line: String) -> (String, String)? {
        guard let separator = line.firstIndex(of: ":") else { return nil }

        let field = line[..<separator].trimmingCharacters(in: .whitespaces)
        let valueStart = line.index(after: separator)
        let value = line[valueStart...].trimmingCharacters(in: .whitespaces)
        guard !field.isEmpty else { return nil }
        return (field, value)
    }

    private static func parseCount(_ value: String) -> Int? {
        guard let count = Int(value), count >= 0 else { return nil }
        return count
    }

    private static func parsePresence(_ value: String) -> VideohubDevicePresence {
        let normalized = value
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")

        switch normalized {
        case "true":
            return .present
        case "false":
            return .absent
        case "needs update":
            return .needsUpdate
        default:
            return .unknown(value)
        }
    }

    /// Splits an index from the remainder of a line only once. This preserves
    /// every space within (and at the end of) labels instead of tokenizing the
    /// label into words.
    private static func parseIndexedPayload(_ line: String) -> (Int, String)? {
        var cursor = line.startIndex

        while cursor < line.endIndex, line[cursor].isWhitespace {
            cursor = line.index(after: cursor)
        }

        let indexStart = cursor
        while cursor < line.endIndex, line[cursor].isNumber {
            cursor = line.index(after: cursor)
        }

        guard indexStart < cursor,
              let index = Int(line[indexStart..<cursor]),
              index >= 0,
              cursor < line.endIndex,
              line[cursor].isWhitespace else {
            return nil
        }

        // Whitespace at this boundary separates the index and label. Internal
        // and trailing label whitespace remains untouched.
        while cursor < line.endIndex, line[cursor].isWhitespace {
            cursor = line.index(after: cursor)
        }

        return (index, String(line[cursor..<line.endIndex]))
    }
}
