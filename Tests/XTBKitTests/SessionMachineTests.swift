import XCTest
@testable import XTBKit

final class SessionMachineTests: XCTestCase {
    private func connected(hasTicket: Bool = true) -> SessionMachine {
        var m = SessionMachine()
        _ = m.handle(.start(hasTicket: hasTicket, hasPassword: true))
        if !hasTicket { _ = m.handle(.loginSucceeded) }
        _ = m.handle(.serviceTicketIssued)
        _ = m.handle(.socketReady)
        XCTAssertEqual(m.state, .connected)
        return m
    }

    func testStartWithTicketRequestsServiceTicketFirst() {
        var m = SessionMachine()
        XCTAssertEqual(m.handle(.start(hasTicket: true, hasPassword: true)), [.requestServiceTicket])
        XCTAssertEqual(m.state, .connecting)
        XCTAssertEqual(m.handle(.serviceTicketIssued), [.openSocket])
        XCTAssertEqual(m.handle(.socketReady), [])
        XCTAssertEqual(m.state, .connected)
    }

    func testStartWithoutTicketLogsInWithPassword() {
        var m = SessionMachine()
        XCTAssertEqual(m.handle(.start(hasTicket: false, hasPassword: true)), [.loginWithPassword])
        XCTAssertEqual(m.handle(.loginSucceeded), [.requestServiceTicket])
    }

    func testStartWithoutPasswordNeedsHuman() {
        var m = SessionMachine()
        XCTAssertEqual(m.handle(.start(hasTicket: false, hasPassword: false)), [])
        XCTAssertEqual(m.state, .needsHuman(.noCredentials))
    }

    func testServiceTicketRejectedFallsBackToPasswordOnce() {
        var m = SessionMachine()
        _ = m.handle(.start(hasTicket: true, hasPassword: true))
        XCTAssertEqual(m.handle(.serviceTicketRejected), [.loginWithPassword])
        XCTAssertEqual(m.handle(.loginSucceeded), [.requestServiceTicket])
        XCTAssertEqual(m.handle(.serviceTicketIssued), [.openSocket])
    }

    func testServiceTicketRejectedWithoutPasswordNeedsHuman() {
        var m = SessionMachine()
        _ = m.handle(.start(hasTicket: true, hasPassword: false))
        XCTAssertEqual(m.handle(.serviceTicketRejected), [])
        XCTAssertEqual(m.state, .needsHuman(.noCredentials))
    }

    private func assertDead(_ m: inout SessionMachine, _ reason: HumanReason, line: UInt = #line) {
        let events: [SessionEvent] = [.retryTimerFired, .systemWoke, .networkChanged, .socketClosed(displaced: false),
                                      .socketClosed(displaced: true), .pingTimedOut, .transportFailed, .serviceTicketIssued,
                                      .serviceTicketRejected, .loginSucceeded, .socketReady,
                                      .start(hasTicket: false, hasPassword: true)]
        for e in events {
            XCTAssertEqual(m.handle(e), [], "\(e)", line: line)
            XCTAssertEqual(m.state, .needsHuman(reason), "\(e)", line: line)
        }
    }

    func testPasswordRejectedStopsEverything() {
        var m = SessionMachine()
        _ = m.handle(.start(hasTicket: false, hasPassword: true))
        XCTAssertEqual(m.handle(.loginRejected(.passwordRejected)), [.cancelRetry])
        assertDead(&m, .passwordRejected)
    }

    func testSecondFactorStopsEverything() {
        var m = SessionMachine()
        _ = m.handle(.start(hasTicket: false, hasPassword: true))
        _ = m.handle(.loginRejected(.secondFactorRequired))
        assertDead(&m, .secondFactorRequired)
    }

    func testUserRequestedLoginLeavesNeedsHuman() {
        var m = SessionMachine()
        _ = m.handle(.start(hasTicket: false, hasPassword: true))
        _ = m.handle(.loginRejected(.passwordRejected))
        XCTAssertEqual(m.handle(.userRequestedLogin(hasPassword: true)), [.cancelRetry, .closeSocket, .loginWithPassword])
        XCTAssertEqual(m.state, .connecting)
    }

    func testUserRequestedLoginWithoutPasswordStaysNeedsHuman() {
        var m = SessionMachine()
        _ = m.handle(.start(hasTicket: false, hasPassword: false))
        XCTAssertEqual(m.handle(.userRequestedLogin(hasPassword: false)), [.cancelRetry, .closeSocket])
        XCTAssertEqual(m.state, .needsHuman(.noCredentials))
    }

    func testUserRequestedLoginWhileConnectedUsesTicket() {
        var m = connected()
        XCTAssertEqual(m.handle(.userRequestedLogin(hasPassword: true)), [.cancelRetry, .closeSocket, .requestServiceTicket])
    }

    func testSocketDropReconnectsWithServiceTicketNotPassword() {
        var m = connected(hasTicket: false)
        XCTAssertEqual(m.handle(.socketClosed(displaced: false)), [.scheduleRetry(seconds: 2)])
        XCTAssertEqual(m.state, .waiting)
        XCTAssertEqual(m.handle(.retryTimerFired), [.requestServiceTicket])
        XCTAssertEqual(m.state, .connecting)
    }

    func testBackoffSequenceAndCap() {
        var m = connected()
        var delays: [Int] = []
        _ = m.handle(.socketClosed(displaced: false)).first.map { if case .scheduleRetry(let s) = $0 { delays.append(s) } }
        for _ in 0..<9 {
            _ = m.handle(.retryTimerFired)
            for a in m.handle(.transportFailed) { if case .scheduleRetry(let s) = a { delays.append(s) } }
        }
        XCTAssertEqual(delays, [2, 4, 8, 16, 32, 64, 128, 256, 300, 300])
    }

