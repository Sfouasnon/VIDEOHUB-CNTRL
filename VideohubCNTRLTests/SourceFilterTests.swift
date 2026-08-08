import Testing
@testable import VideohubCNTRL

@Suite("Source filters")
struct SourceFilterTests {
    @Test("Configured icons map to the required filter chips", arguments: [
        (VideohubIcon.camera, SourceFilter.cameras),
        (.playback, .playback),
        (.graphics, .graphics),
        (.return, .returns),
        (.monitor, .village),
        (.router, .utility),
        (.multiview, .utility),
        (.record, .utility),
        (.genericVideo, .utility),
    ])
    func mapsIconSemantics(icon: VideohubIcon, expectedFilter: SourceFilter) {
        let presentation = presentation(icon: icon)

        #expect(expectedFilter.matches(presentation))
        #expect(SourceFilter.all.matches(presentation))
    }

    @Test("An exact configured group can opt into a filter")
    func exactGroupMatches() {
        let presentation = presentation(
            displayName: "Unclassified feed",
            group: "cAmErAs",
            icon: .genericVideo
        )

        #expect(SourceFilter.cameras.matches(presentation))
    }

    @Test(
        "Every configured filter group matches case-insensitively",
        arguments: SourceFilter.allCases.filter { $0 != .all }
    )
    func everyConfiguredGroupMatches(_ filter: SourceFilter) {
        let presentation = presentation(
            group: filter.rawValue.lowercased(),
            icon: .genericVideo
        )

        #expect(filter.matches(presentation))
    }

    @Test("Display names never infer a filter")
    func displayNameDoesNotInferMeaning() {
        let presentation = presentation(
            displayName: "Camera Playback Graphics Return",
            group: "Studio A",
            icon: .genericVideo
        )

        #expect(!SourceFilter.cameras.matches(presentation))
        #expect(!SourceFilter.playback.matches(presentation))
        #expect(!SourceFilter.graphics.matches(presentation))
        #expect(!SourceFilter.returns.matches(presentation))
        #expect(SourceFilter.utility.matches(presentation))
    }

    private func presentation(
        displayName: String = "Source",
        group: String? = nil,
        icon: VideohubIcon
    ) -> PortPresentation {
        PortPresentation(
            displayName: displayName,
            group: group,
            accentColor: .blue,
            icon: icon
        )
    }
}
