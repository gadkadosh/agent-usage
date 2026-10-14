import Foundation
import XCTest

@testable import AgentUsage

@MainActor
final class HistoryCoordinatorTests: XCTestCase {
    private let now = PiHistoryFixtures.now
    private let calendar = PiHistoryFixtures.calendar

    func testAgentsHaveSeparateIdentityNamespacesAndAlignedBucketTotals() async {
        let pi = ScriptedSource([.success(reading(100))])
        let opencode = ScriptedSource([.success(reading(200))])
        let coordinator = coordinator(pi, opencode)
        let result = await coordinator.refresh(now: now, calendar: calendar)
        XCTAssertEqual(result.summaries[.today]?.tokens, 300)
        XCTAssertEqual(result.summaries[.today]?.buckets.reduce(0) { $0 + $1.tokens }, 300)
        XCTAssertEqual(result.agents.map { $0.summaries[.today]?.tokens }, [100, 200])
        XCTAssertEqual(result.coverage.state, .ready)
        XCTAssertEqual(result.agents.map(\.agent), [.pi, .opencode])
    }

    func testOneFailedAgentKeepsLastReadingWhileOtherAgentAdvancesAndRecovers() async {
        let pi = ScriptedSource([
            .success(reading(100)), .success(reading(150)), .success(reading(160)),
        ])
        let opencode = ScriptedSource([.success(reading(200)), .failure, .success(reading(250))])
        let coordinator = coordinator(pi, opencode)
        _ = await coordinator.refresh(now: now, calendar: calendar)
        let later = now.addingTimeInterval(60)
        let failed = await coordinator.refresh(now: later, calendar: calendar)
        XCTAssertEqual(failed.summaries[.today]?.tokens, 350)
        XCTAssertEqual(failed.coverage.state, .partial)
        XCTAssertFalse(failed.agents[0].refreshFailed)
        XCTAssertTrue(failed.agents[1].refreshFailed)
        XCTAssertEqual(failed.agents[0].fetchedAt, later)
        XCTAssertEqual(failed.agents[1].fetchedAt, now)
        XCTAssertFalse(String(describing: failed).contains("sensitive payload"))
        let recovered = await coordinator.refresh(now: later, calendar: calendar)
        XCTAssertEqual(recovered.summaries[.today]?.tokens, 410)
        XCTAssertEqual(recovered.coverage.state, .ready)
        XCTAssertFalse(recovered.agents.contains { $0.refreshFailed })
    }

    func testInitialFailureAndMissingHistoryDoNotInventReadings() async {
        for step in [ScriptedSource.Step.failure, .success(reading(0, state: .missing))] {
            let pi = ScriptedSource([.success(reading(100))])
            let opencode = ScriptedSource([step])
            let result = await coordinator(pi, opencode).refresh(now: now, calendar: calendar)
            XCTAssertEqual(result.summaries[.today]?.tokens, 100)
            XCTAssertFalse(result.agents[1].coverage.hasReadings)
            XCTAssertTrue(
                result.agents[1].summaries.isEmpty || result.agents[1].coverage.state == .missing
            )
            XCTAssertEqual(
                result.coverage.state,
                result.agents[1].refreshFailed ? .partial : .ready
            )
        }
        let allFailed = await coordinator(ScriptedSource([.failure]), ScriptedSource([.failure]))
            .refresh(now: now, calendar: calendar)
        XCTAssertEqual(allFailed.coverage.state, .unavailable)
        XCTAssertFalse(allFailed.coverage.hasReadings)
        XCTAssertTrue(allFailed.agents.allSatisfy { $0.fetchedAt == nil && $0.refreshFailed })
    }

    func testUnsupportedAgentMakesCombinedTotalPartialAndIdentifiesItsStatus() async {
        let result = await coordinator(
            ScriptedSource([.success(reading(100))]),
            ScriptedSource([.success(reading(0, state: .unsupported))])
        )
        .refresh(now: now, calendar: calendar)
        XCTAssertEqual(result.summaries[.month]?.tokens, 100)
        XCTAssertEqual(result.coverage.state, .partial)
        XCTAssertEqual(result.agents[1].status, "Unsupported history")
    }

