# Security and deployment status

Tally is a reference implementation for accounting and integration review.
There is no supported live deployment or independent security audit. A passing
backtest does not approve a valuation policy, permission grant or production use.

Report suspected vulnerabilities privately to the repository maintainers through
the existing private channel used to share this repository. If no such channel
exists, ask a maintainer to establish one before sending exploit details or
credentials. Do not put confidential findings or RPC keys in public issues.
There is no advertised bounty or response-time guarantee.

For a useful report, include the exact commit, affected contract/integration,
expected versus observed accounting, and a minimal local reproduction. Prefer
fork tests or mocks over transactions on a live network.

Before payments, obtain independent security and accounting review, agree oracle
and remote-state trust, rehearse least-privilege permissions and recovery, and
net obligations against the MSC process. Monitor halted/stale marks, unresolved
equity, unpaid claims, supply losses, float and debt headroom. `halt` blocks
settlement while preserving a last-known mark; `cage` is an irreversible shutdown.

CI credential checks cover documented patterns and reachable first-party history.
They are a bounded safeguard, not proof that a repository contains no sensitive
information. Archive RPC secrets belong in a reviewed workflow environment and
must not be made available to unreviewed fork-PR code.
