import Compression
import Foundation

/// Reads port names, colors and icons out of a Bitfocus Companion export.
///
/// A Companion routing page is a destination, and each key on it is a source.
/// That means the config already holds what an operator would otherwise retype
/// into Videohub CNTRL by hand. This is a Swift port of
/// `script/import_companion_config.py`; the script remains for scripted use, so
/// the two must agree. Any rule change belongs in both.
///
/// Only labels and appearance are imported. Crosspoints are not: a Companion
/// key is a routing action, not a saved layout, and the app already learns live
/// routes from the router itself.
enum CompanionConfigImport {

    // MARK: - Errors

    enum Failure: Error, Equatable, LocalizedError, Sendable {
        case unreadableFile(String)
        case corruptArchive
        case notCompanionConfig
        case noRoutesFound
        case noRouterIdentity

        var errorDescription: String? {
            switch self {
            case let .unreadableFile(message):
                "The file could not be read: \(message)"
            case .corruptArchive:
                "The file looks like a Companion export but its compressed contents could not be expanded."
            case .notCompanionConfig:
                "That is not a Companion configuration export."
            case .noRoutesFound:
                "No Videohub routing buttons were found in this export."
            case .noRouterIdentity:
                "Connect to a router first — imported names are stored per router."
            }
        }
    }

    // MARK: - Public model

    /// One port's worth of imported presentation, ready to preview or apply.
    struct Entry: Identifiable, Equatable, Sendable {
        let kind: PortKind
        let protocolPortIndex: Int
        let name: String
        let accentColor: PortAccentColor
        let icon: VideohubIcon

        var id: String { "\(kind.rawValue)-\(protocolPortIndex)" }

        /// Videohub ports are zero-based in the protocol and one-based on screen.
        var uiNumber: Int { protocolPortIndex + 1 }
    }

    /// A Videohub connection defined in the export, with how many routing keys
    /// point at it. Carts often carry more than one router.
    struct Connection: Identifiable, Equatable, Sendable {
        let id: String
        let label: String
        let routeKeyCount: Int
    }

    /// The result of parsing, shown to the operator before anything is written.
    ///
    /// `id` is deliberately the router rather than the contents: narrowing to a
    /// single Companion connection re-parses and replaces this value, and a
    /// changing id would tear the sheet down and rebuild it mid-decision.
    struct Preview: Equatable, Identifiable, Sendable {
        let routerIdentity: String
        let entries: [Entry]
        let connections: [Connection]
        let selectedConnectionID: String?

        var id: String { routerIdentity }

        var sources: [Entry] { entries.filter { $0.kind == .source } }
        var destinations: [Entry] { entries.filter { $0.kind == .destination } }

        /// The exact shape `CustomizationStore.replaceCustomizations` expects.
        var customizations: [PortCustomizationKey: PortCustomization] {
            var result: [PortCustomizationKey: PortCustomization] = [:]
            for entry in entries {
                let key = PortCustomizationKey(
                    routerIdentity: routerIdentity,
                    kind: entry.kind,
                    protocolPortIndex: entry.protocolPortIndex
                )
                result[key] = PortCustomization(
                    displayNameOverride: entry.name,
                    accentColor: entry.accentColor,
                    icon: entry.icon
                )
            }
            return result
        }
    }

    // MARK: - Entry points

    /// Parses an export and produces a preview for one router.
    ///
    /// - Parameter connectionID: restricts the import to a single Companion
    ///   connection. `nil` accepts every Videohub connection in the file, which
    ///   is right for the common single-router cart.
    static func preview(
        fileURL: URL,
        routerIdentity: String,
        connectionID: String? = nil
    ) throws -> Preview {
        let identity = routerIdentity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !identity.isEmpty else { throw Failure.noRouterIdentity }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw Failure.unreadableFile(error.localizedDescription)
        }

