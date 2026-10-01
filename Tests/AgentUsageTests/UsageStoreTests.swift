import Foundation
import XCTest
@testable import AgentUsage

final class UsageStoreTests: XCTestCase {
    @MainActor
    func testSuccessfulRefreshRecordsStructuredDataAndTimestamp() async {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let store = UsageStore(fetch: { sampleLimits }, now: { date })
        XCTAssertNil(store.snapshot)
        XCTAssertEqual(store.summary, "Agent Usage…")

        await store.refresh()

        XCTAssertEqual(store.snapshot?.fetchedAt, date)
        XCTAssertEqual(store.summary, "5h: 76%  7d: 87.5%")
        XCTAssertNil(store.error)
        XCTAssertFalse(store.isRefreshing)
    }

    @MainActor
    func testInitialFailureShowsUnavailableState() async {
        let store = UsageStore(fetch: { throw FetchError.unavailable })
        await store.refresh()

        XCTAssertNil(store.snapshot)
        XCTAssertEqual(store.summary, "Usage unavailable")
        XCTAssertEqual(store.error, "Test server unavailable.")
        XCTAssertFalse(store.isRefreshing)
    }

    @MainActor
    func testFailedRefreshKeepsLastReadingAndRecoveryClearsError() async {
        let fetcher = ScriptedFetcher()
        var date = Date(timeIntervalSince1970: 1_700_000_000)
        let store = UsageStore(fetch: { try await fetcher.fetch() }, now: { date })
        await store.refresh()
        let firstDate = store.snapshot?.fetchedAt

        date = date.addingTimeInterval(60)
        await store.refresh()
        XCTAssertEqual(store.snapshot?.fetchedAt, firstDate)
        XCTAssertEqual(store.summary, "5h: 76%  7d: 87.5%")
        XCTAssertEqual(store.error, "Test server unavailable.")
        XCTAssertFalse(store.isRefreshing)

        await store.refresh()
        XCTAssertEqual(store.snapshot?.fetchedAt, date)
        XCTAssertNil(store.error)
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
        XCTAssertNotNil(store.snapshot)
    }
}

private let sampleLimits = UsageLimits(rateLimit: .init(
    primaryWindow: .init(usedPercent: 24, resetAfterSeconds: 3_720),
    secondaryWindow: .init(usedPercent: 12.5, resetAfterSeconds: 90_000)
))

private enum FetchError: LocalizedError {
    case unavailable
    var errorDescription: String? { "Test server unavailable." }
}

private actor ScriptedFetcher {
    private var count = 0

    func fetch() throws -> UsageLimits {
        count += 1
        if count == 2 { throw FetchError.unavailable }
        return sampleLimits
    }
}

private actor SuspendedFetcher {
    private(set) var requestCount = 0
    private var pending: CheckedContinuation<UsageLimits, any Error>?
    private var started: CheckedContinuation<Void, Never>?

    func fetch() async throws -> UsageLimits {
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
        pending?.resume(returning: sampleLimits)
        pending = nil
    }
}
