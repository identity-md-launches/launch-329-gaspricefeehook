// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HookTestBase} from "./helpers/HookTestBase.sol";
import {GasPriceFeeHook} from "../src/GasPriceFeeHook.sol";
import {GASP} from "../src/GASP.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @dev Exercise the actual PoolManager with independently funded transactions. No mocks, forks,
/// filesystem access, or environment variables. The target selectors exclude inherited cheatcodes.
contract FeeHandler is Test {
    GasPriceFeeHook public immutable hook;
    PoolSwapTest public immutable router;
    PoolModifyLiquidityTest public immutable lp;
    PoolKey[] internal pools;
    bool[3] public active;
    uint256 public swaps;
    uint256 public donations;
    uint256 public deferredDonations;
    uint256 public liquidityChanges;
    uint128 internal constant LIQUIDITY = 1 << 80;

    constructor(
        GasPriceFeeHook hook_,
        GASP token,
        PoolSwapTest router_,
        PoolModifyLiquidityTest lp_,
        PoolKey[3] memory keys
    ) {
        hook = hook_;
        router = router_;
        lp = lp_;
        token.approve(address(router), type(uint256).max);
        token.approve(address(lp), type(uint256).max);
        for (uint256 i; i < 3; ++i) {
            pools.push(keys[i]);
            active[i] = true;
        }
    }

    function swap(uint8 poolIndex, uint96 size, bool zeroForOne, bool exactInput, bool high) external {
        uint256 i = poolIndex % 3;
        if (!active[i]) return;
        uint256 amount = bound(size, 1, 1 ether);
        vm.fee(1 gwei);
        vm.txGasPrice(high ? 4 gwei : 2 gwei);
        router.swap{value: zeroForOne ? 2 ether : 0}(
            pools[i],
            SwapParams(
                zeroForOne,
                exactInput ? -int256(amount) : int256(amount),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        swaps++;
    }

    function donate(uint8 poolIndex) external {
        uint256 i = poolIndex % 3;
        if (active[i]) {
            hook.donateFees(pools[i]);
            donations++;
        } else {
            (uint256 before0, uint256 before1) = hook.accrued(pools[i].toId());
            try hook.donateFees(pools[i]) {
                revert("donation without liquidity succeeded");
            } catch (bytes memory reason) {
                assertEq(reason, abi.encodeWithSelector(GasPriceFeeHook.NoLiquidity.selector));
            }
            (uint256 after0, uint256 after1) = hook.accrued(pools[i].toId());
            assertEq(after0, before0);
            assertEq(after1, before1);
            deferredDonations++;
        }
    }

    function toggleLiquidity(uint8 poolIndex) external {
        uint256 i = poolIndex % 3;
        int256 change = active[i] ? -int256(uint256(LIQUIDITY)) : int256(uint256(LIQUIDITY));
        lp.modifyLiquidity{value: active[i] ? 0 : 100_000 ether}(
            pools[i], ModifyLiquidityParams(-600, 600, change, bytes32(0)), ""
        );
        active[i] = !active[i];
        liquidityChanges++;
    }

    receive() external payable {}
}

contract GasPriceFeeHookInvariantTest is HookTestBase {
    using TransientStateLibrary for IPoolManager;
    FeeHandler internal handler;
    PoolKey[3] internal pools;
    uint256 internal nativeTotal;
    uint256 internal tokenTotal;

    function setUp() public override {
        super.setUp();
        pools[0] = key;
        pools[1] = key;
        pools[1].fee = 500;
        pools[2] = key;
        pools[2].fee = 10_000;
        for (uint256 i; i < 3; ++i) {
            if (i != 0) manager.initialize(pools[i], PRICE_ONE);
            _seed(pools[i], -600, 600, int256(uint256(LIQUIDITY)));
        }
        handler = new FeeHandler(hook, token, router, lp, pools);
        token.transfer(address(handler), 1_000_000 ether);
        vm.deal(address(handler), 1_000_000 ether);
        nativeTotal = address(this).balance + address(manager).balance + address(handler).balance;
        tokenTotal = token.totalSupply();
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = FeeHandler.swap.selector;
        selectors[1] = FeeHandler.donate.selector;
        selectors[2] = FeeHandler.toggleLiquidity.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
        // The fuzzer funds transaction senders for gas. Keep those accounts outside the
        // contracts whose ETH conservation we measure (all asset payments use the handler).
        targetSender(address(0xBEEF));
        targetSender(address(0xCAFE));
    }

    function invariant_claimsEqualSumAccruedAcrossPools() public view {
        uint256 sum0;
        uint256 sum1;
        for (uint256 i; i < 3; ++i) {
            (uint256 a0, uint256 a1) = hook.accrued(pools[i].toId());
            sum0 += a0;
            sum1 += a1;
        }
        assertEq(manager.balanceOf(address(hook), key.currency0.toId()), sum0);
        assertEq(manager.balanceOf(address(hook), key.currency1.toId()), sum1);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
    }

    function invariant_underlyingFundsConservedAndHookHoldsOnlyClaims() public view {
        assertEq(address(this).balance + address(manager).balance + address(handler).balance, nativeTotal);
        assertEq(
            token.balanceOf(address(this)) + token.balanceOf(address(manager)) + token.balanceOf(address(handler)),
            tokenTotal
        );
        assertEq(token.totalSupply(), tokenTotal);
        assertEq(address(router).balance + address(lp).balance + address(hook).balance, 0);
        assertEq(token.balanceOf(address(router)) + token.balanceOf(address(lp)) + token.balanceOf(address(hook)), 0);
    }
}
