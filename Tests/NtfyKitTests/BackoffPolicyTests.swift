import Testing
@testable import NtfyKit

/// Randomness is injected so the schedule is asserted exactly, not sampled.
private let noJitter: @Sendable () -> Double = { 0.0 }
private let maxJitter: @Sendable () -> Double = { 1.0 }

@Test func firstAttemptWaitsTheBaseDelay() {
    let p = BackoffPolicy.standard
    #expect(p.delay(forAttempt: 1, randomFraction: noJitter) == .seconds(1))
}

@Test func delayDoublesPerAttempt() {
    let p = BackoffPolicy.standard
    #expect(p.delay(forAttempt: 2, randomFraction: noJitter) == .seconds(2))
    #expect(p.delay(forAttempt: 3, randomFraction: noJitter) == .seconds(4))
    #expect(p.delay(forAttempt: 4, randomFraction: noJitter) == .seconds(8))
}

@Test func delayIsCapped() {
    let p = BackoffPolicy.standard
    #expect(p.delay(forAttempt: 20, randomFraction: noJitter) == .seconds(60))
}

/// Jitter only ever adds, and never pushes past the cap.
@Test func jitterStaysWithinItsFraction() {
    let p = BackoffPolicy.standard
    #expect(p.delay(forAttempt: 3, randomFraction: maxJitter) == .milliseconds(4800))
    #expect(p.delay(forAttempt: 20, randomFraction: maxJitter) == .seconds(60))
}

/// Attempt numbers are 1-based; guard against a caller passing 0 or less.
@Test func nonPositiveAttemptsClampToTheBaseDelay() {
    let p = BackoffPolicy.standard
    #expect(p.delay(forAttempt: 0, randomFraction: noJitter) == .seconds(1))
    #expect(p.delay(forAttempt: -3, randomFraction: noJitter) == .seconds(1))
}
