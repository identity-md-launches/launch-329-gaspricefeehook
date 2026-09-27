// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookTestBase} from "./helpers/HookTestBase.sol";
import {GasPriceFeeHook} from "../src/GasPriceFeeHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

contract GasPriceFeeHookTest is HookTestBase, IUnlockCallback {
    using StateLibrary for IPoolManager;

    event FeesDonated(PoolId indexed poolId, uint256 amount0, uint256 amount1);

    function test_exactPermissionsAndConstructor() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        Hooks.Permissions memory expected;
        expected.afterSwap = true;
        expected.afterSwapReturnDelta = true;
        assertEq(abi.encode(p), abi.encode(expected));
        assertEq(HookFlags.flagsOf(address(hook)), 0x44);
        assertEq(address(hook.poolManager()), address(manager));
    }

    function test_constructorRejectsWrongAddressFlags() public {
        // A normal CREATE address lacks the required bits in this fixture.
        vm.expectRevert();
        new GasPriceFeeHook(manager);
    }

    function test_tierBoundaryWithActualSwaps() public {
        _seed(key, -600, 600, int256(uint256(LIQUIDITY)));
        _checkTier(4 gwei, 8 gwei - 1, false);
        _checkTier(4 gwei, 8 gwei, false);
        _checkTier(4 gwei, 8 gwei + 1, true);
        _checkTier(1 gwei, 4 gwei - 1, false);
        _checkTier(1 gwei, 4 gwei, true);
        _checkTier(1 gwei, 4 gwei + 1, true);
        _checkTier(3 gwei, 6 gwei, false);
        _checkTier(3 gwei, 6 gwei + 1, true);
        _checkTier(1, 2, false);
        _checkTier(1, 3, false);
        _checkTier(1, 3 gwei, false);
        _checkTier(1, 3 gwei + 1, true);
        _checkTier(0, 10 gwei, false);
        _checkTier(1 gwei, 0, false);
        _assertClaims(key);
    }

    function _checkTier(uint256 baseFee, uint256 gasPrice, bool high) internal {
        vm.fee(baseFee);
        vm.txGasPrice(gasPrice);
        assertEq(hook.feeBpsFor(gasPrice, baseFee), high ? 300 : 30);
        _checkSwap(key, true, -int256(1 ether), high ? 300 : 30);
    }

    function testFuzz_feeBpsForIsTotalAndMatchesRule(uint256 gasPrice, uint256 baseFee) public view {
        bool high;
        if (baseFee != 0 && baseFee <= type(uint256).max / 2 && gasPrice > 2 * baseFee) {
            high = gasPrice - baseFee >= 3 gwei;
        }
        assertEq(hook.feeBpsFor(gasPrice, baseFee), high ? 300 : 30);
    }

    function test_feeFormulaExactInputAndOutputInBothDirectionsAndTiers() public {
        _seed(key, -600, 600, int256(uint256(LIQUIDITY)));
        for (uint256 tier; tier < 2; ++tier) {
            vm.txGasPrice(tier == 0 ? 2 gwei : 4 gwei);
            uint24 bps = tier == 0 ? 30 : 300;
            _checkSwap(key, true, -int256(1 ether), bps);
            _checkSwap(key, false, -int256(1 ether), bps);
            _checkSwap(key, true, int256(1 ether), bps);
            _checkSwap(key, false, int256(1 ether), bps);
        }
        _assertClaims(key);
    }

    function testFuzz_feeRoundingAndAccounting(uint96 size, bool zeroForOne, bool exactInput, bool high) public {
        _seed(key, -600, 600, int256(uint256(LIQUIDITY)));
        uint256 amount = bound(size, 1, 100 ether);
        vm.txGasPrice(high ? 4 gwei : 2 gwei);
        _checkSwap(key, zeroForOne, exactInput ? -int256(amount) : int256(amount), high ? 300 : 30);
        _assertClaims(key);
    }

    function test_oneWeiFeeCapAndZeroOutput() public {
        _seed(key, -600, 600, int256(uint256(LIQUIDITY)));
        // One input wei is entirely LP fee: no output, no hook fee.
        _checkSwap(key, true, -1, 30);
        // Three input wei produce one output wei: ceil fee is one, net output zero.
        _checkSwap(key, true, -3, 30);
        (, uint256 fees1) = hook.accrued(key.toId());
        assertEq(fees1, 1);
        _assertClaims(key);
    }

    function _checkSwap(PoolKey memory pool, bool zeroForOne, int256 amount, uint24 bps) internal {
        (uint256 before0, uint256 before1) = hook.accrued(pool.toId());
        vm.recordLogs();
        BalanceDelta net = _swap(pool, zeroForOne, amount);
        (BalanceDelta raw, FeeLog memory fee) = _logs(pool, vm.getRecordedLogs());
        bool c0 = zeroForOne == (amount > 0);
        int256 unspecified = c0 ? int256(raw.amount0()) : int256(raw.amount1());
        uint256 absolute = uint256(unspecified < 0 ? -unspecified : unspecified);
        // Independent quotient/remainder expression verifies rounding.
        uint256 product = absolute * bps;
        uint256 expected = product / 10_000 + (product % 10_000 == 0 ? 0 : 1);
        assertLe(expected, absolute);
        assertEq(fee.fee, expected);
        assertEq(fee.sender, address(router));
        assertEq(fee.highTier, bps == 300);
        assertEq(fee.gasPrice, tx.gasprice);
        assertEq(fee.baseFee, block.basefee);
        assertEq(Currency.unwrap(fee.currency), Currency.unwrap(c0 ? pool.currency0 : pool.currency1));
        assertEq(int256(net.amount0()), int256(raw.amount0()) - (c0 ? int256(expected) : int256(0)));
        assertEq(int256(net.amount1()), int256(raw.amount1()) - (c0 ? int256(0) : int256(expected)));
        (uint256 after0, uint256 after1) = hook.accrued(pool.toId());
        assertEq(after0, before0 + (c0 ? expected : 0));
        assertEq(after1, before1 + (c0 ? 0 : expected));
        _assertSettled();
    }

    function test_launchRehearsalFirstBuyIntoEthlessPoolThenSellAndDonate() public {
        BalanceDelta seed = _seed(key, -600, -60, int256(uint256(LIQUIDITY)));
        assertEq(seed.amount0(), 0);
        assertLt(seed.amount1(), 0);
        assertEq(address(manager).balance, 0);
        assertEq(manager.getLiquidity(key.toId()), 0);
        vm.expectRevert(GasPriceFeeHook.NoLiquidity.selector);
        hook.donateFees(key);
        vm.txGasPrice(4 gwei);
        _checkSwap(key, true, -int256(10 ether), 300);
        assertGt(address(manager).balance, 0);
        assertGt(manager.getLiquidity(key.toId()), 0);
        _checkSwap(key, false, -int256(1 ether), 300);
        _assertClaims(key);
        _assertDonation(key, -600, -60);
        // Complete the local lifecycle: LP principal and accumulated fees remain withdrawable.
        _seed(key, -600, -60, -int256(uint256(LIQUIDITY)));
        assertEq(manager.getLiquidity(key.toId()), 0);
        _assertClaims(key);
    }

    function test_donateBothCurrenciesCreditsInRangeLpAndIsPermissionless() public {
        _seed(key, -600, 600, int256(uint256(LIQUIDITY)));
        // Out-of-range position must receive none of the donation.
        _seed(key, 1200, 1800, int256(uint256(LIQUIDITY)));
        _swap(key, true, -int256(1 ether));
        _swap(key, false, -int256(1 ether));
        (uint256 out0, uint256 out1) = manager.getFeeGrowthInside(key.toId(), 1200, 1800);
        _assertDonation(key, -600, 600);
        (uint256 outAfter0, uint256 outAfter1) = manager.getFeeGrowthInside(key.toId(), 1200, 1800);
        assertEq(outAfter0, out0);
        assertEq(outAfter1, out1);
        // Repeated donation with no new swaps is harmless and does not pay twice.
        _assertDonation(key, -600, 600);
    }

    function _assertDonation(PoolKey memory pool, int24 lower, int24 upper) internal {
        (uint256 a0, uint256 a1) = hook.accrued(pool.toId());
        // Realize swap fees first, isolating the subsequent LP donation payout.
        _seed(pool, lower, upper, 0);
        (uint256 before0, uint256 before1) = manager.getFeeGrowthGlobals(pool.toId());
        uint128 active = manager.getLiquidity(pool.toId());
        uint256 managerEth = address(manager).balance;
        uint256 managerGasp = token.balanceOf(address(manager));
        vm.expectEmit(true, false, false, true, address(hook));
        emit FeesDonated(pool.toId(), a0, a1);
        vm.prank(address(0xCAFE));
        hook.donateFees(pool);
        (uint256 after0, uint256 after1) = manager.getFeeGrowthGlobals(pool.toId());
        assertEq(after0 - before0, FullMath.mulDiv(a0, 1 << 128, active));
        assertEq(after1 - before1, FullMath.mulDiv(a1, 1 << 128, active));
        assertEq(address(manager).balance, managerEth);
        assertEq(token.balanceOf(address(manager)), managerGasp);
        (uint256 rem0, uint256 rem1) = hook.accrued(pool.toId());
        assertEq(rem0, 0);
        assertEq(rem1, 0);
        BalanceDelta collected = _seed(pool, lower, upper, 0);
        // Power-of-two fixture liquidity makes both fee-growth divisions exact.
        assertEq(uint128(collected.amount0()), a0);
        assertEq(uint128(collected.amount1()), a1);
        _assertClaims(pool);
    }

    function test_noLiquidityPreservesClaimsUntilLiquidityReturns() public {
        _seed(key, -600, 600, int256(uint256(LIQUIDITY)));
        _swap(key, true, -int256(1 ether));
        _swap(key, false, -int256(1 ether));
        _seed(key, -600, 600, -int256(uint256(LIQUIDITY)));
        (uint256 a0, uint256 a1) = hook.accrued(key.toId());
        assertGt(a0, 0);
        assertGt(a1, 0);
        vm.expectRevert(GasPriceFeeHook.NoLiquidity.selector);
        hook.donateFees(key);
        (uint256 b0, uint256 b1) = hook.accrued(key.toId());
        assertEq(a0, b0);
        assertEq(a1, b1);
        _assertClaims(key);
        _seed(key, -600, 600, int256(uint256(LIQUIDITY)));
        _assertDonation(key, -600, 600);
    }

    function test_poolAccountingIsIsolatedWhenCurrenciesAreShared() public {
        PoolKey memory other = key;
        other.fee = 500;
        manager.initialize(other, PRICE_ONE);
        _seed(key, -600, 600, int256(uint256(LIQUIDITY)));
        _seed(other, -600, 600, int256(uint256(LIQUIDITY)));
        _swap(key, true, -int256(1 ether));
        _swap(other, false, -int256(2 ether));
        (uint256 a0, uint256 a1) = hook.accrued(key.toId());
        (uint256 b0, uint256 b1) = hook.accrued(other.toId());
        assertEq(manager.balanceOf(address(hook), key.currency0.toId()), a0 + b0);
        assertEq(manager.balanceOf(address(hook), key.currency1.toId()), a1 + b1);
        hook.donateFees(key);
        (uint256 keep0, uint256 keep1) = hook.accrued(other.toId());
        assertEq(keep0, b0);
        assertEq(keep1, b1);
        _assertClaims(other);
        hook.donateFees(other);
        _assertClaims(key);
    }

    function test_arbitraryErc20PoolCanAttachHook() public {
        MockERC20 other = new MockERC20("Other", "OTH", 1_000_000_000 ether);
        other.approve(address(router), type(uint256).max);
        other.approve(address(lp), type(uint256).max);
        (Currency c0, Currency c1) = address(token) < address(other)
            ? (Currency.wrap(address(token)), Currency.wrap(address(other)))
            : (Currency.wrap(address(other)), Currency.wrap(address(token)));
        PoolKey memory ercPool = PoolKey(c0, c1, 3000, 60, IHooks(address(hook)));
        manager.initialize(ercPool, PRICE_ONE);
        _seed(ercPool, -600, 600, int256(uint256(LIQUIDITY)));
        _checkSwap(ercPool, true, -int256(1 ether), 30);
        _checkSwap(ercPool, false, -int256(1 ether), 30);
        _checkSwap(ercPool, true, int256(1 ether), 30);
        _checkSwap(ercPool, false, int256(1 ether), 30);
        _assertClaims(ercPool);
        hook.donateFees(ercPool);
        _assertClaims(ercPool);
    }

    function test_callbacksRefuseUntrustedCallersAndUnsolicitedUnlocks() public {
        SwapParams memory params = SwapParams(true, -1, PRICE_ONE - 1);
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.unlockCallback(abi.encode(key));
        vm.prank(address(manager));
        vm.expectRevert(GasPriceFeeHook.UnexpectedUnlock.selector);
        hook.unlockCallback(abi.encode(key));
        PoolKey memory wrong = key;
        wrong.hooks = IHooks(address(0));
        vm.expectRevert(GasPriceFeeHook.InvalidPool.selector);
        hook.donateFees(wrong);
        _assertClaims(key);
    }

    function test_nestedUnlockCannotDonateAndDoesNotCorruptGuard() public {
        _seed(key, -600, 600, int256(uint256(LIQUIDITY)));
        _swap(key, true, -int256(1 ether));
        vm.expectRevert(IPoolManager.AlreadyUnlocked.selector);
        manager.unlock("");
        _assertClaims(key);
        hook.donateFees(key);
        _assertClaims(key);
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(manager));
        hook.donateFees(key);
        return "";
    }

    function test_failedSwapSettlementRollsBackFeesAndPoolState() public {
        _seed(key, -600, 600, int256(uint256(LIQUIDITY)));
        (uint160 priceBefore,,,) = manager.getSlot0(key.toId());
        token.approve(address(router), 0);
        vm.expectRevert();
        _swap(key, false, -int256(1 ether));
        (uint160 priceAfter,,,) = manager.getSlot0(key.toId());
        assertEq(priceBefore, priceAfter);
        _assertClaims(key);
        (uint256 a0, uint256 a1) = hook.accrued(key.toId());
        assertEq(a0 + a1, 0);
    }

    function test_failedDonationAfterBurnRollsBackClaimsAndGuard() public {
        _seed(key, -600, 600, int256(uint256(LIQUIDITY)));
        _swap(key, true, -int256(1 ether));
        _swap(key, false, -int256(1 ether));
        (uint256 a0, uint256 a1) = hook.accrued(key.toId());
        bytes memory failure = abi.encodeWithSignature("DonationFailure()");
        vm.mockCallRevert(address(manager), abi.encodeCall(IPoolManager.donate, (key, a0, a1, bytes(""))), failure);
        vm.expectRevert(failure);
        hook.donateFees(key);
        (uint256 after0, uint256 after1) = hook.accrued(key.toId());
        assertEq(after0, a0);
        assertEq(after1, a1);
        _assertClaims(key);
        vm.clearMockedCalls();
        _assertDonation(key, -600, 600);
    }

    function test_partialFillUsesActualDeltaAndRespectsPriceLimit() public {
        _seed(key, -600, 600, int256(uint256(LIQUIDITY)));
        uint160 limit = TickMath.getSqrtPriceAtTick(-1);
        vm.recordLogs();
        BalanceDelta net = _swapWithLimit(key, true, -int256(100 ether), limit, hex"1234");
        (BalanceDelta raw, FeeLog memory fee) = _logs(key, vm.getRecordedLogs());
        assertGt(int256(raw.amount0()), -int256(100 ether));
        uint256 expected = (uint256(uint128(raw.amount1())) * 30 + 9999) / 10_000;
        assertEq(fee.fee, expected);
        assertEq(int256(net.amount1()), int256(raw.amount1()) - int256(expected));
        (uint160 price,,,) = manager.getSlot0(key.toId());
        assertEq(price, limit);
        _assertClaims(key);
    }

    function test_hookDataCannotAssignFeesToARouterOrUser() public {
        _seed(key, -600, 600, int256(uint256(LIQUIDITY)));
        _swapWithLimit(key, true, -int256(1 ether), TickMath.MIN_SQRT_PRICE + 1, abi.encode(address(0xBEEF)));
        _swapWithLimit(key, false, -int256(1 ether), TickMath.MAX_SQRT_PRICE - 1, hex"ff");
        _assertClaims(key);
        assertEq(manager.balanceOf(address(0xBEEF), key.currency0.toId()), 0);
        assertEq(manager.balanceOf(address(router), key.currency1.toId()), 0);
    }

    function test_runtimeHasNoEscapeHatches() public view {
        _scan(address(hook));
        _scan(address(token));
    }

    function _scan(address deployed) internal view {
        bytes memory code = deployed.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
            else assertTrue(op != 0xff && op != 0xf4 && op != 0xf2);
        }
    }
}
