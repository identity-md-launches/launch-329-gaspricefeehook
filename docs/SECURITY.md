# Implementation review handoff

This records the author's design checks and local evidence. It is **not** the separate
independent review, a security audit or authorization to deploy.

| Property | Implementation and evidence |
| --- | --- |
| Permission/address agreement | BaseHook constructor validation; CREATE2 deployment in tests; exact 0x44 mask asserted |
| Callback caller | BaseHook `onlyPoolManager`; direct outsider `afterSwap` and unlock calls rejected |
| Unlock provenance | Idle/pending/executing state, expected PoolId, callback consumption, nested-unlock tests |
| Swap accounting | Positive return delta cancels claim-mint debt; real manager settlement across all four swap modes |
| Donation accounting | Burn credits equal donation debits; exact LP payout test, rounding documented |
| Atomic rollback | Failed token settlement and injected post-burn donation failure preserve accounting/claims |
| No liquidity | Claims wait across LP removal/re-addition; real manager unit and stateful tests |
| Pool isolation | Full PoolId mapping; shared-currency pools tested; per-currency aggregate claim invariant |
| External calls | Only immutable PoolManager; no hook token/ETH transfer, user callback or oracle |
| Arithmetic | Overflow-safe tip comparison; widened signed magnitude; ceil/cap formula; bounded int128 fee cast |
| Public sender identity | Router is reported, no user attribution; hookData ignored and unauthenticated |
| Supply/authority | OZ ERC-20, one constructor mint, no exposed mint or owner; token behavioral tests |
| Immutability | No proxy, delegatecall, callcode or selfdestruct; runtime opcode scans on token and hook |
| Factory compatibility | No initialization/liquidity hooks; ETH-less one-sided launch rehearsal |

The independent reviewer should check these properties in the accepted bytecode/source and
manifest, including the exact Sepolia manager argument, CREATE2 deployer/salt, constructor
shape, fixed supply, compiler configuration, enabled permissions, static-fee launch pool and
source/ABI consistency. Passing local tests cannot establish live address provenance, factory
policy compliance, authorization or signed artifact linkage.

Known design limits are part of the behavior to review: sender-selected gas price and private
bundle bypass; zero-base-fee low tier; permissionless donation timing/JIT exposure; v4 rounding
dust; unsolicited claim surplus; signed-int128 limits on donation amounts; and reliance on a
canonical, nonmalicious PoolManager and standard pool currencies. Fee-on-transfer, rebasing
and callback tokens have not been certified by these tests. The launch's native ETH/GASP pair
uses ordinary accounting. No fork test, static-analysis tool report, formal proof or external
audit is claimed by this contribution.

Dependency provenance is in [dependencies.json](dependencies.json); file hashes are in
[dependency-checksums.txt](dependency-checksums.txt). In particular the vendored, unmodified
[v4-periphery BaseHook](https://github.com/Uniswap/v4-periphery/blob/444c526b77d804590f0d7bc5a481af5a3277c952/src/utils/BaseHook.sol)
and matching [v4-core PoolManager](https://github.com/Uniswap/v4-core/blob/a7cf038cd568801a79a9b4cf92cd5b52c95c8585/src/PoolManager.sol)
are the integration basis. Upstream licenses remain with their source files.
