// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookTestBase} from "./helpers/HookTestBase.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";

/// @notice Exercise actual swaps, balances and ERC-6909 claims against an independent fee oracle.
/// @dev No mocked manager or hook callbacks. Transaction gas inputs span the uint64 range
/// accepted by Foundry, including gasPrice < baseFee; the pure view also checks uint256 edges.
contract GasPriceFeeHookFuzzTest is HookTestBase, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;

    struct Balances {
        uint256 wallet0;
        uint256 wallet1;
        uint256 manager0;
        uint256 manager1;
        uint256 accrued0;
        uint256 accrued1;
        uint256 claims0;
        uint256 claims1;
    }

    function setUp() public override {
        super.setUp();
        _seed(key, -600, 600, int256(uint256(LIQUIDITY)));
    }

    function testFuzz_swapSizeDirectionModeAndGasRule(
        uint128 size,
        bool zeroForOne,
        bool exactInput,
        uint64 baseFee,
        uint64 gasPrice
    ) public {
        int256 amount = int256(bound(size, 1, 100 ether));
        _trade(key, zeroForOne, exactInput ? -amount : amount, baseFee, gasPrice);
        _assertClaims(key);
    }

    function testFuzz_doubleBaseFeeBoundary(uint96 size, uint64 baseSeed, bool zeroForOne, bool exactInput) public {
        // At these base fees the tip floor is already met at the 2x boundary.
        uint256 baseFee = bound(baseSeed, 3 gwei, type(uint64).max / 2);
        int256 amount = int256(bound(size, 1, 100 ether));
        if (exactInput) amount = -amount;
        for (uint256 i; i < 3; ++i) {
            uint256 gasPrice = 2 * baseFee - 1 + i;
            assertEq(hook.feeBpsFor(gasPrice, baseFee), i == 2 ? 300 : 30);
            _trade(key, zeroForOne, amount, baseFee, gasPrice);
        }
        _assertClaims(key);
    }

    function testFuzz_minimumTipBoundary(uint96 size, uint32 baseSeed, bool zeroForOne, bool exactInput) public {
        // Below 3 gwei the tip floor, rather than doubling alone, decides the tier.
        uint256 baseFee = bound(baseSeed, 1, 3 gwei - 1);
        int256 amount = int256(bound(size, 1, 100 ether));
        if (exactInput) amount = -amount;
        for (uint256 i; i < 3; ++i) {
            uint256 gasPrice = baseFee + 3 gwei - 1 + i;
            assertEq(hook.feeBpsFor(gasPrice, baseFee), i == 0 ? 30 : 300);
            _trade(key, zeroForOne, amount, baseFee, gasPrice);
        }
        _assertClaims(key);
    }

    function test_tipAndDoubleBaseFeeIntersectionInEveryMode() public {
        for (uint256 mode; mode < 4; ++mode) {
            for (uint256 i; i < 3; ++i) {
                uint256 baseFee = 3 gwei - 1 + i;
                uint256 gasPrice = baseFee + 3 gwei;
                // The tip is exactly the floor in all three cases; strict doubling still applies.
                assertEq(hook.feeBpsFor(gasPrice, baseFee), i == 0 ? 300 : 30);
                _trade(key, mode < 2, mode % 2 == 0 ? -int256(1 ether) : int256(1 ether), baseFee, gasPrice);
            }
        }
        _assertClaims(key);
    }

    function testFuzz_zeroBaseFeeUsesDocumentedLowTier(uint64 gasPrice, bool zeroForOne, bool exactInput) public {
        assertEq(hook.feeBpsFor(gasPrice, 0), 30);
        _trade(key, zeroForOne, exactInput ? -int256(1 ether) : int256(1 ether), 0, gasPrice);
        _assertClaims(key);
    }

    function test_feeBpsForUint256Boundaries() public view {
        assertEq(hook.feeBpsFor(type(uint256).max, type(uint256).max / 2), 300);
        assertEq(hook.feeBpsFor(type(uint256).max - 1, type(uint256).max / 2), 30);
        assertEq(hook.feeBpsFor(type(uint256).max, type(uint256).max / 2 + 1), 30);
        assertEq(hook.feeBpsFor(type(uint256).max, type(uint256).max), 30);
        assertEq(hook.feeBpsFor(0, type(uint256).max), 30);
        assertEq(hook.feeBpsFor(type(uint256).max, 0), 30);
    }

    function test_uint64GasBoundariesInEveryMode() public {
        uint256 maximum = type(uint64).max;
        uint256[5] memory bases = [maximum / 2, maximum / 2 + 1, maximum, maximum, uint256(0)];
        uint256[5] memory prices = [maximum, maximum, maximum, uint256(0), maximum];
        for (uint256 mode; mode < 4; ++mode) {
            for (uint256 i; i < bases.length; ++i) {
                assertEq(hook.feeBpsFor(prices[i], bases[i]), i == 0 ? 300 : 30);
                _trade(key, mode < 2, mode % 2 == 0 ? -int256(1 ether) : int256(1 ether), bases[i], prices[i]);
            }
        }
        _assertClaims(key);
    }

    function testFuzz_partialFillChargesActualUnspecifiedAmount(
        uint256 size,
        uint8 ticks,
        bool zeroForOne,
        bool exactInput,
        uint64 baseFee,
        uint64 gasPrice
    ) public {
        // At most ten ticks consume less than the router's 1000 ETH funding, even when the
        // requested amount is int256.max. All four modes must stop short at the price limit.
        int256 amount = int256(bound(size, 1000 ether, uint256(type(int256).max)));
        int24 distance = int24(int256(bound(ticks, 1, 10)));
        SwapParams memory params = SwapParams(
            zeroForOne, exactInput ? -amount : amount, TickMath.getSqrtPriceAtTick(zeroForOne ? -distance : distance)
        );
        _checkedSwap(key, params, baseFee, gasPrice, false);
        _assertClaims(key);
    }

    function test_int256MinimumExactInputPartialFillBothDirections() public {
        _checkedSwap(key, SwapParams(true, type(int256).min, TickMath.getSqrtPriceAtTick(-1)), 1 gwei, 4 gwei, false);
        _checkedSwap(key, SwapParams(false, type(int256).min, TickMath.getSqrtPriceAtTick(1)), 1 gwei, 2 gwei, false);
        _assertClaims(key);
    }

    function test_tinySwapsAndRoundingInEveryModeAndTier() public {
        // Includes zero-output swaps, a fee equal to the entire one-wei output, and amounts
        // straddling useful rounding boundaries. Exact division is covered by the oracle too.
        uint256[10] memory sizes = [uint256(1), 2, 3, 33, 34, 333, 334, 9999, 10_000, 10_001];
        for (uint256 tier; tier < 2; ++tier) {
            for (uint256 mode; mode < 4; ++mode) {
                for (uint256 i; i < sizes.length; ++i) {
                    int256 amount = int256(sizes[i]);
                    _trade(key, mode < 2, mode % 2 == 0 ? -amount : amount, 1 gwei, tier == 0 ? 2 gwei : 4 gwei);
                }
            }
        }
        _assertClaims(key);
    }

    function testFuzz_claimsAcrossPoolsEqualIndependentlyComputedFees(bytes32 seed) public {
        MockERC20 other = new MockERC20("Fee test", "FEE", 1_000_000_000 ether);
        other.approve(address(router), type(uint256).max);
        other.approve(address(lp), type(uint256).max);

        PoolKey[3] memory pools;
        pools[0] = key;
        pools[1] = key;
        pools[1].fee = 500;
        pools[2] = key;
        (pools[2].currency0, pools[2].currency1) = address(token) < address(other)
            ? (Currency.wrap(address(token)), Currency.wrap(address(other)))
            : (Currency.wrap(address(other)), Currency.wrap(address(token)));
        for (uint256 i = 1; i < 3; ++i) {
            manager.initialize(pools[i], PRICE_ONE);
            _seed(pools[i], -600, 600, int256(uint256(LIQUIDITY)));
        }

        Currency[3] memory currencies = [key.currency0, key.currency1, Currency.wrap(address(other))];
        uint256[2][3] memory expected;
        uint256 start = uint256(seed) % 3;
        for (uint256 i; i < 12; ++i) {
            uint256 entropy = uint256(keccak256(abi.encode(seed, i)));
            uint256 poolIndex = (start + i) % 3;
            int256 amount = int256(bound(uint96(entropy), 1, 10 ether));
            uint256 baseFee = uint64(entropy >> 96) % (10 gwei);
            uint256 gasPrice = uint64(entropy >> 160) % (25 gwei);
            (uint256 fee0, uint256 fee1) =
                _trade(pools[poolIndex], entropy & 1 == 0, entropy & 2 == 0 ? -amount : amount, baseFee, gasPrice);
            expected[poolIndex][0] += fee0;
            expected[poolIndex][1] += fee1;
            _assertPortfolio(pools, currencies, expected);

            if (i % 4 == 3) {
                // Drain a different pool while retaining the others' claims in shared currencies.
                uint256 donated = (poolIndex + 1) % 3;
                hook.donateFees(pools[donated]);
                expected[donated][0] = 0;
                expected[donated][1] = 0;
                _assertPortfolio(pools, currencies, expected);
            }
        }
        for (uint256 i; i < 3; ++i) {
            hook.donateFees(pools[i]);
            expected[i][0] = 0;
            expected[i][1] = 0;
            _assertPortfolio(pools, currencies, expected);
        }
    }

    function testFuzz_zeroSwapRejectsWithoutChangingExistingFees(bool zeroForOne, uint64 baseFee, uint64 gasPrice)
        public
    {
        _primeFees();
        bytes32 beforeState = _stateDigest();
        vm.fee(baseFee);
        vm.txGasPrice(gasPrice);
        vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        _swap(key, zeroForOne, 0);
        assertEq(_stateDigest(), beforeState, "zero swap changed state");
        _assertClaims(key);
    }

    function testFuzz_invalidPriceLimitPreservesExistingFees(
        uint96 size,
        bool zeroForOne,
        bool exactInput,
        uint8 failureKind,
        uint64 baseFee,
        uint64 gasPrice
    ) public {
        _primeFees();
        bytes32 beforeState = _stateDigest();
        (uint160 price,,,) = manager.getSlot0(key.toId());
        int256 amount = int256(bound(size, 1, 100 ether));
        uint160 limit;
        bytes memory reason;
        if (failureKind % 3 == 2) {
            limit = zeroForOne ? TickMath.MIN_SQRT_PRICE : TickMath.MAX_SQRT_PRICE;
            reason = abi.encodeWithSelector(Pool.PriceLimitOutOfBounds.selector, limit);
        } else {
            limit = failureKind % 3 == 0 ? price : (zeroForOne ? price + 1 : price - 1);
            reason = abi.encodeWithSelector(Pool.PriceLimitAlreadyExceeded.selector, price, limit);
        }
        vm.fee(baseFee);
        vm.txGasPrice(gasPrice);
        vm.expectRevert(reason);
        _swapWithLimit(key, zeroForOne, exactInput ? -amount : amount, limit, "");
        assertEq(_stateDigest(), beforeState, "rejected price limit changed state");
        _assertClaims(key);
    }

    function testFuzz_oneWeiUnderpaymentRollsBackMintedFees(
        uint96 size,
        bool zeroForOne,
        bool exactInput,
        uint64 baseFee,
        uint64 gasPrice
    ) public {
        _primeFees();
        bytes32 beforeState = _stateDigest();
        int256 amount = int256(bound(size, 1 gwei, 100 ether));
        SwapParams memory params = _params(zeroForOne, exactInput ? -amount : amount);
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        Currency output = zeroForOne ? key.currency1 : key.currency0;
        Currency feeCurrency = exactInput ? output : input;
        vm.fee(baseFee);
        vm.txGasPrice(gasPrice);
        // Prove execution reached the hook's claim mint before the final settlement rejection.
        vm.expectCall(
            address(manager), abi.encodeWithSelector(IPoolManager.mint.selector, address(hook), feeCurrency.toId())
        );
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        manager.unlock(abi.encode(params));
        assertEq(_stateDigest(), beforeState, "underpayment did not roll back the swap and claims");
        _assertClaims(key);

        // The same trade with full payment must still work after the failed unlock.
        _trade(key, zeroForOne, params.amountSpecified, baseFee, gasPrice);
        _assertClaims(key);
    }

    /// @dev Deliberately pay one wei less than the real debt, after the real hook has minted.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        SwapParams memory params = abi.decode(data, (SwapParams));
        BalanceDelta delta = manager.swap(key, params, "");
        Currency input = params.zeroForOne ? key.currency0 : key.currency1;
        Currency output = params.zeroForOne ? key.currency1 : key.currency0;
        int256 debt = params.zeroForOne ? int256(delta.amount0()) : int256(delta.amount1());
        int256 credit = params.zeroForOne ? int256(delta.amount1()) : int256(delta.amount0());
        assertLt(debt, 0);
        assertGe(credit, 0);
        input.settle(manager, address(this), uint256(-debt) - 1, false);
        if (credit != 0) output.take(manager, address(this), uint256(credit), false);
        return "";
    }

    function _trade(PoolKey memory pool, bool zeroForOne, int256 amount, uint256 baseFee, uint256 gasPrice)
        internal
        returns (uint256 fee0, uint256 fee1)
    {
        return _checkedSwap(pool, _params(zeroForOne, amount), baseFee, gasPrice, true);
    }

    function _params(bool zeroForOne, int256 amount) internal pure returns (SwapParams memory) {
        return SwapParams(zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
    }

    function _expectedBps(uint256 baseFee, uint256 gasPrice) internal pure returns (uint256) {
        // Literal specification with an explicit overflow guard, independent of feeBpsFor.
        if (baseFee == 0 || baseFee > type(uint256).max / 2 || gasPrice <= 2 * baseFee) return 30;
        return gasPrice - baseFee >= 3 gwei ? 300 : 30;
    }

    function _magnitude(int256 value) internal pure returns (uint256) {
        return value < 0 ? uint256(-(value + 1)) + 1 : uint256(value);
    }

    function _checkedSwap(
        PoolKey memory pool,
        SwapParams memory params,
        uint256 baseFee,
        uint256 gasPrice,
        bool fullFill
    ) internal returns (uint256 fee0, uint256 fee1) {
        Balances memory beforeSwap = _balances(pool);
        vm.fee(baseFee);
        vm.txGasPrice(gasPrice);
        vm.recordLogs();
        BalanceDelta net = _swapWithLimit(pool, params.zeroForOne, params.amountSpecified, params.sqrtPriceLimitX96, "");
        (BalanceDelta raw, FeeLog memory fee) = _logs(pool, vm.getRecordedLogs());

        // The core event is the AMM delta before afterSwap, already including the LP fee.
        // Choose input/output first, then exactness, rather than copying the hook's branch.
        int256 rawInput = params.zeroForOne ? int256(raw.amount0()) : int256(raw.amount1());
        int256 rawOutput = params.zeroForOne ? int256(raw.amount1()) : int256(raw.amount0());
        assertLe(rawInput, 0, "AMM input sign");
        assertGe(rawOutput, 0, "AMM output sign");
        bool exactInput = params.amountSpecified < 0;
        uint256 unspecified = exactInput ? uint256(rawOutput) : uint256(-rawInput);
        uint256 bps = _expectedBps(baseFee, gasPrice);
        uint256 product = unspecified * bps;
        uint256 expectedFee = product / 10_000 + (product % 10_000 == 0 ? 0 : 1);
        assertLe(fee.fee, unspecified, "fee exceeds the actual unspecified amount");
        assertEq(fee.fee, expectedFee, "ceil fee formula");

        Currency input = params.zeroForOne ? pool.currency0 : pool.currency1;
        Currency output = params.zeroForOne ? pool.currency1 : pool.currency0;
        Currency feeCurrency = exactInput ? output : input;
        assertEq(Currency.unwrap(fee.currency), Currency.unwrap(feeCurrency), "fee currency");
        assertEq(fee.sender, address(router), "event sender");
        assertEq(fee.highTier, bps == 300, "event tier");
        assertEq(fee.baseFee, baseFee, "event base fee");
        assertEq(fee.gasPrice, gasPrice, "event gas price");
        assertEq(hook.feeBpsFor(gasPrice, baseFee), bps, "view and callback tier agree");

        fee0 = feeCurrency == pool.currency0 ? expectedFee : 0;
        fee1 = feeCurrency == pool.currency1 ? expectedFee : 0;
        assertEq(int256(net.amount0()), int256(raw.amount0()) - int256(fee0), "swapper delta0");
        assertEq(int256(net.amount1()), int256(raw.amount1()) - int256(fee1), "swapper delta1");

        uint256 filled = exactInput ? uint256(-rawInput) : uint256(rawOutput);
        if (fullFill) {
            assertEq(filled, _magnitude(params.amountSpecified), "specified side must remain unchanged");
        } else {
            assertLt(filled, _magnitude(params.amountSpecified), "fixture must actually partially fill");
            (uint160 price,,,) = manager.getSlot0(pool.toId());
            assertEq(price, params.sqrtPriceLimitX96, "partial fill price limit");
        }

        Balances memory afterSwap = _balances(pool);
        assertEq(int256(afterSwap.wallet0) - int256(beforeSwap.wallet0), int256(net.amount0()), "wallet currency0");
        assertEq(int256(afterSwap.wallet1) - int256(beforeSwap.wallet1), int256(net.amount1()), "wallet currency1");
        assertEq(int256(afterSwap.manager0) - int256(beforeSwap.manager0), -int256(net.amount0()), "manager currency0");
        assertEq(int256(afterSwap.manager1) - int256(beforeSwap.manager1), -int256(net.amount1()), "manager currency1");
        assertEq(afterSwap.accrued0, beforeSwap.accrued0 + fee0, "pool accrued0");
        assertEq(afterSwap.accrued1, beforeSwap.accrued1 + fee1, "pool accrued1");
        assertEq(afterSwap.claims0, beforeSwap.claims0 + fee0, "minted currency0 claims");
        assertEq(afterSwap.claims1, beforeSwap.claims1 + fee1, "minted currency1 claims");
        assertEq(pool.currency0.balanceOf(address(hook)), 0, "hook must retain claims only");
        assertEq(pool.currency1.balanceOf(address(hook)), 0, "hook must retain claims only");
        assertEq(pool.currency0.balanceOf(address(router)), 0, "router left currency0 unsettled");
        assertEq(pool.currency1.balanceOf(address(router)), 0, "router left currency1 unsettled");
        _assertSettled();
    }

    function _balances(PoolKey memory pool) internal view returns (Balances memory b) {
        b.wallet0 = pool.currency0.balanceOf(address(this));
        b.wallet1 = pool.currency1.balanceOf(address(this));
        b.manager0 = pool.currency0.balanceOf(address(manager));
        b.manager1 = pool.currency1.balanceOf(address(manager));
        (b.accrued0, b.accrued1) = hook.accrued(pool.toId());
        b.claims0 = manager.balanceOf(address(hook), pool.currency0.toId());
        b.claims1 = manager.balanceOf(address(hook), pool.currency1.toId());
    }

    function _assertPortfolio(PoolKey[3] memory pools, Currency[3] memory currencies, uint256[2][3] memory expected)
        internal
        view
    {
        for (uint256 i; i < 3; ++i) {
            (uint256 a0, uint256 a1) = hook.accrued(pools[i].toId());
            assertEq(a0, expected[i][0], "pool currency0 independent fee total");
            assertEq(a1, expected[i][1], "pool currency1 independent fee total");
            uint256 total;
            for (uint256 j; j < 3; ++j) {
                if (pools[j].currency0 == currencies[i]) total += expected[j][0];
                if (pools[j].currency1 == currencies[i]) total += expected[j][1];
            }
            assertEq(manager.balanceOf(address(hook), currencies[i].toId()), total, "claims across pools");
        }
        _assertSettled();
    }

    function _primeFees() internal {
        _trade(key, true, -int256(1 ether), 1 gwei, 4 gwei);
        _trade(key, false, -int256(1 ether), 1 gwei, 4 gwei);
        (uint256 a0, uint256 a1) = hook.accrued(key.toId());
        assertGt(a0, 0);
        assertGt(a1, 0);
    }

    function _stateDigest() internal view returns (bytes32) {
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());
        (uint256 growth0, uint256 growth1) = manager.getFeeGrowthGlobals(key.toId());
        return keccak256(
            abi.encode(
                _balances(key), price, tick, protocolFee, lpFee, growth0, growth1, manager.getLiquidity(key.toId())
            )
        );
    }
}
