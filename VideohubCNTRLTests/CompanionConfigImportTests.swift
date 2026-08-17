import Foundation
import Testing
@testable import VideohubCNTRL

/// The Swift importer and `script/import_companion_config.py` must agree: both
/// are offered to operators and a cart imported one way then re-imported the
/// other must not shuffle names around.
///
/// Every expectation below was captured by running the Python script against
/// this exact fixture, so a divergence here is a real behavioural drift rather
/// than a guess about what the script does.
@Suite("Companion config import")
struct CompanionConfigImportTests {

    // MARK: - Fixture

    /// A gzipped `.companionconfig` exercising label voting, near-black
    /// rejection, shared destination names, markup stripping and a second
    /// Videohub connection.
    /// Held as an array and joined rather than a chain of `+`: eleven
    /// concatenated string literals is enough to slow the type checker down.
    private static let gzippedFixtureBase64: String = [
        "H4sICICFdGcC/2ZpeHR1cmUuY29tcGFuaW9uY29uZmlnAO2XXWvbMBSG/4owu9hgMMuWHaeUQtMP",
        "Wmg36Ec2WMeQ7bNEVJGMLKcNxf99kt0y+yZowTMMcmPZ0qtzjh5Jx9KLtwZVMim8A0Q+Io+JUlOR",
        "QWm+X7z1Ejclpylw8+bdrqjSaM5ykMsq9WrTY70M+poZzR6rAl3Ydiso6OLVXGtM0BU0OkWZmFGF",
        "ro13o8uk0EryVup3nnpTNB3SSutWWuoNh1evGxO/ef3+R6fhWVtVUzbDoLxqWk7oCh03UXWsyufW",
        "O5eqpw5I5BOM6/pH3biEohsazbSh9rME3dbm8km0YZhxCGhaL3PrwEI0BmRhq1pxKSuVQc+bb53k",
        "UGomqG7no9too6gbnHhgJhdGoU4he0TYlQwmJJjESTwSGuyKJhgYzb1QQDk6EwsmwB1OEkZTMhKb",
        "wJVNODCbc05FbvWOWPyRgIROQLrr5S0fzefoCn7pfSramorwP0xFX5UUC/TZzsf/DWboRHRdcc3W",
        "DJ7+IkeHwSSM/bHyEHFC001Fb9vu7Nsdurq/G2nb3Z5eohMpzKFHg3JlGcU4Gu1vF20jGfRJkj3J",
        "XUmGfZLRnuSuJEmfZLwnuSvJqE9y0iP5RS9BoRtZ2aGNg/NcKmALgcxZxf30G8YBSSYD4AwccE63",
        "4Zz2cSb90x7j3FxM0WF6ZO6fh5/So5Gg3oCulEDv3jNhZlJQfmAvyB8QOn54EDNXzgkmOCLTkVZt",
        "vA1z3MFc178BNm4c9FEQAAA=",
    ].joined()

    private static func gzippedFixture() throws -> Data {
        try #require(Data(base64Encoded: gzippedFixtureBase64, options: [.ignoreUnknownCharacters]))
    }

    private static let router = "169.254.171.201"

    /// Flattened `kind/uiNumber/name/color/icon`, matching the script's preview
    /// columns so the two can be compared by eye as well as by assertion.
    private func rows(_ preview: CompanionConfigImport.Preview) -> [String] {
        var result: [String] = []
        for entry in preview.entries {
            let kind: String = entry.kind.rawValue
            let number: Int = entry.uiNumber
            let color: String = entry.accentColor.rawValue
            let icon: String = entry.icon.rawValue
            result.append("\(kind) \(number) \(entry.name) \(color) \(icon)")
        }
        return result
    }

    // MARK: - Parsing

