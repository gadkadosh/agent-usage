# Multi-agent history — draft

Status: product decisions agreed; PR 1 implements the Pi-only architecture. PR 2 adds Codex and multi-agent presentation.

## Delivery decision

Deliver this feature in two independently reviewable PRs:

1. **Pi-only architecture migration:** introduce the normalized adapter boundary and shared service, move aggregation out of Pi, establish replacement/retention/failure semantics, and preserve existing UI behavior. Validate the seam with synthetic adapters, without shipping another agent.
2. **Codex and multi-agent presentation:** implement verified Codex accounting and discovery, then ship combined history with per-agent rows and source-specific status. Include native before/after UI evidence.

Investigate Codex's format before committing to the first interface; local schema inspection establishes that it needs timestamped normalized records and source-owned counter interpretation. Detailed counter/fork correctness remains a prerequisite to implementing Codex in PR 2. Token breakdown/model metadata can be introduced there once their source semantics are verified; PR 1 preserves Pi's current normalized total model.

## Agreed product behavior

- Show one combined token total above one combined history chart.
- Below the chart, list each included agent's total for the selected period. The period selection controls all three presentations.
- Reuse the existing Pi row presentation: agent symbol/name and compact token total. Sort rows alphabetically and attach coverage/staleness warnings to affected agents. No percentages, breakdown, or drill-down in this task.
- Preserve hover behavior: the large number temporarily shows the combined hovered hour/day total; agent rows continue showing full selected-period totals.
- Measure total token activity, counting cached input once. Estimated cost is outside scope.
- Include subagent and background-task model activity under the originating agent's row. Count copied fork history only once and count genuinely new post-fork activity normally. Adapters must establish source-supported identities rather than guess at deduplication from matching token totals.
- Start with Pi and Codex. OpenCode is a future adapter; do not assume all sources use files.
- Discover default local history locations automatically and honor supported environment overrides. Custom-directory settings and remote/cloud-only histories are outside scope.
- Refresh agents independently. One agent's failure must not prevent another agent's successful update.
- Keep existing refresh triggers: startup, menu opening, and manual refresh. No periodic refresh or live filesystem watching in this task.
- Keep the last successful data from an agent whose refresh fails. Mark its row stale; the combined total/chart show available data without a separate combined warning.
- If history is found but the first read fails, show that agent's row as failed/unavailable without a numeric contribution. Show partial/incomplete status on its row when only some usage can be read. Missing history directories stay hidden.
- The shared history service owns retained source results and failure state. Adapters own their internal parsing/index caches.
- Each accepted adapter refresh returns a complete replacement set of normalized observations for the requested history window, not an additive delta. Internal scanning may be incremental. Successful replacement allows corrected/deleted records to disappear; a failed or unsupported read preserves the previous accepted set. Readable empty results establish zero, confirmed missing history clears the contribution, and usable partial results replace it with incomplete coverage.

## Proposed architecture

Adapters discover, read, cache, parse, normalize, and resolve source-specific duplicate/conflicting records. They return timestamped normalized usage and source coverage, rather than chart summaries.

A shared history service retains each adapter's latest accepted result, coordinates refreshes, and aggregates combined and per-agent summaries using the same time boundaries. The UI store exposes selection and presentation state. Failure and partial-coverage indicators appear on agent rows; the combined display shows available contributions.

Normalized usage carries an agent identity, an operation identity scoped to that agent, a timestamp, and a validated total. Preserve available token breakdown and model/provider metadata without implementing pricing. Exact fields and optionality remain to be specified. Missing detail must not be invented as zero.

Keep storage mechanics inside adapters. Extract shared file-reading utilities only where Pi and Codex demonstrate matching requirements; do not expose filesystem concepts in the adapter contract.

Retain timestamped data rather than stale period totals, so period changes and midnight rollovers still filter stale contributions correctly. Snapshot replacement, continuation batches, and retention boundaries need explicit contracts.

## Visibility proposal

Include agents with recorded usage in the last 30 days, without requiring installation detection. Keep them visible when a shorter selected period contains zero usage. Preserve visibility through temporary read failures. The user considers exact visibility rules noncritical; unreadable first discovery and expiration of stale rows remain to be specified.

