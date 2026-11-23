import Foundation
import XCTest

@testable import AgentUsage

final class UsageStoreTests: XCTestCase {
    @MainActor
    func testSuccessfulRefreshRecordsStructuredDataAndTimestamp() async {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let store = UsageStore(fetch: { sampleAllowance }, now: { date })
        XCTAssertNil(store.allowances[0].snapshot)
        XCTAssertEqual(store.summary, "Agent Usage…")

        await store.refresh()

        XCTAssertEqual(store.allowances[0].snapshot?.fetchedAt, date)
        XCTAssertEqual(store.summary, "5h: 76%  7d: 87.5%")
        XCTAssertNil(store.allowances[0].error)
        XCTAssertFalse(store.isRefreshing)
    }

    @MainActor
    func testInitialFailureShowsUnavailableState() async {
        let store = UsageStore(fetch: { throw FetchError.unavailable })
        await store.refresh()

        XCTAssertNil(store.allowances[0].snapshot)
        XCTAssertEqual(store.summary, "Usage unavailable")
        XCTAssertEqual(store.allowances[0].error, "Test server unavailable.")
        XCTAssertFalse(store.isRefreshing)
    }

    @MainActor
    func testFailedRefreshKeepsLastReadingAndRecoveryClearsError() async {
        let fetcher = ScriptedFetcher()
        var date = Date(timeIntervalSince1970: 1_700_000_000)
        let store = UsageStore(fetch: { try await fetcher.fetch() }, now: { date })
        await store.refresh()
        let firstDate = store.allowances[0].snapshot?.fetchedAt

        date = date.addingTimeInterval(60)
        await store.refresh()
        XCTAssertEqual(store.allowances[0].snapshot?.fetchedAt, firstDate)
        XCTAssertEqual(store.summary, "5h: 76%  7d: 87.5%")
        XCTAssertEqual(store.allowances[0].error, "Test server unavailable.")
        XCTAssertFalse(store.isRefreshing)

        await store.refresh()
        XCTAssertEqual(store.allowances[0].snapshot?.fetchedAt, date)
        XCTAssertNil(store.allowances[0].error)
    }

    @MainActor
    func testOverlappingRefreshesOnlyFetchOnce() async {
        let fetcher = SuspendedFetcher()
        let store = UsageStore(fetch: { try await fetcher.fetch() })
        let refresh = Task { await store.refresh() }
        await fetcher.waitUntilStarted()

        XCTAssertTrue(store.isRefreshing)
        await store.refresh()
        let count = await fetcher.requestCount
        XCTAssertEqual(count, 1)

        await fetcher.finish()
        await refresh.value
        XCTAssertFalse(store.isRefreshing)
        XCTAssertNotNil(store.allowances[0].snapshot)
    }

    @MainActor
    func testProvidersRefreshAndFailIndependently() async {
        let fetcher = ScriptedFetcher()
        var date = Date(timeIntervalSince1970: 1_700_000_000)
        let store = UsageStore(
            sources: [
                AllowanceSource(provider: .chatGPT) { sampleAllowance },
                AllowanceSource(provider: .chatGPT) { try await fetcher.fetch() },
            ],
            now: { date }
        )
        await store.refresh()
        date = date.addingTimeInterval(60)
        await store.refresh()

        XCTAssertNil(store.allowances[0].error)
        XCTAssertNotNil(store.allowances[0].snapshot)
        XCTAssertEqual(store.allowances[1].error, "Test server unavailable.")
        XCTAssertNotNil(store.allowances[1].snapshot, "A failure keeps that provider's reading")
    }

    @MainActor
    func testSummaryShowsTheProviderClosestToItsLimit() async {
        let tight = Allowance(windows: [
            window(label: "5h", used: 10),
            window(label: "7d", used: 95),
        ])
        let store = UsageStore(sources: [
            AllowanceSource(provider: .chatGPT) { sampleAllowance },
            AllowanceSource(provider: .chatGPT) { tight },
        ])
        await store.refresh()

        XCTAssertEqual(store.summary, "5h: 90%  7d: 5%")
    }