    @Test("Filtering to one connection matches the Python script exactly")
    func filteredImportMatchesScript() throws {
        let preview = try CompanionConfigImport.preview(
            configurationData: Self.gzippedFixture(),
            routerIdentity: Self.router,
            connectionID: "vh1"
        )

        #expect(preview.routerIdentity == Self.router)
        #expect(preview.sources.count == 7)
        #expect(preview.destinations.count == 3)
        #expect(rows(preview) == [
            "source 1 Cam A blue camera",
            "source 2 HyperDeck 1 red record",
            "source 3 Unreal Engine green engine",
            "source 4 Flanders blue monitor",
            "source 5 Multiview 1 yellow multiview",
            "source 6 SDI Converter cyan converter",
            "source 7 Return A B purple return",
            "destination 1 BrainBar Mon slate monitor",
            "destination 2 VV Left slate genericVideo",
            "destination 7 Village Mon slate monitor",
        ])
    }

    @Test("Accepting every connection matches the Python script exactly")
    func unfilteredImportMatchesScript() throws {
        let preview = try CompanionConfigImport.preview(
            configurationData: Self.gzippedFixture(),
            routerIdentity: Self.router
        )

        #expect(preview.sources.count == 8)
        #expect(preview.destinations.count == 4)
        #expect(rows(preview).contains("source 10 Foreign Cam pink camera"))
        #expect(rows(preview).contains("destination 10 Other Router slate router"))
    }

    @Test("Connections are listed with their route key counts, busiest first")
    func connectionsAreDiscovered() throws {
        let preview = try CompanionConfigImport.preview(
            configurationData: Self.gzippedFixture(),
            routerIdentity: Self.router
        )

        #expect(preview.connections.map(\.id) == ["vh1", "vh2"])
        #expect(preview.connections.map(\.label) == ["Smart Videohub", "Backup Hub"])
        #expect(preview.connections.map(\.routeKeyCount) == [12, 1])
    }

    // MARK: - Individual rules

    @Test("The most common label wins rather than the first one seen")
    func repeatedLabelWins() throws {
        // Source 0 is labelled "Cam A" twice and "Wrong Name" once.
        let preview = try CompanionConfigImport.preview(
            configurationData: Self.gzippedFixture(),
            routerIdentity: Self.router,
            connectionID: "vh1"
        )
        let source = try #require(preview.sources.first { $0.protocolPortIndex == 0 })
        #expect(source.name == "Cam A")
    }

    @Test("A page name used by many destinations describes a signal, not a place")
    func sharedDestinationNamesAreDropped() throws {
        // Four pages named "EXT LUT" route to destinations 2-5. Naming four
        // outputs the same thing is worse than leaving their router labels.
        let preview = try CompanionConfigImport.preview(
            configurationData: Self.gzippedFixture(),
            routerIdentity: Self.router,
            connectionID: "vh1"
        )
        #expect(!preview.destinations.contains { $0.name == "EXT LUT" })
        #expect(preview.destinations.map(\.protocolPortIndex) == [0, 1, 6])
    }

    @Test("Companion's default near-black background is not a colour choice")
    func nearBlackFallsBackToDefaultAccent() throws {
        let preview = try CompanionConfigImport.preview(
            configurationData: Self.gzippedFixture(),
            routerIdentity: Self.router,
            connectionID: "vh1"
        )
        let flanders = try #require(preview.sources.first { $0.name == "Flanders" })
        #expect(flanders.accentColor == .blue)
        #expect(CompanionConfigImport.nearestAccent(0x000000) == nil)
        #expect(CompanionConfigImport.nearestAccent(0x101010) == nil)
        #expect(CompanionConfigImport.nearestAccent(0x2563EB) == .blue)
        #expect(CompanionConfigImport.nearestAccent(0xDC2626) == .red)
    }

    @Test("Variables and markup are stripped out of labels")
    func labelsAreCleaned() {
        #expect(CompanionConfigImport.cleanLabel(#"Return $(internal:page)  A\nB"#) == "Return A B")
        #expect(CompanionConfigImport.cleanLabel("Village <b>Mon</b>") == "Village Mon")
        #expect(CompanionConfigImport.cleanLabel("  spaced   out  ") == "spaced out")
    }

    @Test("Icon rules prefer the specific term over the generic one")
    func iconRulesAreOrdered() {
        #expect(CompanionConfigImport.icon(for: "Cam A") == .camera)
        #expect(CompanionConfigImport.icon(for: "Multiview 1") == .multiview)
        #expect(CompanionConfigImport.icon(for: "HyperDeck 1") == .record)
        #expect(CompanionConfigImport.icon(for: "Unreal Engine") == .engine)
        #expect(CompanionConfigImport.icon(for: "SDI Converter") == .converter)
        #expect(CompanionConfigImport.icon(for: "Flanders") == .monitor)
        #expect(CompanionConfigImport.icon(for: "Nothing In Particular") == .genericVideo)
    }

    // MARK: - Container handling

    @Test("Plain JSON exports parse identically to gzipped ones")
    func plainJSONMatchesGzipped() throws {
        let gzipped = try Self.gzippedFixture()
        let plain = try Gzip.inflate(gzipped)

        #expect(Gzip.isGzipped(gzipped))
        #expect(!Gzip.isGzipped(plain))

        let fromGzip = try CompanionConfigImport.preview(
            configurationData: gzipped, routerIdentity: Self.router, connectionID: "vh1"
        )
        let fromPlain = try CompanionConfigImport.preview(
            configurationData: plain, routerIdentity: Self.router, connectionID: "vh1"
        )
        #expect(fromGzip == fromPlain)
    }

    @Test("Inflating produces well-formed JSON of the expected size")
    func gzipRoundTripsToJSON() throws {
        let plain = try Gzip.inflate(Self.gzippedFixture())
        #expect(plain.count == 4_177)

        let root = try #require(
            try JSONSerialization.jsonObject(with: plain) as? [String: Any]
        )
        #expect(root["pages"] != nil)
        #expect(root["instances"] != nil)
    }

    // MARK: - Refusals

    @Test("A file that is not a Companion export is refused")
    func nonCompanionFileIsRefused() {
        let data = Data(#"{"hello":"world"}"#.utf8)
        #expect(throws: CompanionConfigImport.Failure.notCompanionConfig) {
            try CompanionConfigImport.preview(
                configurationData: data, routerIdentity: Self.router
            )
        }
    }

    @Test("Importing without a router identity is refused")
    func missingRouterIdentityIsRefused() throws {
        let data = try Self.gzippedFixture()
        #expect(throws: CompanionConfigImport.Failure.noRouterIdentity) {
            try CompanionConfigImport.preview(configurationData: data, routerIdentity: "   ")
        }
    }

    @Test("An export with no Videohub routing keys is refused")
    func exportWithoutRoutesIsRefused() {
        let data = Data(#"{"instances":{},"pages":{"1":{"name":"Empty","controls":{}}}}"#.utf8)
        #expect(throws: CompanionConfigImport.Failure.noRoutesFound) {
            try CompanionConfigImport.preview(
                configurationData: data, routerIdentity: Self.router
            )
        }
    }

    @Test("Truncated gzip is reported rather than crashing")
    func truncatedArchiveIsRefused() throws {
        let truncated = try Self.gzippedFixture().prefix(40)
        #expect(throws: CompanionConfigImport.Failure.corruptArchive) {
            try Gzip.inflate(Data(truncated))
        }
    }

    // MARK: - Router identity

    @Test("The router identity is lowercased so it matches stored keys")
    func routerIdentityIsNormalized() throws {
        let preview = try CompanionConfigImport.preview(
            configurationData: Self.gzippedFixture(),
            routerIdentity: "  Videohub.LOCAL  "
        )
        #expect(preview.routerIdentity == "videohub.local")
    }

    @Test("Preview converts to customization keys aimed at one router only")
    func customizationsCarryTheRouterIdentity() throws {
        let preview = try CompanionConfigImport.preview(
            configurationData: Self.gzippedFixture(),
            routerIdentity: Self.router,
            connectionID: "vh1"
        )
        let customizations = preview.customizations

        #expect(customizations.count == preview.entries.count)
        #expect(customizations.keys.allSatisfy { $0.routerIdentity == Self.router })
        #expect(customizations.keys.allSatisfy(\.isValid))

        let camA = PortCustomizationKey(
            routerIdentity: Self.router, kind: .source, protocolPortIndex: 0
        )
        #expect(customizations[camA]?.displayNameOverride == "Cam A")
        #expect(customizations[camA]?.icon == .camera)
    }
}