## Codex feasibility findings

A small read-only sample of local Codex history contained JSONL sessions under `~/.codex/sessions`, with `token_count` events exposing `total_token_usage` and `last_token_usage`. Only usage schema keys were printed; transcripts were not output or copied into this repository.

This establishes feasibility, not a stable format contract. Implementation must verify source behavior for repeated counters, resume, forks, archived copies, child sessions, counter resets, and cache/reasoning subsets before choosing normalization and operation identity rules. Use synthetic fixtures rather than personal transcripts.

## Implementation sequence

1. Establish the Codex format contract from official implementation evidence and synthetic fixtures. Verify discovery overrides, archived sessions, token categories, cumulative versus last-operation counters, repeated events, resume, fork inheritance, and child/background activity. Record supported versions and coverage limitations. The local sample alone is not sufficient evidence.
2. Introduce a storage-independent adapter boundary with source identity, an explicit requested retention window, normalized observations, coverage, and continuation state. Failures must use sanitized source-specific errors. Shared interfaces must not require file counts or filesystem cursors from a future SQLite adapter. Preserve Pi's current safety and coverage semantics internally.
3. Move aggregation out of Pi's source into the shared history service. Migrate Pi without changing its accounting. Keep source caches alive across refreshes. A replacement result must contain all retained observations currently accepted by that adapter, including across budgeted continuation batches; the service must never append replacement sets.
4. Add independent source result retention and failure handling. Namespace observation identities by agent. Use one `now`, calendar, retention cutoff, and set of bucket boundaries for each combined publication. Coalesce overlapping refresh requests and keep scanning off the UI actor.
5. Implement Codex against the contract and add it to live composition alongside Pi. A missing source must not block another source. Keep source selection explicit in code; dynamic plugins are unnecessary for this feature.
6. Extend the existing history panel with a general history heading and alphabetical agent rows. Preserve selected-period and hover behavior. Place failures, partial coverage, and staleness on their respective rows; keep the chart and large number based on available observations.
7. Complete accounting, lifecycle, build, and packaged UI verification described below. Update technical notes with supported discovery and format limitations.

## Remaining technical questions

- Codex-specific continuation behavior and resource budgets.
- Supported Codex format/version evidence and normalization rules.

PR 1 establishes Swift types, retained source results, refresh coalescing, storage-independent coverage, and complete replacement batches for Pi. Each source publishes as it completes, recomputing combined summaries from all currently accepted source results. Catch-up reads only pending adapters and reuses one clock, calendar and retention cutoff; completed or failed adapters are not retried until the next explicit refresh. No product decision should depend on undocumented assumptions about Codex counters.

## Validation for implementation

- Preserve existing Pi parsing, safety limits, duplicate handling, and coverage behavior.
- Verify combined total equals the sum of agent totals and chart buckets for identical period boundaries.
- Cover independent failures/recovery, stale data across period boundaries, identity collisions across agents, and repeated refreshes without double counting.
- Cover Codex cumulative/repeated reports, counter resets, resume, inherited fork history, archived copies, child/background activity, and cache/reasoning subsets. Assert replacement behavior for corrected/deleted data and continuation batches.
- Run `make check-clt-build` separately, without SDK overrides. Full Xcode is required for tests.
- Verify UI in the isolated packaged menu-bar app using `scripts/ui-review.sh`; record matched before/after evidence and repeatable setup for the PR.

## Glossary

- **Agent:** A coding tool such as Pi, Codex, or OpenCode; distinct from its model provider.
- **Adapter:** The boundary translating one agent's local history into shared usage and coverage semantics.
- **Usage observation:** Timestamped, normalized recorded token activity with a stable source-scoped identity.
- **Coverage:** What a source could read and interpret; independent of its token total.
- **Stale contribution:** Previously accepted source data retained after a failed refresh, filtered to the currently selected period.
- **Combined history:** Aggregated activity recorded by included local agents; it is not an authoritative provider billing ledger.