    @MainActor
    func testSummaryWaitsUntilEveryProviderHasFailed() async {
        let pending = SuspendedFetcher()
        let store = UsageStore(sources: [
            AllowanceSource(provider: .chatGPT) { throw FetchError.unavailable },
            AllowanceSource(provider: .chatGPT) { try await pending.fetch() },
        ])
        let refresh = Task { await store.refresh() }
        await pending.waitUntilStarted()
        while store.allowances[0].error == nil { await Task.yield() }

        XCTAssertEqual(store.summary, "Agent Usage…")

        await pending.finish()
        await refresh.value
        XCTAssertEqual(store.summary, "5h: 76%  7d: 87.5%")
    }

    @MainActor
    func testSignedOutProviderIsHiddenAndDropsItsReading() async {
        let login = LoginScript()
        var date = Date(timeIntervalSince1970: 1_700_000_000)
        let store = UsageStore(
            sources: [
                AllowanceSource(provider: .chatGPT) { nil },
                AllowanceSource(provider: .claude) { await login.allowance() },
            ],
            now: { date }
        )
        XCTAssertEqual(store.visibleAllowances.map(\.provider), [.chatGPT, .claude])

        await store.refresh()
        XCTAssertEqual(store.visibleAllowances.map(\.provider), [.claude])
        XCTAssertNil(store.allowances[0].error)
        XCTAssertEqual(store.summary, "5h: 76%  7d: 87.5%")

        await login.signOut()
        date = date.addingTimeInterval(5 * 60)
        await store.refresh()
        XCTAssertTrue(store.visibleAllowances.isEmpty)
        XCTAssertNil(store.allowances[1].snapshot)
        XCTAssertEqual(store.summary, "Agent Usage")
    }

    @MainActor
    func testSignedOutProviderDoesNotHideAnotherProvidersFailure() async {
        let store = UsageStore(sources: [
            AllowanceSource(provider: .chatGPT) { nil },
            AllowanceSource(provider: .claude) { throw FetchError.unavailable },
        ])
        await store.refresh()
        XCTAssertEqual(store.visibleAllowances.map(\.provider), [.claude])
        XCTAssertEqual(store.summary, "Usage unavailable")
    }
}

extension UsageStoreTests {
    @MainActor
    func testEachProviderWaitsForItsOwnInterval() async {
        let chatGPT = ServerScript([.ok])
        let claude = ServerScript([.ok])
        var date = Date(timeIntervalSince1970: 1_700_000_000)
        let store = UsageStore(
            sources: [
                AllowanceSource(provider: .chatGPT) { try await chatGPT.fetch() },
                AllowanceSource(provider: .claude) { try await claude.fetch() },
            ],
            now: { date }
        )
        await store.refresh()
        await store.refresh()
        var counts = (await chatGPT.count, await claude.count)
        XCTAssertTrue(counts == (1, 1), "An immediate Refresh sends no request")

        date = date.addingTimeInterval(60)
        await store.refresh()
        date = date.addingTimeInterval(239)
        await store.refresh()
        counts = (await chatGPT.count, await claude.count)
        XCTAssertTrue(counts == (3, 1), "\(counts)")

        date = date.addingTimeInterval(1)
        await store.refresh()
        let claudeCount = await claude.count
        XCTAssertEqual(claudeCount, 2)
    }

