public enum HumanReason: Equatable, Sendable { case noCredentials, passwordRejected, secondFactorRequired }

public enum SessionState: Equatable, Sendable { case idle, connecting, connected, waiting, needsHuman(HumanReason) }

public enum SessionEvent: Equatable, Sendable {
    case start(hasTicket: Bool, hasPassword: Bool)
    case serviceTicketIssued, serviceTicketRejected, loginSucceeded
    /// Wrong password, or a login phase other than plain success (2FA).
    case loginRejected(HumanReason)
    /// Network-level failure on any step.
    case transportFailed
    case socketReady, socketClosed(displaced: Bool), pingTimedOut
    case retryTimerFired, systemWoke, networkChanged
    case userRequestedLogin(hasPassword: Bool)
}

public enum SessionAction: Equatable, Sendable {
    case requestServiceTicket, loginWithPassword, openSocket, closeSocket
    case scheduleRetry(seconds: Int), cancelRetry
}

/// Decides what the session does next. Pure: no clocks, no network.
///
/// The password is used only when there is no main ticket or the server rejected it, and a
/// rejected login stops everything until the human acts, so a wrong password can never loop.
public struct SessionMachine: Sendable {
    public private(set) var state: SessionState = .idle
    private var hasTicket = false
    private var hasPassword = false
    private var failures = 0
    /// Waiting because another session of the owner took over; do not fight for the connection.
    private var yielding = false

    static let maxBackoff = 300
    static let displacedDelay = 900

    public init() {}

    public mutating func handle(_ event: SessionEvent) -> [SessionAction] {
        if case .userRequestedLogin(let password) = event {
            guard state != .idle else { return [] }
            hasPassword = password
            failures = 0
            yielding = false
            return [.cancelRetry, .closeSocket] + connect()
        }

        switch state {
        case .idle:
            guard case .start(let ticket, let password) = event else { return [] }
            hasTicket = ticket
            hasPassword = password
            return connect()

        case .needsHuman:
            return []

        case .connecting:
            switch event {
            case .serviceTicketIssued:
                return [.openSocket]
            case .serviceTicketRejected:
                hasTicket = false
                return connect()
            case .loginSucceeded:
                hasTicket = true
                return [.requestServiceTicket]
            case .loginRejected(let reason):
                state = .needsHuman(reason)
                return [.cancelRetry]
            case .socketReady:
                state = .connected
                failures = 0
                return []
            case .transportFailed, .socketClosed(displaced: false):
                return backOff()
            case .socketClosed(displaced: true):
                return yield()
            default:
                return []
            }

        case .connected:
            switch event {
            case .socketClosed(displaced: false):
                return backOff()
            case .socketClosed(displaced: true):
                return yield()
            case .pingTimedOut:
                return [.closeSocket] + backOff()
            case .systemWoke, .networkChanged:
                return [.cancelRetry, .closeSocket] + connect()
            default:
                return []
            }

        case .waiting:
            switch event {
            case .retryTimerFired:
                yielding = false
                return connect()
            case .systemWoke, .networkChanged:
                guard !yielding else { return [] }
                return [.cancelRetry, .closeSocket] + connect()
            default:
                return []
            }
        }
    }

    private mutating func connect() -> [SessionAction] {
        if hasTicket {
            state = .connecting
            return [.requestServiceTicket]
        }
        if hasPassword {
            state = .connecting
            return [.loginWithPassword]
        }
        state = .needsHuman(.noCredentials)
        return []
    }

    private mutating func backOff() -> [SessionAction] {
        failures += 1
        state = .waiting
        let seconds = failures >= 9 ? Self.maxBackoff : min(Self.maxBackoff, 1 << failures)
        return [.scheduleRetry(seconds: seconds)]
    }

    private mutating func yield() -> [SessionAction] {
        state = .waiting
        yielding = true
        return [.scheduleRetry(seconds: Self.displacedDelay)]
    }
}