@MainActor
@Suite("Customization store bulk replacement")
struct CustomizationStoreReplacementTests {
    private func temporaryStore() -> CustomizationStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompanionImport-\(UUID().uuidString)", isDirectory: true)
        return CustomizationStore(
            fileURL: directory.appendingPathComponent(CustomizationStore.fileName)
        )
    }

    private func key(_ router: String, _ index: Int) -> PortCustomizationKey {
        PortCustomizationKey(routerIdentity: router, kind: .source, protocolPortIndex: index)
    }

    @Test("Replacing one router leaves other routers untouched")
    func replacementIsScopedToOneRouter() {
        let store = temporaryStore()
        store.set(PortCustomization(displayNameOverride: "Keep Me"), for: key("router-b", 0))
        store.set(PortCustomization(displayNameOverride: "Replace Me"), for: key("router-a", 0))
        store.set(PortCustomization(displayNameOverride: "Drop Me"), for: key("router-a", 1))

        let applied = store.replaceCustomizations(
            forRouter: "router-a",
            with: [key("router-a", 0): PortCustomization(displayNameOverride: "Imported")]
        )

        #expect(applied)
        #expect(store.customization(for: key("router-a", 0))?.displayNameOverride == "Imported")
        // Stale entries from a previous cart layout must not survive.
        #expect(store.customization(for: key("router-a", 1)) == nil)
        #expect(store.customization(for: key("router-b", 0))?.displayNameOverride == "Keep Me")
    }

    @Test("A batch aimed at the wrong router is refused whole")
    func mismatchedRouterIsRefused() {
        let store = temporaryStore()
        store.set(PortCustomization(displayNameOverride: "Original"), for: key("router-a", 0))

        let applied = store.replaceCustomizations(
            forRouter: "router-a",
            with: [key("router-b", 0): PortCustomization(displayNameOverride: "Wrong")]
        )

        #expect(!applied)
        #expect(store.lastError == .invalidKey)
        #expect(store.customization(for: key("router-a", 0))?.displayNameOverride == "Original")
    }

    @Test("Replacing with nothing clears that router")
    func emptyReplacementClearsRouter() {
        let store = temporaryStore()
        store.set(PortCustomization(displayNameOverride: "Gone"), for: key("router-a", 0))

        #expect(store.replaceCustomizations(forRouter: "router-a", with: [:]))
        #expect(store.customization(for: key("router-a", 0)) == nil)
    }

    @Test("Replacements survive a reload from disk")
    func replacementPersists() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompanionImport-\(UUID().uuidString)", isDirectory: true)
        let location = directory.appendingPathComponent(CustomizationStore.fileName)

        let store = CustomizationStore(fileURL: location)
        #expect(
            store.replaceCustomizations(
                forRouter: "router-a",
                with: [key("router-a", 3): PortCustomization(
                    displayNameOverride: "Cam A", accentColor: .red, icon: .camera
                )]
            )
        )

        let reloaded = CustomizationStore(fileURL: location)
        let restored = reloaded.customization(for: key("router-a", 3))
        #expect(restored?.displayNameOverride == "Cam A")
        #expect(restored?.accentColor == .red)
        #expect(restored?.icon == .camera)
    }
}