    @MainActor
    func testRateLimitingBacksOffUntilASuccess() async {
        let server = ServerScript([
            .ok, .rateLimited(nil), .rateLimited(0), .rateLimited(nil), .rateLimited(nil), .ok,
        ])
        var date = Date(timeIntervalSince1970: 1_700_000_000)
        let store = UsageStore(
            sources: [AllowanceSource(provider: .claude) { try await server.fetch() }],
            now: { date }
        )
        await store.refresh()
        let reading = store.allowances[0].snapshot

        // Minutes between requests: the interval, then a backoff that ignores Retry-After: 0.
        for (step, minutes) in [5, 5, 10, 20, 30, 5].enumerated() {
            let count = await server.count
            date = date.addingTimeInterval(TimeInterval(minutes * 60 - 1))
            await store.refresh()
            let early = await server.count
            XCTAssertEqual(early, count, "Request \(step + 2) was sent early")
            date = date.addingTimeInterval(1)
            await store.refresh()
            let due = await server.count
            XCTAssertEqual(due, count + 1, "Request \(step + 2) was not sent")

            if step < 4 {
                let state = store.allowances[0]
                XCTAssertEqual(state.snapshot, reading, "A rate limit keeps the last reading")
                XCTAssertEqual(state.error, "The usage server is limiting requests (HTTP 429).")
                XCTAssertNotNil(state.rateLimitedUntil)
                XCTAssertGreaterThan(state.rateLimitedUntil!, date)
            }
        }
        XCTAssertNil(store.allowances[0].rateLimitedUntil)
        XCTAssertNil(store.allowances[0].error)
    }

    @MainActor
    func testRateLimitingWaitsAsLongAsTheServerAsks() async {
        let server = ServerScript([.rateLimited(3_600), .ok])
        var date = Date(timeIntervalSince1970: 1_700_000_000)
        let store = UsageStore(
            sources: [AllowanceSource(provider: .claude) { try await server.fetch() }],
            now: { date }
        )
        await store.refresh()
        XCTAssertEqual(store.allowances[0].rateLimitedUntil, date.addingTimeInterval(3_600))

        date = date.addingTimeInterval(3_599)
        await store.refresh()
        var count = await server.count
        XCTAssertEqual(count, 1)

        date = date.addingTimeInterval(1)
        await store.refresh()
        count = await server.count
        XCTAssertEqual(count, 2)
        XCTAssertNotNil(store.allowances[0].snapshot)
    }
}

private actor ServerScript {
    enum Response {
        case ok
        case rateLimited(TimeInterval?)
    }

    private var responses: [Response]
    private(set) var count = 0

    /// Plays the responses in order, then repeats the last one.
    init(_ responses: [Response]) { self.responses = responses }

    func fetch() throws -> Allowance {
        count += 1
        let response = responses.count > 1 ? responses.removeFirst() : responses[0]
        if case .rateLimited(let retryAfter) = response {
            throw UsageError.rateLimited(retryAfter: retryAfter)
        }
        return sampleAllowance
    }
}

private actor LoginScript {
    private var signedIn = true

    func allowance() -> Allowance? { signedIn ? sampleAllowance : nil }
    func signOut() { signedIn = false }
}

private let sampleAllowance = Allowance(windows: [
    window(label: "5h", used: 24),
    window(label: "7d", used: 12.5),
])

private func window(label: String, used: Double) -> AllowanceWindow {
    AllowanceWindow(
        label: label,
        title: label,
        subtitle: "",
        usedPercent: used,
        resetsAt: Date(timeIntervalSince1970: 1_700_003_600)
    )
}

private enum FetchError: LocalizedError {
    case unavailable
    var errorDescription: String? { "Test server unavailable." }
}

private actor ScriptedFetcher {
    private var count = 0

    func fetch() throws -> Allowance {
        count += 1
        if count == 2 { throw FetchError.unavailable }
        return sampleAllowance
    }
}

private actor SuspendedFetcher {
    private(set) var requestCount = 0
    private var pending: CheckedContinuation<Allowance, any Error>?
    private var started: CheckedContinuation<Void, Never>?

    func fetch() async throws -> Allowance {
        requestCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish() {
        pending?.resume(returning: sampleAllowance)
        pending = nil
    }
}
