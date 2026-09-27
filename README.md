# Gas Tax — GASP and GasPriceFeeHook

This is the contract-stage contribution for **lab-gas-price-fee-hook**, a Sepolia-only
`univ4_hook` launch. It delivers source, local tests, vendored dependencies and compiler-generated
ABIs. The manifest contributor writes `launch.json`; a separate contributor independently
reviews accepted source and manifest. Publication, signed artifact linkage, attestation,
admission, factory deployment and the website are subsequent service responsibilities.

## Contracts

- `src/GASP.sol`: **Gas Tax / GASP**, 18 decimals, fixed supply **1,000,000,000 GASP**
  (`1000000000000000000000000000` smallest units). Its argument-free constructor mints
  everything to `msg.sender`. The factory must be that caller. Standard OpenZeppelin ERC-20
  transfers and allowances; no owner, mint entry point, transfer tax, burn, pause or upgrade.
- `src/GasPriceFeeHook.sol`: extends the pinned v4-periphery `BaseHook`. Its only constructor
  argument is `IPoolManager`. No owner, admin, proxy, external oracle or configurable rate.
  Exactly `afterSwap` and `afterSwapReturnDelta` are enabled; all other permissions are false.
- `src/HookFlags.sol`: canonical v4 permission constants for deployment/admission tooling.

### Gas-price rule

For nonzero base fee, the high tier applies only when **both** conditions hold:

```text
transaction gas price > 2 × block base fee
transaction gas price − block base fee >= 3 gwei (MIN_TIP)
```

High tier charges **300 bps (3%)**; low tier charges **30 bps (0.3%)**. The hook fee is
additional to the launch pool's **3000 units (0.3%) LP fee**. Gas price exactly twice the
base fee is low tier. A tip exactly 3 gwei meets the tip floor, but must still satisfy the
strict ratio test. Zero-base-fee simulations always use the low tier. The pure
`feeBpsFor(gasPrice, baseFee)` also returns low tier for gas prices at or below base fee,
and handles all uint256 values without overflow.

`tx.gasprice` is chosen by the sender (the effective EIP-1559 gas price). This rule only taxes
**public priority bidding**. Private bundles with a low tip plus a direct coinbase payment
avoid the high tier. This is not sandwich prevention or proof of fair ordering. Sepolia's
very small base fees make the independent 3 gwei floor necessary for the intended policy.

### Fee currency and rounding

The callback charges the **actual unspecified amount** in the core swap delta, including
when a price limit causes a partial fill:

```text
fee = min(abs(unspecifiedAmount), ceil(abs(unspecifiedAmount) × bps / 10,000))
```

| Swap | v4 amountSpecified | zeroForOne | Fee currency | Trader effect |
| --- | --- | --- | --- | --- |
| Exact input buy | negative | true | currency1 / GASP | Output reduced |
| Exact input sell | negative | false | currency0 / ETH | Output reduced |
| Exact output buy | positive | true | currency0 / ETH | Input increased |
| Exact output sell | positive | false | currency1 / GASP | Input increased |

Currency names above describe the launch pool. Other pools can attach the same hook;
there is no token allowlist or hardcoded token. Values are raw currency units, independent
of decimals. Zero unspecified amount means zero fee. Rounding can consume an entire
one-unit output; the fee is never larger than the unspecified amount.

The hook mints ERC-6909 claims to itself inside `afterSwap` and returns a positive fee
delta. Mint's negative transient balance and the hook's positive return delta cancel.
Underlying ETH and tokens stay in PoolManager; the callback never pushes assets. In
particular, a first buy into a pool seeded with GASP alone needs no pre-existing ETH
balance for hook-fee payment.

### Donation and LP settlement

`accrued(poolId)` returns separate currency0/currency1 amounts attributed to that pool.
Anyone can call `donateFees(fullPoolKey)` while PoolManager is locked. The hook starts an
unlock, accepts exactly its pending callback for that key from its immutable PoolManager,
burns the pool's recorded claims, and donates both amounts to the pool. It clears the
accrual atomically. Every burn credit is matched by an equal donation debit. Reentry,
unsolicited callbacks, wrong hook keys and attempts to nest an unlock are rejected.

