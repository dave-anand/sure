# Local finance consolidation assessment

Assessed October 25, 2026 from the local source trees for Sure,
`~/git/local-fin-app`, and `~/git/local-fin-health`. This is a source-level
assessment, not verification of their deployed instances or financial inputs.
No private databases, browser storage, or financial exports were inspected.

The subsequent [feature review and migration backlog](finance-feature-review.md)
adds implementation evidence, executable verification, feature decisions and
acceptance criteria. Use it to prioritize work before implementing import adapters.

## Recommendation

Use Sure as the household financial system of record and common user interface.
Migrate useful workflows from local-fin-app rather than embedding its Express
and Next.js application. Initially retain local-fin-health's Python calculation
engine behind a private, versioned interface, with Sure owning authentication,
authorization, persisted plans and calculation jobs. A single application
experience need not require rewriting a tested engine in Ruby immediately.

This changes the original sequence: integrate the existing Canadian planning
engine after ingestion and reconciliation are reliable, rather than rebuilding
retirement planning from scratch. Keep backup/restore verification and
demonstration-account evaluation ahead of data migration.

## Findings from implementation

| Area | Existing implementation | Proposed treatment |
| --- | --- | --- |
| Daily finances | local-fin-app has accounts, transactions, manual transfers, recurring schedules, loan workflows and reporting in `apps/api/src/index.ts` and React panels. Sure already has corresponding core models and workflows. | Keep Sure's ledger; migrate data and demonstrated UX gaps only. |
| Import assistance | local-fin-app has CSV preview/import, duplicate handling, PDF conversion, merchant normalization and rules/model-assisted categorization. | Evaluate its parser fixtures and useful rules against Sure's import and provider abstractions. Do not copy a second ledger. |
| Investment data | local-fin-app's detailed portfolio state uses browser local storage (`portfolio_analysis_inputs`); backend aggregate snapshots cannot reconstruct positions. | Export browser data explicitly, preserve unknown cost bases and capture valuation dates. |
| Planning and resilience | local-fin-health has pure projection, scoring, scenario, Canadian ledger/tax and simulation modules, plus tests under `backend/tests`. Current projection code declares model `3.3.0`; some documentation describes older versions. | Preserve the calculation boundary and pin model versions; establish golden inputs/outputs before integration. |
| Canadian coverage | The health engine models benefits, registered withdrawals, contribution room, survivor events and tax-aware strategies with limitations; Canadian mode rejects corporate/spousal RRSP accounts and excludes Quebec. | Expose supported coverage explicitly. Sure's existing account labels do not imply equivalent tax calculations. |
| Historical review | The health app stores immutable review/projection documents with inputs, assumptions, versions and outputs. | Preserve history separately from current account balances and new-model calculations. |
| Holdings migration | The health app has preview/apply with a plan revision check, explicit replacement targets, CAD/USD holdings and cost bases. | Retain stale-preview protection, owner mapping and explicit replacement semantics. |
| Simulations | The health engine already implements seeded exploratory Monte Carlo, normally 500 trials, with a time limit; larger background runs remain future work. | Run expensive calculations as jobs; keep probabilities separate from deterministic health scores. |
| Security | The health app has no authentication and uses unencrypted SQLite/JSON; local-fin-app describes itself as a starter application. | Do not expose their existing APIs through Sure unchanged. Enforce Sure's family and account access boundaries. |

Source anchors: local-fin-app `apps/api/src/{index,pdf-import,merchant-normalization}.ts`
and `apps/web/components/portfolio-analysis-panel.tsx`; local-fin-health
`backend/app/{api/routes.py,schemas/plan.py,services/projections/engine.py}`,
`services/canadian/`, `services/simulations/monte_carlo.py`, and its
`docs/{CANADIAN,MODEL,MONTE_CARLO,ARCHITECTURE}.md`.

## API ingestion already exists

Sure's `Api::V1::ImportsController` accepts CSV uploads or raw content and exposes
preflight, status and rows. `ImportSessionsController` supports chunked Sure
NDJSON with client session/chunk identifiers and publication.
`SureImport::IMPORTABLE_NDJSON_TYPES` includes accounts, balances, transactions,
transfers, trades, holdings and valuations. Resource APIs also exist for holdings,
trades, valuations and securities. Reuse these before proposing new endpoints.

The goal is unattended data delivery and safe publication, rather than manual
file selection. A watched folder, scheduled broker export collector, or other
authorized producer can send data to Sure. An API does not itself obtain bank
or brokerage data: each source still needs a supported export, connection or
collector. No direct ProjectionLab integration or file compatibility has been
verified; that would be a separate adapter after checking its supported contract.

