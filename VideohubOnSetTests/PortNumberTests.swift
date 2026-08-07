import Testing
@testable import VideohubOnSet

@Suite("Port number conversion")
struct PortNumberTests {
    @Test
    func protocolZeroIsPhysicalPortOne() {
        let port = PortNumber(protocolIndex: 0)
        #expect(port?.uiNumber == 1)
    }

    @Test
    func physicalPortOneIsProtocolZero() {
        let port = PortNumber(uiNumber: 1)
        #expect(port?.protocolIndex == 0)
    }

    @Test
    func invalidPortNumbersAreRejected() {
        #expect(PortNumber(protocolIndex: -1) == nil)
        #expect(PortNumber(uiNumber: 0) == nil)
    }
}
