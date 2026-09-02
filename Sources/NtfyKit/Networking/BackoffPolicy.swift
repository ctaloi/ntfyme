import Foundation

/// Exponential reconnect backoff with additive jitter, capped.
///
/// Jitter is additive rather than symmetric so a delay never falls below the
/// exponential floor, which is what prevents a fleet of clients from
/// synchronising their reconnects after a server restart.
public struct BackoffPolicy: Sendable, Equatable {
    public let base: Duration
    public let multiplier: Double
    public let cap: Duration
    public let jitterFraction: Double

    public static let standard = BackoffPolicy(
        base: .seconds(1), multiplier: 2, cap: .seconds(60), jitterFraction: 0.2
    )

    public init(base: Duration, multiplier: Double, cap: Duration, jitterFraction: Double) {
        self.base = base
        self.multiplier = multiplier
        self.cap = cap
        self.jitterFraction = jitterFraction
    }

    /// - Parameter randomFraction: returns a value in `0...1`. Injected so tests
    ///   can assert the schedule exactly.
    public func delay(forAttempt attempt: Int, randomFraction: () -> Double) -> Duration {
        let steps = Swift.max(0, attempt - 1)
        let baseSeconds = seconds(base)
        let capSeconds = seconds(cap)

        let exponential = Swift.min(baseSeconds * pow(multiplier, Double(steps)), capSeconds)
        let jittered = exponential * (1 + jitterFraction * randomFraction().clamped(to: 0...1))

        return .milliseconds(Int((Swift.min(jittered, capSeconds) * 1000).rounded()))
    }

    private func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
