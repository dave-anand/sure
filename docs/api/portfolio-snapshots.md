# Automated portfolio snapshots

This is the first implementation increment of the [consolidation backlog](../finance-feature-review.md).
It imports one **complete observed account snapshot** per request, with explicit
account and security mappings. It does not manufacture purchase transactions,
reconstruct transaction history, or import planning assumptions.

The existing import sessions remain the path for full-ledger migrations. Their
source mappings are session-scoped, and ordinary manual-account sync can remove
positions unsupported by trades. This endpoint reuses Sure's provider holding
adapter and balance-anchor models, adding durable source identity and exclusive
snapshot ownership rather than manufacturing trades to fit those imports.

## One-time mapping

Create a dedicated, zero-balance investment account and map its UUID along with
existing Sure security UUIDs. The token must have `read_write` scope and own the
account or have full-control sharing. Guests cannot publish. Use the read-only
securities API to find existing exchange-specific security UUIDs; ticker text
alone is not sufficient identity. Missing securities need deliberate setup
before publication. This increment does not infer or create them from tickers.

First publication refuses an existing provider, holdings, trades, transactions,
nonzero balance or nonzero valuation history. In particular, do not target the
aggregate demonstration investment account. The snapshot connection becomes the
account's exclusive provider writer. Other connections cannot write alongside
it, and the source account cannot silently be remapped to another account.
Published accounts appear in the Accounts page's Portfolio snapshots group.
Generic unlink is unavailable until a reviewed conversion can retain holdings;
deleting an account continues to follow the existing account-deletion workflow.

## Version 1 contract

```json
{
  "schema_version": 1,
  "source": "broker-export",
  "source_account_id": "stable-broker-account-id",
  "account_id": "00000000-0000-0000-0000-000000000001",
  "as_of": "2026-10-25",
  "currency": "CAD",
  "balance": "1100.00",
  "cash_balance": "100.00",
  "holdings": [
    {
      "source_security_id": "stable-broker-security-id",
      "security_id": "00000000-0000-0000-0000-000000000002",
      "quantity": "10",
      "price": "100.00",
      "amount": "1000.00",
      "cost_basis_total": null
    }
  ]
}
```

Replace the illustrative UUIDs with your mappings. Source IDs are opaque,
case-sensitive identities, not filenames. Keep them stable across exports.
Only CAD and USD accounts are supported; every position price, amount and cost
in a request must already use the account's currency. Mixed-currency positions
and FX conversion require a subsequent adapter with dated FX provenance. Do not
relabel foreign quotes as account-currency prices.

All financial values are nonnegative decimal **strings**. Quantity supports up
to 18 fractional digits; money supports four. `amount` must agree with quantity
times price, and `balance` with cash plus all holdings, each within 0.01. The
caller must supply a complete position list (maximum 500), with no duplicate
source/security identities. Omit closed positions; later publications write
zero authoritative rows for them so old positions do not reappear. Short
positions and margin debt are outside version 1.

`cost_basis_total` is the total acquisition cost in account currency. Null or
omitted means unknown. The archive preserves that total; Sure holdings use a
per-unit basis, converted with four-decimal rounding, and retain the normal
priority of user-locked cost-basis/security edits. This field does not certify
Canadian adjusted cost base. A new snapshot never implies a contribution,
income, an expense or an investment return.

## Preview, publish and status

1. POST `/api/v1/portfolio_snapshots/preview` with
   `{ "portfolio_snapshot": { ... } }`. It validates mappings and reconciliation
   without writing. Save the returned `data.revision`.
2. POST `/api/v1/portfolio_snapshots` with the same object plus top-level
   `expected_revision`. The account, source bindings, observed balance, holdings,
   valuation and archived payload commit in one transaction. Publication is
   synchronous and returns HTTP 201 with `status: "complete"` and an ID.
3. GET `/api/v1/portfolio_snapshots/{id}` to retrieve completion, checksum and
   reconciled totals. Reads follow account visibility; revoked sharing also
   revokes access to status. Replies are private/no-store.

Supply `X-Api-Key` on each request. A changed account or source state invalidates
the preview and produces HTTP 409; preview again. Equivalent decimal formatting
and reordered positions normalize to one checksum. An identical source/date
replay returns the original ID without duplicating records, including after a
newer date has been accepted. Different content for an accepted date, an older
unpublished date, or a changed security mapping produces 409. Corrections and
remapping require a later explicit review workflow; do not change the source ID
to bypass this gate.

Publication stores observed dates only. Existing account-sync calculations can
derive daily series, but those series are not a reconstructed trade history.
The authoritative provider-tagged holdings survive ordinary sync. No quote
provider or language model is called by the publication path. Accounts that
later acquire manual trades/transactions cannot accept further snapshots in
this initial snapshot-only mode.
Portfolio value still includes these accounts, but the combined period-return
metric is unavailable when an included account has snapshot-only history.
Otherwise missing contributions could be mistaken for market gains. Recorded
cost-basis comparisons remain distinct from investment-return calculations.

## Scheduled collector

`bin/sure-import-snapshot` uses Ruby's standard library and needs no local Rails
or database connection. Provide `SURE_URL` and `SURE_API_KEY` through the
collector's environment. Keep its input files private and out of Git.

```sh
bin/sure-import-snapshot snapshot.json
bin/sure-import-snapshot --publish snapshot.json
bin/sure-import-snapshot --status SNAPSHOT_UUID
```

The default command previews only; `--publish` performs both requests. An
authorized scheduler can run it after producing an export, without a browser
or manual file selection. HTTP deployments outside localhost require the
explicit `--allow-http` option. The client never follows redirects with the key.
On a timeout, retry unchanged input or read the prior publication's status.
Errors return a nonzero exit status. The producer still needs an actual supported
broker export/connection; broker collection and legacy-browser export adapters
are subsequent increments.

## Deployment and recovery

Migration `20261025160000_create_portfolio_snapshots` adds source connections and
snapshot archives. Back up before applying it during an explicitly scheduled
deployment. No production migration is part of local validation. Snapshot
payloads use the application's configured Active Record encryption and are
included in database backups; keep the encryption keys with protected backups.
Rolling back drops the archive tables and requires removing their polymorphic
provider links first. Do not drop them from an instance containing published
snapshots without a reviewed data-retention plan.

## Local-file-only deployments

This fork's Docker configuration defaults `LOCAL_FILE_IMPORTS_ONLY=true`.
Set this environment variable on both web and worker services and restart them
when changing it. The application default remains false for compatibility with
other installations. Existing credentials and imported financial records are
preserved; setting false restores the integrations.

With this mode enabled, bank/provider connection endpoints are blocked, queued
provider jobs are skipped, and scheduled bank, market-price, FX and property-value
fetches are disabled. Provider-based AI/PDF extraction is also unavailable.
CSV imports, this JSON file client and local account recalculation remain
available. Supply prices and currencies in your files; cached historical data is
retained. Recalculation does not fetch new quotes or exchange rates.

This is an application policy, not a network firewall. Deployment tools, update
checks and other nonfinancial application features may still use the network.
