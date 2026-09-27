// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {GASP} from "../../src/GASP.sol";
import {GasPriceFeeHook} from "../../src/GasPriceFeeHook.sol";
import {HookFlags} from "../../src/HookFlags.sol";

abstract contract HookTestBase is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    uint160 internal constant PRICE_ONE = 1 << 96;
    uint128 internal constant LIQUIDITY = 1 << 80;
    bytes32 internal constant SWAP_EVENT =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    bytes32 internal constant FEE_EVENT = keccak256("FeeCharged(bytes32,address,bool,uint256,uint256,address,uint256)");
    IPoolManager internal manager;
    GasPriceFeeHook internal hook;
    GASP internal token;
    PoolSwapTest internal router;
    PoolModifyLiquidityTest internal lp;
    PoolKey internal key;

    struct FeeLog {
        address sender;
        bool highTier;
        uint256 gasPrice;
        uint256 baseFee;
        Currency currency;
        uint256 fee;
    }

    function setUp() public virtual {
        manager = IPoolManager(address(new PoolManager(address(this))));
        hook = _deployHook(manager);
        token = new GASP();
        router = new PoolSwapTest(manager);
        lp = new PoolModifyLiquidityTest(manager);
        token.approve(address(router), type(uint256).max);
        token.approve(address(lp), type(uint256).max);
        vm.deal(address(this), 1_000_000_000 ether);
        vm.fee(1 gwei);
        vm.txGasPrice(2 gwei);
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(address(hook)));
        manager.initialize(key, PRICE_ONE);
    }

    function _deployHook(IPoolManager pm) internal returns (GasPriceFeeHook deployed) {
        bytes memory initCode = abi.encodePacked(type(GasPriceFeeHook).creationCode, abi.encode(pm));
        bytes32 codeHash = keccak256(initCode);
        for (uint256 i; i < 200_000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", address(this), salt, codeHash)))));
            if (HookFlags.matches(predicted, HookFlags.GAS_PRICE_FEE_HOOK)) {
                deployed = new GasPriceFeeHook{salt: salt}(pm);
                assertEq(address(deployed), predicted);
                return deployed;
            }
        }
        revert("hook salt not found");
    }

    function _seed(PoolKey memory pool, int24 lower, int24 upper, int256 amount) internal returns (BalanceDelta) {
        uint256 nativeValue = pool.currency0.isAddressZero() && amount > 0 ? 1_000_000 ether : 0;
        return lp.modifyLiquidity{value: nativeValue}(pool, ModifyLiquidityParams(lower, upper, amount, bytes32(0)), "");
    }

    function _swap(PoolKey memory pool, bool zeroForOne, int256 amount) internal returns (BalanceDelta) {
        return _swapWithLimit(
            pool, zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1, ""
        );
    }

    function _swapWithLimit(PoolKey memory pool, bool zeroForOne, int256 amount, uint160 limit, bytes memory data)
        internal
        returns (BalanceDelta)
    {
        return router.swap{value: pool.currency0.isAddressZero() && zeroForOne ? 1000 ether : 0}(
            pool, SwapParams(zeroForOne, amount, limit), PoolSwapTest.TestSettings(false, false), data
        );
    }

    function _logs(PoolKey memory pool, Vm.Log[] memory logs)
        internal
        view
        returns (BalanceDelta raw, FeeLog memory fee)
    {
        bool foundSwap;
        bool foundFee;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_EVENT) {
                assertEq(logs[i].topics[1], PoolId.unwrap(pool.toId()));
                (int128 a0, int128 a1,,,,) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                raw = toBalanceDelta(a0, a1);
                foundSwap = true;
            }
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == FEE_EVENT) {
                assertEq(logs[i].topics[1], PoolId.unwrap(pool.toId()));
                fee = abi.decode(logs[i].data, (FeeLog));
                foundFee = true;
            }
        }
        assertTrue(foundSwap, "missing core Swap event");
        assertTrue(foundFee, "missing hook FeeCharged event");
    }

    function _assertSettled() internal view {
        assertFalse(manager.isUnlocked());
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
    }

    function _assertClaims(PoolKey memory pool) internal view {
        (uint256 a0, uint256 a1) = hook.accrued(pool.toId());
        assertEq(manager.balanceOf(address(hook), pool.currency0.toId()), a0);
        assertEq(manager.balanceOf(address(hook), pool.currency1.toId()), a1);
        _assertSettled();
    }

    receive() external payable {}
}
