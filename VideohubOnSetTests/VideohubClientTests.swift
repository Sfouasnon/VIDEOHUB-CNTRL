import Testing
@testable import VideohubOnSet

@Suite("Videohub client reconnect policy")
struct VideohubClientTests {
    @Test("Backoff resets only after an explicitly synchronized session")
    func reconnectBackoffReset() {
        var backoff = VideohubReconnectBackoff()

        #expect(backoff.nextDelay() == 1)
        #expect(backoff.nextDelay() == 2)
        #expect(backoff.nextDelay() == 4)
        #expect(backoff.nextDelay() == 8)
        #expect(backoff.nextDelay() == 12)
        #expect(backoff.nextDelay() == 12)

        backoff.reset()

        #expect(backoff.attempt == 0)
        #expect(backoff.nextDelay() == 1)
    }
}