        return try preview(
            configurationData: data,
            routerIdentity: identity,
            connectionID: connectionID
        )
    }

    /// Data-level entry point, kept separate so tests need no file on disk.
    static func preview(
        configurationData data: Data,
        routerIdentity: String,
        connectionID: String? = nil
    ) throws -> Preview {
        let identity = routerIdentity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !identity.isEmpty else { throw Failure.noRouterIdentity }

        let json = try decodeConfiguration(data)

        guard let root = json as? [String: Any] else { throw Failure.notCompanionConfig }
        guard root["pages"] != nil || root["instances"] != nil else {
            throw Failure.notCompanionConfig
        }

        let instances = instanceLabels(in: root)
        // Named `harvested`, not `harvest`: `let harvest = harvest(...)` puts the
        // new binding in scope inside its own initializer.
        let harvested = harvest(root: root, connectionID: connectionID)

        guard !harvested.connectionCounts.isEmpty else { throw Failure.noRoutesFound }

        var connections: [Connection] = []
        for (id, count) in harvested.connectionCounts {
            let label: String = instances[id] ?? "Unnamed connection"
            connections.append(Connection(id: id, label: label, routeKeyCount: count))
        }
        connections.sort { lhs, rhs in
            if lhs.routeKeyCount != rhs.routeKeyCount {
                return lhs.routeKeyCount > rhs.routeKeyCount
            }
            let order = lhs.label.localizedCaseInsensitiveCompare(rhs.label)
            return order == .orderedAscending
        }

        let destinationNames = dropSharedDestinationNames(harvested.destinationNames)
        let entries = buildEntries(
            sourceNames: harvested.sourceNames,
            sourceColors: harvested.sourceColors,
            destinationNames: destinationNames
        )

        return Preview(
            routerIdentity: identity,
            entries: entries,
            connections: connections,
            selectedConnectionID: connectionID
        )
    }

    // MARK: - Decoding

    /// A `.companionconfig` is gzipped JSON; older exports are plain JSON.
    private static func decodeConfiguration(_ data: Data) throws -> Any {
        let payload = Gzip.isGzipped(data) ? try Gzip.inflate(data) : data
        do {
            return try JSONSerialization.jsonObject(with: payload, options: [])
        } catch {
            throw Failure.notCompanionConfig
        }
    }

    private static func instanceLabels(in root: [String: Any]) -> [String: String] {
        guard let instances = root["instances"] as? [String: Any] else { return [:] }

        var result: [String: String] = [:]
        for (identifier, rawBody) in instances {
            guard let body = rawBody as? [String: Any] else { continue }
            let rawLabel = body["label"] as? String
            let trimmed = rawLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                result[identifier] = trimmed
            } else {
                result[identifier] = identifier
            }
        }
        return result
    }

    // MARK: - Harvesting

    private struct Harvest {
        var sourceNames: [Int: [String: Int]] = [:]
        var sourceColors: [Int: [PortAccentColor: Int]] = [:]
        var destinationNames: [Int: [String: Int]] = [:]
        var connectionCounts: [String: Int] = [:]
    }

    /// Collects candidate names and colors per port, with vote counts.
    ///
    /// A source appears on many pages with slightly different labels; taking the
    /// most common one is more reliable than taking the first.
    private static func harvest(root: [String: Any], connectionID: String?) -> Harvest {
        var result = Harvest()

        for control in controls(in: root) {
            let label: String = text(of: control.body)
            let background: Int? = backgroundColor(of: control.body)
            let pageLabel: String = cleanLabel(control.pageName)

            // Resolved once per key rather than once per route.
            var accent: PortAccentColor?
            if let background {
                accent = nearestAccent(background)
            }

            let pageNamesADestination: Bool = !pageLabel.isEmpty
                && pageLabel.uppercased() != "PAGE"

            for route in routes(in: control.body) {
                // Counted before the filter, so the connection picker can offer
                // connections the current filter excludes.
                var seen: Int = result.connectionCounts[route.connectionID] ?? 0
                seen += 1
                result.connectionCounts[route.connectionID] = seen

                if let connectionID, route.connectionID != connectionID { continue }

                if !label.isEmpty {
                    var names: [String: Int] = result.sourceNames[route.source] ?? [:]
                    names[label] = (names[label] ?? 0) + 1
                    result.sourceNames[route.source] = names
                }

                if let accent {
                    var colors: [PortAccentColor: Int] = result.sourceColors[route.source] ?? [:]
                    colors[accent] = (colors[accent] ?? 0) + 1
                    result.sourceColors[route.source] = colors
                }

                if pageNamesADestination {
                    var names: [String: Int] = result.destinationNames[route.destination] ?? [:]
                    names[pageLabel] = (names[pageLabel] ?? 0) + 1
                    result.destinationNames[route.destination] = names
                }
            }
        }

        return result
    }

    private struct Control {
        let pageName: String
        let body: [String: Any]
    }

    /// Every configured button, in page order.
    private static func controls(in root: [String: Any]) -> [Control] {
        guard let pages = root["pages"] as? [String: Any] else { return [] }

        // Page keys are numeric strings. Anything unparseable sorts last rather
        // than crashing the import.
        let ordered = pages.sorted { lhs, rhs in
            let left: Int = Int(lhs.key) ?? Int.max
            let right: Int = Int(rhs.key) ?? Int.max
            return left < right
        }

        var result: [Control] = []
        for (_, rawPage) in ordered {
            guard let page = rawPage as? [String: Any] else { continue }
            let pageName = page["name"] as? String ?? ""
            guard let rows = page["controls"] as? [String: Any] else { continue }

            for (_, rawRow) in rows {
                guard let row = rawRow as? [String: Any] else { continue }
                for (_, rawControl) in row {
                    guard let control = rawControl as? [String: Any],
                          let type = control["type"] as? String,
                          type.hasPrefix("button") else { continue }
                    result.append(Control(pageName: pageName, body: control))
                }
            }
        }
        return result
    }

    private static func styleLayers(of control: [String: Any]) -> [[String: Any]] {
        guard let style = control["style"] as? [String: Any],
              let layers = style["layers"] as? [Any] else { return [] }
        return layers.compactMap { $0 as? [String: Any] }
    }

    private static func text(of control: [String: Any]) -> String {
        for layer in styleLayers(of: control) where layer["type"] as? String == "text" {
            guard let text = layer["text"] as? [String: Any] else { continue }
            if let value = text["value"] {
                let string = String(describing: value)
                if !string.isEmpty { return cleanLabel(string) }
            }
        }
        return ""
    }

    private static func backgroundColor(of control: [String: Any]) -> Int? {
        for layer in styleLayers(of: control) where layer["type"] as? String == "box" {
            guard let color = layer["color"] as? [String: Any] else { continue }
            // Only a genuine integer counts: Companion writes expressions as
            // strings, and those carry no color we can resolve here.
            if let value = color["value"] as? Int { return value }
            if let number = color["value"] as? NSNumber,
               CFNumberIsFloatType(number) == false {
                return number.intValue
            }
        }
        return nil
    }

    private struct Route {
        let source: Int
        let destination: Int
        let connectionID: String
    }

    /// Every (source, destination) pair a key can produce, across all steps.
    private static func routes(in control: [String: Any]) -> [Route] {
        guard let steps = control["steps"] as? [String: Any] else { return [] }

        var result: [Route] = []
        for (_, rawStep) in steps {
            guard let step = rawStep as? [String: Any],
                  let actionSets = step["action_sets"] as? [String: Any] else { continue }

            for (_, rawActions) in actionSets {
                guard let actions = rawActions as? [Any] else { continue }
                for rawAction in actions {
                    guard let action = rawAction as? [String: Any],
                          let options = action["options"] as? [String: Any],
                          let source = optionInteger(options["source"]),
                          let destination = optionInteger(options["destination"]) else { continue }

                    // A missing connectionId still groups: it becomes its own
                    // bucket rather than silently merging with a real one.
                    let connectionID = action["connectionId"] as? String ?? ""
                    result.append(
                        Route(source: source, destination: destination, connectionID: connectionID)
                    )
                }
            }
        }
        return result
    }

    private static func optionInteger(_ option: Any?) -> Int? {
        guard let wrapper = option as? [String: Any] else { return nil }
        if let value = wrapper["value"] as? Int { return value }
        if let number = wrapper["value"] as? NSNumber, CFNumberIsFloatType(number) == false {
            return number.intValue
        }
        return nil
    }

    // MARK: - Naming rules

    /// Companion labels carry markup and variables that mean nothing here.
    static func cleanLabel(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(
            of: #"\$\([^)]*\)"#, with: "", options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"<[^>]+>"#, with: "", options: .regularExpression
        )
        result = result.replacingOccurrences(of: #"\n"#, with: " ")
        result = result.replacingOccurrences(of: "\n", with: " ")
        result = result.replacingOccurrences(
            of: #"\s+"#, with: " ", options: .regularExpression
        )
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Icon names matched against the label text. The first pattern that
    /// matches wins, so specific terms come before generic ones.
    struct IconRule: Sendable {
        let pattern: String
        let icon: VideohubIcon
    }

    private static let iconRules: [IconRule] = [
        IconRule(pattern: #"\bwitcam|\bcam\b|camera|\bcam\d"#, icon: .camera),
        IconRule(pattern: #"multi|\bmv\b|quad"#, icon: .multiview),
        IconRule(pattern: #"retarget"#, icon: .retarget),
        IconRule(pattern: #"mocap|motion.?cap"#, icon: .motionCapture),
        IconRule(pattern: #"simulcam|simul"#, icon: .simulcam),
        IconRule(pattern: #"engine|render|unreal|helios"#, icon: .engine),
        IconRule(pattern: #"scope|wfm|wave"#, icon: .scopes),
        IconRule(pattern: #"record|\brec\b|hyperdeck|\bhdk\b"#, icon: .record),
        IconRule(pattern: #"playback|\bpb\b|player"#, icon: .playback),
        IconRule(pattern: #"graphic|\bcg\b|title"#, icon: .graphics),
        IconRule(pattern: #"laptop|macbook|\bmac\b|\bpc\b"#, icon: .laptop),
        IconRule(pattern: #"convert|\bsdi\b|\bhdmi\b|updown|\bufc\b"#, icon: .converter),
        IconRule(pattern: #"return|\brtn\b|\bref\b"#, icon: .return),
        IconRule(pattern: #"router|videohub|\bvh\b"#, icon: .router),
        IconRule(
            pattern: #"monitor|\bmon\b|flanders|smallhd|display|\btv\b|desk|screen"#,
            icon: .monitor
        ),
    ]

    static func icon(for label: String) -> VideohubIcon {
        let lowered: String = label.lowercased()
        for rule in iconRules {
            let match = lowered.range(of: rule.pattern, options: .regularExpression)
            if match != nil { return rule.icon }
        }
        return .genericVideo
    }

    /// Approximate RGB for each accent, used to map a Companion background
    /// color to the nearest thing the app can draw.
    ///
    /// A named struct rather than a tuple, and each field spelled out: a large
    /// literal of labelled tuples is one of the reliable ways to make the Swift
    /// type checker give up on a file.
    struct AccentSwatch: Sendable {
        let accent: PortAccentColor
        let red: Int
        let green: Int
        let blue: Int
    }

    private static let accentSwatches: [AccentSwatch] = [
        AccentSwatch(accent: .blue, red: 0x25, green: 0x63, blue: 0xEB),
        AccentSwatch(accent: .cyan, red: 0x08, green: 0x91, blue: 0xB2),
        AccentSwatch(accent: .green, red: 0x16, green: 0xA3, blue: 0x4A),
        AccentSwatch(accent: .yellow, red: 0xCA, green: 0x8A, blue: 0x04),
        AccentSwatch(accent: .orange, red: 0xEA, green: 0x58, blue: 0x0C),
        AccentSwatch(accent: .red, red: 0xDC, green: 0x26, blue: 0x26),
        AccentSwatch(accent: .purple, red: 0x7C, green: 0x3A, blue: 0xED),
        AccentSwatch(accent: .pink, red: 0xDB, green: 0x27, blue: 0x77),
        AccentSwatch(accent: .teal, red: 0x0D, green: 0x94, blue: 0x88),
        AccentSwatch(accent: .indigo, red: 0x4F, green: 0x46, blue: 0xE5),
        AccentSwatch(accent: .mint, red: 0x10, green: 0xB9, blue: 0x81),
        AccentSwatch(accent: .lime, red: 0x65, green: 0xA3, blue: 0x0D),
        AccentSwatch(accent: .amber, red: 0xD9, green: 0x77, blue: 0x06),
        AccentSwatch(accent: .brown, red: 0x78, green: 0x35, blue: 0x0F),
        AccentSwatch(accent: .slate, red: 0x47, green: 0x55, blue: 0x69),
    ]

    static func nearestAccent(_ packedRGB: Int) -> PortAccentColor? {
        let red: Int = (packedRGB >> 16) & 0xFF
        let green: Int = (packedRGB >> 8) & 0xFF
        let blue: Int = packedRGB & 0xFF

        // Near-black is Companion's default background, not a deliberate
        // choice, so it must not drag every port onto the same dark accent.
        let brightness: Int = red + green + blue
        guard brightness >= 40 else { return nil }

        var best: PortAccentColor?
        var bestDistance: Int = .max

        for swatch in accentSwatches {
            let deltaRed: Int = red - swatch.red
            let deltaGreen: Int = green - swatch.green
            let deltaBlue: Int = blue - swatch.blue

            // Split across statements rather than one sum of three products.
            var distance: Int = deltaRed * deltaRed
            distance += deltaGreen * deltaGreen
            distance += deltaBlue * deltaBlue

            if distance < bestDistance {
                best = swatch.accent
                bestDistance = distance
            }
        }
        return best
    }

    /// Discards page names that describe a signal type rather than a place.
    ///
    /// Most Companion pages are one destination — "BrainBar Mon", "VV Left" —
    /// and the page name is exactly what that output should be called. But some
    /// pages are organised by signal instead ("EXT LUT", "INT LUT") and route to
    /// many different outputs. Naming eight destinations "EXT LUT" is worse than
    /// leaving them with their router labels, so those names are dropped.
    private static func dropSharedDestinationNames(
        _ destinationNames: [Int: [String: Int]],
        limit: Int = 2
    ) -> [Int: [String: Int]] {
        var winners: [Int: String] = [:]
        for (index, names) in destinationNames {
            guard let winner = mostCommon(names) else { continue }
            winners[index] = winner
        }

        var usage: [String: Int] = [:]
        for name in winners.values { usage[name, default: 0] += 1 }

        return destinationNames.filter { index, names in
            guard !names.isEmpty, let winner = winners[index] else { return false }
            return (usage[winner] ?? 0) <= limit
        }
    }

    /// Highest count wins; ties break alphabetically so a given file always
    /// imports identically.
    ///
    /// The Python script leaves ties to `Counter` insertion order. Here they
    /// are resolved explicitly, because an import that reshuffles names between
    /// runs would be impossible to trust on a show day.
    private static func mostCommon(_ counts: [String: Int]) -> String? {
        var bestKey: String?
        var bestCount: Int = .min

        for (key, count) in counts {
            if count > bestCount {
                bestKey = key
                bestCount = count
            } else if count == bestCount, let current = bestKey, key < current {
                bestKey = key
            }
        }
        return bestKey
    }

    private static func mostCommonAccent(_ counts: [PortAccentColor: Int]) -> PortAccentColor? {
        var bestAccent: PortAccentColor?
        var bestCount: Int = .min

        for (accent, count) in counts {
            if count > bestCount {
                bestAccent = accent
                bestCount = count
            } else if count == bestCount, let current = bestAccent, accent.rawValue < current.rawValue {
                bestAccent = accent
            }
        }
        return bestAccent
    }

    private static func buildEntries(
        sourceNames: [Int: [String: Int]],
        sourceColors: [Int: [PortAccentColor: Int]],
        destinationNames: [Int: [String: Int]]
    ) -> [Entry] {
        var entries: [Entry] = []

        for index in sourceNames.keys.sorted() {
            guard index >= 0, let name = mostCommon(sourceNames[index] ?? [:]) else { continue }
            let accent = sourceColors[index].flatMap(mostCommonAccent) ?? .blue
            entries.append(
                Entry(
                    kind: .source,
                    protocolPortIndex: index,
                    name: name,
                    accentColor: accent,
                    icon: icon(for: name)
                )
            )
        }

        for index in destinationNames.keys.sorted() {
            guard index >= 0, let name = mostCommon(destinationNames[index] ?? [:]) else { continue }
            entries.append(
                Entry(
                    kind: .destination,
                    protocolPortIndex: index,
                    name: name,
                    accentColor: .slate,
                    icon: icon(for: name)
                )
            )
        }

        return entries
    }
}

// MARK: - Gzip

/// Just enough gzip to open a `.companionconfig`.
///
/// Apple's `Compression` framework speaks raw DEFLATE, not the gzip container,
/// so the header has to be stepped over by hand before the payload is handed to
/// it. Pulling in a third-party zlib wrapper for one file read would be a poor
/// trade.
enum Gzip {
    static func isGzipped(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0x1F && data[data.startIndex + 1] == 0x8B
    }

    static func inflate(_ data: Data) throws -> Data {
        let body = Data(data)   // Normalise indices; a sliced Data does not start at 0.
        guard body.count > 18, body[0] == 0x1F, body[1] == 0x8B, body[2] == 0x08 else {
            throw CompanionConfigImport.Failure.corruptArchive
        }

        let flags = body[3]
        var cursor = 10

        if flags & 0x04 != 0 {                     // FEXTRA
            let headerEnd: Int = cursor + 2
            guard headerEnd <= body.count else { throw CompanionConfigImport.Failure.corruptArchive }
            let low: Int = Int(body[cursor])
            let high: Int = Int(body[cursor + 1]) << 8
            let extraLength: Int = low | high
            cursor = headerEnd + extraLength
        }
        if flags & 0x08 != 0 {                     // FNAME
            cursor = try skipZeroTerminated(in: body, from: cursor)
        }
        if flags & 0x10 != 0 {                     // FCOMMENT
            cursor = try skipZeroTerminated(in: body, from: cursor)
        }
        if flags & 0x02 != 0 {                     // FHCRC
            cursor += 2
        }

        // The last 8 bytes are CRC32 + ISIZE, not deflate payload.
        let payloadEnd: Int = body.count - 8
        guard cursor < payloadEnd else { throw CompanionConfigImport.Failure.corruptArchive }
        let deflated: Data = body.subdata(in: cursor..<payloadEnd)

        // ISIZE is the little-endian uncompressed length, used only to size the
        // output buffer. A wrong value costs a reallocation, not correctness.
        var expandedSize: Int = 0
        for byte in body.suffix(4).reversed() {
            expandedSize = expandedSize << 8
            expandedSize |= Int(byte)
        }

        return try rawInflate(deflated, expectedSize: expandedSize)
    }

    private static func skipZeroTerminated(in data: Data, from start: Int) throws -> Int {
        var cursor = start
        while cursor < data.count, data[cursor] != 0 { cursor += 1 }
        guard cursor < data.count else { throw CompanionConfigImport.Failure.corruptArchive }
        return cursor + 1
    }

    private static func rawInflate(_ deflated: Data, expectedSize: Int) throws -> Data {
        var stream = compression_stream(
            dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: -1)!,
            dst_size: 0,
            src_ptr: UnsafePointer<UInt8>(bitPattern: -1)!,
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(
            &stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB
        ) == COMPRESSION_STATUS_OK else {
            throw CompanionConfigImport.Failure.corruptArchive
        }
        defer { compression_stream_destroy(&stream) }

        let chunkSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { buffer.deallocate() }

        var output = Data()
        output.reserveCapacity(max(expectedSize, chunkSize))

        return try deflated.withUnsafeBytes { raw -> Data in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                throw CompanionConfigImport.Failure.corruptArchive
            }
            stream.src_ptr = base
            stream.src_size = raw.count

            while true {
                stream.dst_ptr = buffer
                stream.dst_size = chunkSize

                let status = compression_stream_process(
                    &stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                )
                output.append(buffer, count: chunkSize - stream.dst_size)

                switch status {
                case COMPRESSION_STATUS_END:
                    return output
                case COMPRESSION_STATUS_OK:
                    continue
                default:
                    throw CompanionConfigImport.Failure.corruptArchive
                }
            }
        }
    }
}