Transport retry protection is not sufficient evidence of business-level
deduplication across newly submitted batches. Validate and extend the existing
import contracts for source identifiers, overlapping statements and revised data.

## Delivery plan

### Recovery verification: October 25, 2026

The deployed, unmodified `bin/sure-backup restore` successfully restored a
post-encryption backup into a disposable database and a separate file-storage
volume. Checksum validation passed, and Rails decrypted the restored user's
email and resolved its deterministic email lookup. Temporary resources were
removed, and the live application's health endpoint returned HTTP 200.

The shipped script already handles a PostgreSQL 17 restore client targeting a
PostgreSQL 16 server by filtering the unsupported `transaction_timeout` setting
from generated SQL. An earlier direct `pg_restore` probe bypassed that handling;
its failure was not evidence of a defect in Sure's restore command. No restore
code change or release was required. A full fresh-host recovery, including
deployment configuration and browser login, remains a separate verification.

### Remaining increments

1. **Finish the operational baseline.** Verify unmodified recovery, preserve
   encryption keys, and evaluate six demonstration accounts. Keep real migration
   data separate from the aggregate demonstration portfolio.
2. **Inventory and map data.** Capture read-only exports from both applications,
   including browser holdings and immutable planning history. Identify the
   authoritative source per account and date. Map owners, account types,
   currencies, cash, holdings, cost basis and debt balances; record unknowns.
   Sure uses negative transaction amounts for inflows, whereas local-fin-app's
   documented CSV example uses positive payroll. Convert signs explicitly.
   Validate cash-plus-holdings totals and exclude insurance death benefits from
   current net worth. Confirm source ownership and dependency licenses before
   reusing code.
3. **Deliver one automated import path.** Start with one dated account/holdings
   snapshot, using an adapter to Sure's existing API. Define schema version,
   source and external account/record IDs, as-of dates, native currencies, FX
   provenance and file hash. Support validation, reconciliation preview,
   publication, status polling, conflict reporting and replay. Pin previews to
   revisions; reject stale input. Prove retries and overlapping batches do not
   duplicate data. Trusted, previously validated mappings may auto-publish;
   ambiguous ownership or unreconciled totals require review.
4. **Migrate actual finances incrementally.** Import one account first, reconcile
   it to its statement, then expand to the remaining accounts and transactions.
   Preserve an import audit trail and a defined reversal strategy. Do not treat
   holding snapshots as purchases, investment gains as cash income, or planning
   assumptions as verified balances. Retire aggregate placeholders only after
   their detailed replacements reconcile.
5. **Integrate Canadian planning.** Define a versioned immutable planning input
   built from authorized Sure data plus separately entered assumptions. Preserve
   stable owner IDs and map them to the health engine's indexed references;
   distinguish tax ACB from broker book value. Keep the Python service off public
   ports, restrict callers, and provide no direct live-ledger write access.
   Sure stores plan revisions, scenarios, model/table versions and hashes,
   input snapshots and outputs. Run calculation jobs through Sidekiq with timeouts
   and stale-result detection. Start with deterministic projections and reviews;
   add exploratory simulations after parity is established.
6. **Consolidate the experience.** Add planning, resilience and scenario views
   through Sure's existing design system and localization. Reuse its market-data
   providers rather than operating competing price-refresh paths. Port only
   local-fin-app reporting or scheduling features that a gap assessment shows
   are missing. Maintain effective-rate fallback and clear unsupported-case
   messages rather than silently applying the wrong tax treatment.
7. **Cut over after parallel verification.** Compare balances and calculations
   on fixed fixtures, document intentional differences, retain original exports
   and old model artifacts, then make old applications read-only before retiring
   them. Consolidate backups to include planning history and engine versions.

## Acceptance and workflow

The first increment succeeds when a producer can submit a snapshot without a
browser, poll its result, replay it without duplicates, and reconcile Sure's
account values to the source. Authorization must reject cross-family/account
access, including uploads, status and preview results.

Planning integration succeeds when fixed imported inputs reproduce the existing
engine's outputs within defined tolerances, preserve historical reviews, disclose
unsupported assumptions and cannot change live balances.

Implement in small branches and PRs, with the repository's full required checks
before pushing or opening PRs. API changes require behavioral Minitest coverage,
documentation-only rswag specs and regenerated OpenAPI documentation. Keep
secrets, raw financial exports and production configuration outside Git. Deploy
reviewed versions with backups and health checks; avoid a single bulk migration
or wholesale rewrite of all three applications.
