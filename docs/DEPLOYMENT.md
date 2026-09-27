# Deployment and integration handoff

## Parameters fixed by the approved launch

| Parameter | Value |
| --- | --- |
| Network | Sepolia, chain ID 11155111 only |
| Launch kind / site label | `univ4_hook` / `lab-gas-price-fee-hook` |
| Token source / artifact | `src/GASP.sol:GASP` |
| Token constructor | No arguments; caller receives the entire supply |
| Token name / symbol / decimals | Gas Tax / GASP / 18 |
| Total supply | 1,000,000,000 GASP; 10^27 raw units |
| Hook source / artifact | `src/GasPriceFeeHook.sol:GasPriceFeeHook` |
| Hook constructor | Exactly one ABI-encoded address (`IPoolManager`) |
| Sepolia PoolManager | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` |
| Hook address permission mask | `0x0044` (68): afterSwap bit 6 and afterSwapReturnDelta bit 2 |
| All hook flag mask | `0x3fff`; all other lower bits must be zero |
| Launch currency0 | Native ETH, address zero |
| Launch currency1 | Factory-deployed GASP address |
| Launch LP fee / tick spacing | 3000 / 60, a static-fee pool |
| Hook rates | LOW_BPS 30; HIGH_BPS 300; MIN_TIP 3,000,000,000 wei |
| Initial liquidity | GASP only, tick range below opening price |
| Compiler | Solidity 0.8.26; Cancun; optimizer 200; via IR; metadata bytecode hash none |
| Administrative authority | None on token or hook |

The hook deliberately does not hardcode chain ID or a token address so a real local
PoolManager can exercise the same bytecode logic and any pool can attach it. The **launch
service** must enforce Sepolia, the exact manager constructor argument and the intended
pool key. A matching ABI does not establish that an address is the intended manager.

## Factory and address mining

1. Build the accepted source with the pinned compiler/settings. Export/check the ABIs.
2. Use the **actual CREATE2 deployer address** and the final hook initcode:
   `GasPriceFeeHook.creationCode || abi.encode(sepoliaPoolManager)`.
3. Find a salt for which `uint160(predictedAddress) & 0x3fff == 0x0044`. The vendored
   `v4-periphery/src/utils/HookMiner.sol` can perform this search; it is tooling, not hook
   runtime logic. A compiler/constructor/deployer change invalidates the mined result.
4. The factory deploys GASP directly and receives all 10^27 units. A wrapper deploying the
   token would receive its supply instead and must not silently replace this step.
5. Deploy the mined hook. `BaseHook` checks address flags during construction. Cross-check
   runtime code and `poolManager()` as well as every `getHookPermissions()` field.
6. Initialize the native-ETH/GASP key with LP fee 3000 and tickSpacing 60; seed GASP-only
   liquidity below the opening price. Initialization and adding/removing liquidity do not
   call the hook because those permission bits are disabled.
7. Rehearse first buy, sell, deferred/successful donation and LP withdrawal against the
   approved live manager before admitting/deploying the production launch transaction.

The actual factory address, token/hook addresses, CREATE2 salt, starting sqrtPriceX96,
seed amounts, LP position ticks/recipient and transaction details depend on the factory
launch configuration and deployed artifacts. They are not fabricated here. The local
rehearsal's price 2^96, ticks [-600, -60], and liquidity 2^80 are test parameters, **not
recommended launch economics**.

## Responsibilities and independent review

The manifest contributor supplies `launch.json` from accepted source. The independent
reviewer checks source behavior, the exact constructor, supply, flags and concrete
policy/authorization conflicts against the manifest. Service-owned publication policy
and signed artifact linkage are handled by the services. Tests or documentation here do
not stand in for that review or for signed admission records.

The services publish source, attest, admit and deploy through the approved factory, then
start the static frontend. They should verify current Sepolia code at the approved
addresses, gas estimates, factory compatibility, mined addresses and LP economics, and
record the live rehearsal outcome. This contribution submits no transactions and does not
produce an independently reviewed manifest.

Any user or keeper may call `donateFees` when current in-range liquidity is nonzero. The
caller pays gas and receives no reward. Monitor `FeeCharged`, `FeesDonated`, `accrued`,
manager claim balances, current liquidity and failed donation calls. Deferred donations
are expected when liquidity is absent. A useful operational cadence batches fees enough
to outweigh gas cost and LP rounding dust. There is no privileged emergency pause, rescue,
rate change or upgrade; changes require a new hook/pool and separate review.

## ABI and frontend contract

The compiler-generated interface arrays are [GASP.json](abi/GASP.json) and
[GasPriceFeeHook.json](abi/GasPriceFeeHook.json). `PoolId` encodes as `bytes32` and `Currency`
as `address`. Pool keys encode `(address currency0, address currency1, uint24 fee,
int24 tickSpacing, address hooks)`; pool ID is the keccak256 of the ABI encoding of all five
fields. Every field is needed when donating; no pool-key registry is stored in the hook.

| Interface | Meaning |
| --- | --- |
| `feeBpsFor(uint256 gasPrice, uint256 baseFee) -> uint24` | Pure 30/300 bps tier preview; inputs are wei |
| `accrued(bytes32 poolId) -> (uint256 amount0, uint256 amount1)` | Accrued fees in raw units |
| `donateFees(PoolKey key)` | Permissionless, nonpayable transaction; manager must be locked |
| `poolManager() -> address` | Immutable constructor argument |
| `getHookPermissions()` | Fourteen booleans; exactly afterSwap and afterSwapReturnDelta true |
| `FeeCharged(indexed bytes32 poolId, address sender, bool highTier, uint256 gasPrice, uint256 baseFee, address currency, uint256 fee)` | Emitted for every callback, including a zero fee |
| `FeesDonated(indexed bytes32 poolId, uint256 amount0, uint256 amount1)` | Successfully donated amounts, possibly zero |

The ABI also includes inherited BaseHook callbacks. Only the two declared flags are active;
other callbacks authenticate PoolManager and revert `HookNotImplemented`. The enabled
`afterSwap` callback also authenticates PoolManager. `unlockCallback` is a settlement
callback, not a hook permission, and requires a pending hook-initiated donation.

`FeeCharged.sender` is the manager's direct caller, normally the router, **not the wallet**.
The hook does not distribute rewards to swappers and ignores `hookData` completely. Empty,
malformed and forged hook data cannot credit a wallet or router. Hook data is unauthenticated;
a future identity-based design would require its own authenticated context and review.

The later one-page static site should show current base fee, the 2× threshold, 3 gwei floor,
a chosen gas price's tier, recent `FeeCharged` events with high-tier flags, both fee accruals,
a donate action and a swap form. For nonzero base fee, the first high-tier gas price is
`max(2 * baseFee + 1 wei, baseFee + 3 gwei)`; at zero base fee there is no high tier.

Approved Sepolia integration addresses from the workflow:

- PoolSwapTest: `0x9B6b46e2c869aa39918Db7f52f5557FE577B6eEe`.
- StateView: `0xE1Dd9c3fA50EDB962E442f60DfBc432e24537E4C`.
- V4Quoter: `0x61B3f2011A92d183C7dbaDBdA940a7555Ccf9227`.

Use StateView for pool state and V4Quoter for quotes. PoolSwapTest forwards hookData and
sqrtPriceLimitX96; amountSpecified is negative for exact input and zeroForOne is ETH-in
for this pool. With ordinary token settlement, its settings are `takeClaims=false` and
`settleUsingBurn=false`. Supply enough native value for buys, including an exact-output
input fee; GASP sells require router allowance. Respect user price/slippage limits and
possible partial fills. This test router exposes a price limit, not an independent minimum
output/deadline guarantee; the frontend must present its actual constraints accurately.

RPC simulation gas context must match the intended effective gas price and current base fee;
default zero-price or zero-base-fee simulations quote the low tier. Requote near submission,
apply the actual fee tier and handle base-fee changes before inclusion. Service verification
of these live addresses and quote behavior remains necessary. The later site is a static
export with `dist/index.html`, no backend, and the approved site label above.