    func testCatchUpOnlyRefreshesPendingSourcesAndFreezesTheClock() async {
        var partial = reading(100)
        partial.hasMoreFiles = true
        let pi = ScriptedSource([.success(partial), .success(reading(200)), .success(reading(300))])
        let opencode = ScriptedSource([.success(reading(50)), .success(reading(75))])
        let coordinator = coordinator(pi, opencode)
        let first = await coordinator.refresh(now: now, calendar: calendar)
        XCTAssertTrue(first.hasMoreFiles)
        XCTAssertEqual(first.summaries[.today]?.tokens, 150)
        XCTAssertTrue(first.agents[0].isLoading)
        XCTAssertFalse(first.agents[1].isLoading)
        let later = now.addingTimeInterval(60)
        let final = await coordinator.refresh(now: later, calendar: calendar)
        XCTAssertFalse(final.hasMoreFiles)
        XCTAssertEqual(final.summaries[.today]?.tokens, 250)
        XCTAssertEqual(final.fetchedAt, now)
        let piClocks = await pi.clocks
        let opencodeClocks = await opencode.clocks
        XCTAssertEqual(piClocks, [now, now])
        XCTAssertEqual(opencodeClocks, [now])
        let next = await coordinator.refresh(now: later, calendar: calendar)
        XCTAssertEqual(next.summaries[.today]?.tokens, 375)
        XCTAssertEqual(next.agents.map(\.fetchedAt), [later, later])
    }

    func testStaleReadingsAreRebucketedAcrossMidnightInsteadOfSummingIncompatibleCharts() async {
        let pi = ScriptedSource([.success(reading(100)), .success(reading(100))])
        let opencode = ScriptedSource([.success(reading(200)), .failure])
        let coordinator = coordinator(pi, opencode)
        _ = await coordinator.refresh(now: now, calendar: calendar)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: now)!
        let result = await coordinator.refresh(now: nextDay, calendar: calendar)
        XCTAssertEqual(result.summaries[.today]?.tokens, 0)
        XCTAssertEqual(result.summaries[.week]?.tokens, 300)
        XCTAssertEqual(result.summaries[.week]?.buckets.reduce(0) { $0 + $1.tokens }, 300)
        XCTAssertEqual(result.agents[1].fetchedAt, now)
        XCTAssertEqual(result.coverage.state, .partial)
    }

    func testSharedCanonicalizationCountsCopiesOnceAndExcludesAllConflictingCopies() {
        let first = UsageObservation(operationID: "same", timestamp: now, tokens: 100)
        let conflict = UsageObservation(operationID: "same", timestamp: now, tokens: 200)
        let other = UsageObservation(operationID: "other", timestamp: now, tokens: 300)
        XCTAssertEqual(UsageObservation.resolve([first, first]).observations, [first])
        let result = UsageObservation.resolve([first, conflict, first, other])
        XCTAssertEqual(result.observations, [other])
        XCTAssertTrue(result.hasConflicts)
    }

    private func reading(_ tokens: Int64, state: HistoryCoverage.State = .ready) -> HistoryReadings
    {
        let present = state == .ready || state == .partial
        return HistoryReadings(
            observations: present
                ? [UsageObservation(operationID: "same-id", timestamp: now, tokens: tokens)] : [],
            coverage: HistoryCoverage(state: state, filesRead: present ? 1 : 0, issues: [])
        )
    }

    private func coordinator(_ pi: ScriptedSource, _ opencode: ScriptedSource) -> HistoryCoordinator
    {
        HistoryCoordinator(sources: [
            HistorySource(agent: .pi, read: { try await pi.read($0) }),
            HistorySource(agent: .opencode, read: { try await opencode.read($0) }),
        ])
    }
}

private actor ScriptedSource {
    enum Step: Sendable {
        case success(HistoryReadings)
        case failure
    }
    private var steps: [Step]
    private(set) var clocks: [Date] = []
    init(_ steps: [Step]) { self.steps = steps }
    func read(_ context: HistoryReadContext) throws -> HistoryReadings {
        clocks.append(context.now)
        switch steps.removeFirst() {
        case .success(let result): return result
        case .failure: throw NSError(domain: "sensitive payload", code: 1)
        }
    }
}