When in-range liquidity is zero, donation reverts `NoLiquidity`; all claims and accrual
remain available for a later call. This includes the launch pool before its first buy.
An uninitialized pool also has zero liquidity. Repeated donation with no accrued fees is
a harmless zero donation if liquidity exists. A failed burn/donation rolls back the entire
operation, including the callback guard. No keeper reward or mandatory interval exists.

Donation rewards **currently in-range LPs**, pro rata to liquidity, not historical swap LPs.
LPs collect through normal v4 liquidity modification. Fee growth increases by
`floor(donatedAmount × 2^128 / inRangeLiquidity)` per currency. Fee-growth and LP collection
rounding can leave dust, so small donations need not produce an immediately collectable
whole unit. Donation timing is public; an LP can add liquidity before a donation and share
in it. There is no anti-JIT mechanism or historical entitlement.

For swap accruals and donations, claims held in each currency equal the sum of that
currency's accrual over all pools. ERC-6909 allows unsolicited transfers to any address:
claims gifted directly to the hook are **unattributed surplus**, not pool fees. There is no
rescue function, approval or arbitrary withdrawal; do not send claims, tokens or ETH to
the hook. This accounting invariant assumes no such unsolicited gifts.

The canonical manager bounds each burn/donation currency amount to positive int128. GASP's
entire supply is far below that bound. Operators of other attached pools must donate before
an individual accrual exceeds `2^127 - 1` raw units; larger aggregates cannot be donated in
one call by this implementation. The hook performs no iteration over attached pools.

## Build and verify without network access

Install Foundry and Solidity **0.8.26** in the toolchain. Dependencies are ordinary source
files in `lib/`; no package install, git submodule or network access is needed to build or
test. `foundry.toml` pins the compiler, Cancun EVM, optimizer (200 runs), IR pipeline and
`bytecode_hash = "none"`. FFI and filesystem cheatcode permissions are disabled.

```sh
forge build
forge test
forge fmt --check
python3 scripts/export_abis.py --check
```

To regenerate ABI exports after an intentional source change:

```sh
python3 scripts/export_abis.py
```

`docs/dependencies.json` pins repository commits. `docs/dependency-checksums.txt` records
SHA-256 hashes of the unmodified vendored files, including upstream licenses. The
periphery snapshot retains `src/utils/BaseHook.sol` and uses the matching v4-core snapshot.
Only the transitive source dependencies used here, plus `HookMiner`, are vendored.
The upstream test routers are test/integration dependencies, not new production deployments.

## Tests and limits of local evidence

`test/GASP.t.sol` covers metadata, fixed supply, arbitrary transfer conservation, allowances,
invalid transfers and absence of administrative/mint entry points.

`test/GasPriceFeeHook.t.sol` uses an actual v4-core PoolManager and a CREATE2-mined hook with
constructor permission validation intact. It covers the tier boundaries with `vm.fee` and
`vm.txGasPrice`, all four swap modes at both rates, fuzzed rounding, tiny/zero output,
partial fills, settlement rollback, access control, shared-currency pool isolation, generic
ERC-20 pairs and donation/LP fee collection. The launch rehearsal seeds only GASP below
the opening price, checks the manager holds no ETH, buys, sells, donates and removes liquidity.
Donation tests use power-of-two liquidity to check exact payouts without rounding ambiguity.

`test/GasPriceFeeHook.invariant.t.sol` runs randomized sequences across three real pools:
swaps in both directions/modes/tiers, permissionless donation, liquidity removal and return,
and deferred donation with no liquidity. It checks per-currency claim conservation, zero
transient debt, underlying fund conservation and a fixed token supply. Transaction senders
are external test accounts so the fuzzer's gas funding cannot alter measured contract balances.
Default settings are 256 fuzz cases and 64 invariant sequences of depth 64.

No tests require environment variables, RPC, FFI or filesystem cheatcodes. The delivered
suite is local evidence, not an independent review, live Sepolia fork rehearsal, signed
attestation or admission decision. See [deployment responsibilities](docs/DEPLOYMENT.md)
and [review handoff](docs/SECURITY.md).
