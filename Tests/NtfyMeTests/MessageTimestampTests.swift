import Foundation
import Testing
@testable import NtfyMe

/// `MessageTimestamp` — the list row's time column. Every case is a boundary
/// against "now", which is why the function takes `now` rather than reading
/// the clock: none of this would be testable otherwise.
///
/// A fixed calendar and time zone, so a boundary does not pass or fail
/// depending on where the machine running the tests is.

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

/// Wednesday, 3 September 2025, 12:00 UTC.
private let now = calendar.date(from: DateComponents(
    year: 2025, month: 9, day: 3, hour: 12, minute: 0))!

private func text(_ date: Date) -> String {
    MessageTimestamp.text(for: date, now: now, calendar: calendar)
}

@Test func underAMinuteReadsAsNow() {
    #expect(text(now) == "now")
    #expect(text(now.addingTimeInterval(-59)) == "now")
}

/// A publisher's clock can be ahead, and ntfy's delayed delivery carries a
/// scheduled time — so a future date has to read as something, and "now" is
/// better than a negative minute count.
@Test func aFutureDateReadsAsNowRatherThanNegative() {
    #expect(text(now.addingTimeInterval(600)) == "now")
}

@Test func withinTheHourReadsAsMinutes() {
    #expect(text(now.addingTimeInterval(-60)) == "1m")
    #expect(text(now.addingTimeInterval(-4 * 60)) == "4m")
    #expect(text(now.addingTimeInterval(-59 * 60)) == "59m")
}

/// Earlier today, past the hour: a clock time. This is the case the old
/// behaviour got right and the only one it got right.
///
/// Asserts the *shape*, not a particular hour: `formatted()` renders in the
/// machine's own time zone and locale — as it should, since a user reads
/// these in their zone — so a UTC-constructed 08:04 comes back as "4:04 AM"
/// on a machine in EDT. Pinning the hour would pin the time zone of
/// whoever ran the tests, which is how a test starts failing on a
/// colleague's laptop for no reason.
@Test func earlierTodayReadsAsAClockTime() {
    let earlier = calendar.date(from: DateComponents(
        year: 2025, month: 9, day: 3, hour: 8, minute: 4))!
    let rendered = text(earlier)
    #expect(rendered.contains(":"), "a clock time, not a weekday or a date")
    #expect(rendered != "Yesterday")
    #expect(!rendered.contains("Sep"))
}

@Test func yesterdayIsNamed() {
    let yesterdayEvening = calendar.date(from: DateComponents(
        year: 2025, month: 9, day: 2, hour: 22, minute: 30))!
    #expect(text(yesterdayEvening) == "Yesterday")
}

/// Two days ago is inside the week, so it is a weekday — the case that was
/// previously indistinguishable from four minutes ago.
@Test func earlierThisWeekIsAWeekday() {
    let monday = calendar.date(from: DateComponents(
        year: 2025, month: 9, day: 1, hour: 9, minute: 0))!
    #expect(text(monday) == "Mon")
}

@Test func olderThanAWeekIsADate() {
    let lastMonth = calendar.date(from: DateComponents(
        year: 2025, month: 8, day: 12, hour: 9, minute: 0))!
    let rendered = text(lastMonth)
    #expect(rendered.contains("12"))
    #expect(rendered.contains("Aug"))
    // Same year, so no year — it would be noise on every row.
    #expect(!rendered.contains("2025"))
}

@Test func anotherYearCarriesTheYear() {
    let lastYear = calendar.date(from: DateComponents(
        year: 2024, month: 12, day: 20, hour: 9, minute: 0))!
    let rendered = text(lastYear)
    #expect(rendered.contains("2024"))
    #expect(rendered.contains("Dec"))
}

/// The seven-day cutoff is elapsed time, not "this calendar week", so the
/// column does not change meaning depending on which day it is read.
@Test func theWeekBoundaryIsSevenDaysNotTheCalendarWeek() {
    let sixDays = now.addingTimeInterval(-6 * 24 * 3600)
    let eightDays = now.addingTimeInterval(-8 * 24 * 3600)
    #expect(MessageTimestamp.text(for: sixDays, now: now, calendar: calendar).count <= 3,
            "a weekday abbreviation")
    #expect(MessageTimestamp.text(for: eightDays, now: now, calendar: calendar).contains("Aug"))
}
