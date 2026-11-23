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
    func testOverlappingRefreshRunsOnceMoreAfterTheCurrentOne() async {
        let fetcher = SuspendedFetcher()
        let store = UsageStore(fetch: { try await fetcher.fetch() })
        let refresh = Task { await store.refresh() }
        await fetcher.waitUntilStarted()

        XCTAssertTrue(store.isRefreshing)
        await store.refresh()
        await store.refresh()
        var count = await fetcher.requestCount
        XCTAssertEqual(count, 1, "Overlapping requests don't fetch concurrently")

        await fetcher.release()
        await refresh.value
        count = await fetcher.requestCount
        XCTAssertEqual(count, 2, "They coalesce into one more pass")
        XCTAssertFalse(store.isRefreshing)
        XCTAssertNotNil(store.allowances[0].snapshot)
    }

    @MainActor
    func testProvidersRefreshAndFailIndependently() async {
        let fetcher = ScriptedFetcher()
        let store = UsageStore(sources: [
            AllowanceSource(provider: .chatGPT) { sampleAllowance },
            AllowanceSource(provider: .chatGPT) { try await fetcher.fetch() },
        ])
        await store.refresh()
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
        let store = UsageStore(sources: [
            AllowanceSource(provider: .chatGPT) { nil },
            AllowanceSource(provider: .claude) { await login.allowance() },
        ])
        XCTAssertEqual(store.visibleAllowances.map(\.provider), [.chatGPT, .claude])

        await store.refresh()
        XCTAssertEqual(store.visibleAllowances.map(\.provider), [.claude])
        XCTAssertNil(store.allowances[0].error)
        XCTAssertEqual(store.summary, "5h: 76%  7d: 87.5%")

        await login.signOut()
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

    @MainActor
    func testHiddenProviderIsNotFetchedAndTheChoiceIsRemembered() async throws {
        let suite = "UsageStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let chatGPT = CountingFetcher()
        func launch() -> UsageStore {
            UsageStore(
                sources: [
                    AllowanceSource(provider: .chatGPT) { await chatGPT.fetch() },
                    AllowanceSource(provider: .claude) { sampleAllowance },
                ],
                defaults: defaults
            )
        }

        let store = launch()
        await store.setShown(.chatGPT, false)
        await store.refresh()
        XCTAssertEqual(store.visibleAllowances.map(\.provider), [.claude])
        var count = await chatGPT.count
        XCTAssertEqual(count, 0)

        let relaunched = launch()
        await relaunched.refresh()
        XCTAssertEqual(relaunched.visibleAllowances.map(\.provider), [.claude])

        await relaunched.setShown(.chatGPT, true)
        XCTAssertEqual(relaunched.visibleAllowances.map(\.provider), [.chatGPT, .claude])
        XCTAssertNotNil(relaunched.allowances[0].snapshot, "Showing a provider fetches it")
        count = await chatGPT.count
        XCTAssertEqual(count, 1)
    }

    @MainActor
    func testProviderShownDuringARefreshShowsOnlyAFreshReading() async throws {
        let suite = "UsageStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let claude = SuspendedFetcher()
        let store = UsageStore(
            sources: [
                AllowanceSource(provider: .chatGPT) { sampleAllowance },
                AllowanceSource(provider: .claude) { try await claude.fetch() },
            ],
            defaults: defaults
        )
        var refresh = Task { await store.refresh() }
        await claude.waitUntilStarted()
        await claude.finish()
        await refresh.value
        XCTAssertNotNil(store.allowances[0].snapshot)

        await store.setShown(.chatGPT, false)
        refresh = Task { await store.refresh() }
        await claude.waitUntilStarted()
        await store.setShown(.chatGPT, true)
        XCTAssertEqual(store.visibleAllowances.map(\.provider), [.chatGPT, .claude])
        XCTAssertNil(store.allowances[0].snapshot, "A reading from before hiding is not shown")

        await claude.release()
        await refresh.value
        XCTAssertNotNil(store.allowances[0].snapshot, "It is fetched once that refresh ends")
    }

    @MainActor
    func testEmptyMessageTellsHiddenProvidersFromMissingLogins() async throws {
        let suite = "UsageStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(
            sources: [
                AllowanceSource(provider: .chatGPT) { nil },
                AllowanceSource(provider: .claude) { sampleAllowance },
            ],
            defaults: defaults
        )
        await store.refresh()
        XCTAssertNil(store.emptyAllowanceMessage)

        await store.setShown(.claude, false)
        XCTAssertEqual(store.emptyAllowanceMessage, "Hidden from the options menu: Claude.")
        await store.setShown(.chatGPT, false)
        XCTAssertEqual(
            store.emptyAllowanceMessage,
            "Hidden from the options menu: ChatGPT, Claude."
        )

        await store.setShown(.claude, true)
        XCTAssertNil(store.emptyAllowanceMessage)
        await store.setShown(.chatGPT, true)

        let signedOut = UsageStore(
            sources: [AllowanceSource(provider: .claude) { nil }],
            defaults: defaults
        )
        await signedOut.refresh()
        XCTAssertEqual(
            signedOut.emptyAllowanceMessage?.hasPrefix("No subscription login found."),
            true
        )
    }
}

private actor CountingFetcher {
    private(set) var count = 0

    func fetch() -> Allowance {
        count += 1
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
    private var released = false

    func fetch() async throws -> Allowance {
        requestCount += 1
        if released { return sampleAllowance }
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

    /// Finishes the pending fetch and answers every later one at once.
    func release() {
        released = true
        finish()
    }
}