    func testBackoffResetsAfterSocketReady() {
        var m = connected()
        _ = m.handle(.socketClosed(displaced: false))
        _ = m.handle(.retryTimerFired)
        XCTAssertEqual(m.handle(.transportFailed), [.scheduleRetry(seconds: 4)])
        _ = m.handle(.retryTimerFired)
        _ = m.handle(.serviceTicketIssued)
        _ = m.handle(.socketReady)
        XCTAssertEqual(m.handle(.socketClosed(displaced: false)), [.scheduleRetry(seconds: 2)])
    }

    func testDisplacedWaits900Seconds() {
        var m = connected()
        XCTAssertEqual(m.handle(.socketClosed(displaced: true)), [.scheduleRetry(seconds: 900)])
        XCTAssertEqual(m.state, .waiting)
    }

    func testDisplacedIgnoresWakeAndNetworkChange() {
        var m = connected()
        _ = m.handle(.socketClosed(displaced: true))
        XCTAssertEqual(m.handle(.systemWoke), [])
        XCTAssertEqual(m.handle(.networkChanged), [])
        XCTAssertEqual(m.state, .waiting)
        XCTAssertEqual(m.handle(.retryTimerFired), [.requestServiceTicket])
    }

    func testPingTimeoutClosesAndRetries() {
        var m = connected()
        XCTAssertEqual(m.handle(.pingTimedOut), [.closeSocket, .scheduleRetry(seconds: 2)])
        XCTAssertEqual(m.state, .waiting)
    }

    func testWakeTriggersImmediateReconnect() {
        var m = connected()
        XCTAssertEqual(m.handle(.systemWoke), [.cancelRetry, .closeSocket, .requestServiceTicket])
        XCTAssertEqual(m.state, .connecting)

        var w = connected()
        _ = w.handle(.socketClosed(displaced: false))
        XCTAssertEqual(w.handle(.networkChanged), [.cancelRetry, .closeSocket, .requestServiceTicket])
    }

    func testWakeWhileConnectingDoesNothing() {
        var m = SessionMachine()
        _ = m.handle(.start(hasTicket: true, hasPassword: true))
        XCTAssertEqual(m.handle(.systemWoke), [])
        XCTAssertEqual(m.state, .connecting)
    }

    func testTransportFailureDuringPasswordLoginRetriesWithoutNeedsHuman() {
        var m = SessionMachine()
        _ = m.handle(.start(hasTicket: false, hasPassword: true))
        XCTAssertEqual(m.handle(.transportFailed), [.scheduleRetry(seconds: 2)])
        XCTAssertEqual(m.state, .waiting)
        XCTAssertEqual(m.handle(.retryTimerFired), [.loginWithPassword])
    }

    func testSocketClosedWhileConnectingRetries() {
        var m = SessionMachine()
        _ = m.handle(.start(hasTicket: true, hasPassword: true))
        _ = m.handle(.serviceTicketIssued)
        XCTAssertEqual(m.handle(.socketClosed(displaced: false)), [.scheduleRetry(seconds: 2)])
    }

    func testStaleEventsAreIgnored() {
        var m = connected()
        XCTAssertEqual(m.handle(.serviceTicketIssued), [])
        XCTAssertEqual(m.handle(.retryTimerFired), [])
        XCTAssertEqual(m.handle(.transportFailed), [])
        XCTAssertEqual(m.state, .connected)
        var idle = SessionMachine()
        XCTAssertEqual(idle.handle(.socketReady), [])
        XCTAssertEqual(idle.state, .idle)
    }

    /// Random event sequences: the password is never used while a main ticket is believed valid,
    /// and after a rejected login nothing happens until the human acts.
    func testRandomSequencesNeverUsePasswordWhileTicketValidNorAfterRejection() {
        var rng = SplitMix64(seed: 0xC0FFEE)
        let pool: [SessionEvent] = [.serviceTicketIssued, .serviceTicketRejected, .loginSucceeded,
                                    .loginRejected(.passwordRejected), .loginRejected(.secondFactorRequired),
                                    .transportFailed, .socketReady, .socketClosed(displaced: false),
                                    .socketClosed(displaced: true), .pingTimedOut, .retryTimerFired, .systemWoke,
                                    .networkChanged, .userRequestedLogin(hasPassword: true)]
        for run in 0..<1000 {
            var m = SessionMachine()
            var ticketValid = run % 2 == 0
            var dead = false
            _ = m.handle(.start(hasTicket: ticketValid, hasPassword: true))
            for _ in 0..<60 {
                let event = pool[Int(rng.next() % UInt64(pool.count))]
                let stateBefore = m.state
                let actions = m.handle(event)
                if case .userRequestedLogin = event { dead = false }
                if dead { XCTAssertEqual(actions, [], "run \(run): \(event) after rejection") }
                // Mirror what the machine can know about the ticket.
                if stateBefore == .connecting {
                    if event == .loginSucceeded { ticketValid = true }
                    if event == .serviceTicketRejected { ticketValid = false }
                    if case .loginRejected = event { dead = true }
                }
                if actions.contains(.loginWithPassword) {
                    XCTAssertFalse(ticketValid, "run \(run): password used with valid ticket on \(event)")
                }
            }
        }
    }
}

struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
