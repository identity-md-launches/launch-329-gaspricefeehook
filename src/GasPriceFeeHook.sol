// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/// @title Gas Price Fee Hook
/// @notice Charges 30 or 300 bps on the unspecified swap currency; anyone may donate accrued
/// ERC-6909 claims back to the same pool's currently in-range liquidity providers.
/// @dev tx.gasprice is sender-chosen. This only taxes public priority bidding: a private bundle
/// with a low tip plus a direct coinbase payment avoids the high tier. Zero-base-fee simulations
/// use the low tier. No user identity is authenticated or credited; hookData is ignored.
/// The sender event field is the PoolManager caller (usually a router), not an authenticated user.
/// There is no owner, admin, upgrade, token allowlist, external oracle, or asset-transfer callback.
contract GasPriceFeeHook is BaseHook, IUnlockCallback {
    using StateLibrary for IPoolManager;

    uint256 public constant MIN_TIP = 3 gwei;
    uint24 public constant LOW_BPS = 30;
    uint24 public constant HIGH_BPS = 300;
    uint256 private constant BPS_DENOMINATOR = 10_000;

    struct AccruedFees {
        uint256 amount0;
        uint256 amount1;
    }

    /// @notice Claims attributed to a pool, in each currency's smallest units.
    mapping(PoolId poolId => AccruedFees) public accrued;

    enum DonationState {
        Idle,
        Pending,
        Executing
    }

    DonationState private donationState;
    PoolId private donationPool;

    error InvalidPoolManager();
    error InvalidPool();
    error NoLiquidity();
    error DonationInProgress();
    error UnexpectedUnlock();

    event FeeCharged(
        PoolId indexed poolId,
        address sender,
        bool highTier,
        uint256 gasPrice,
        uint256 baseFee,
        Currency currency,
        uint256 fee
    );
    event FeesDonated(PoolId indexed poolId, uint256 amount0, uint256 amount1);

    /// @param manager Sepolia PoolManager: 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543.
    /// @dev BaseHook validates that the deployed address has exactly permission bits 0x0044.
    constructor(IPoolManager manager) BaseHook(manager) {
        if (address(manager) == address(0)) revert InvalidPoolManager();
    }

    /// @notice Only afterSwap and afterSwapReturnDelta are enabled. Initialization and LP actions
    /// are unrestricted, including the launch factory's one-sided GASP liquidity seed.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.afterSwap = true;
        p.afterSwapReturnDelta = true;
    }

    /// @notice High tier requires gasPrice > 2 * baseFee AND gasPrice - baseFee >= MIN_TIP.
    /// @dev Zero base fee and gasPrice <= baseFee return LOW_BPS. Comparing tip > baseFee avoids
    /// overflow of 2 * baseFee and makes this function total over all uint256 input pairs.
    function feeBpsFor(uint256 gasPrice, uint256 baseFee) public pure returns (uint24) {
        if (baseFee == 0 || gasPrice <= baseFee) return LOW_BPS;
        uint256 tip = gasPrice - baseFee;
        return tip > baseFee && tip >= MIN_TIP ? HIGH_BPS : LOW_BPS;
    }

    /// @dev BaseHook authenticates the PoolManager before entering this callback. Negative
    /// amountSpecified means exact input: the fee reduces output. Exact output adds to input.
    /// The positive returned delta credits the hook; mint creates an equal debt, leaving zero net
    /// transient balance. No underlying ETH/ERC20 transfer occurs here, even in an ETH-less pool.
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        bool currency0Unspecified = params.zeroForOne == (params.amountSpecified > 0);
        int256 unspecified = currency0Unspecified ? int256(delta.amount0()) : int256(delta.amount1());
        // Widen before negation to handle int128.min without overflow.
        uint256 amount = uint256(unspecified < 0 ? -unspecified : unspecified);
        uint24 bps = feeBpsFor(tx.gasprice, block.basefee);
        // amount is at most 2**127, so multiplication and rounding cannot overflow uint256.
        uint256 fee = (amount * bps + BPS_DENOMINATOR - 1) / BPS_DENOMINATOR;
        if (fee > amount) fee = amount;

        PoolId id = key.toId();
        Currency currency = currency0Unspecified ? key.currency0 : key.currency1;
        if (fee != 0) {
            if (currency0Unspecified) accrued[id].amount0 += fee;
            else accrued[id].amount1 += fee;
            poolManager.mint(address(this), currency.toId(), fee);
        }
        emit FeeCharged(id, sender, bps == HIGH_BPS, tx.gasprice, block.basefee, currency, fee);
        // At most 3% of 2**127 fits in a positive int128.
        return (BaseHook.afterSwap.selector, int128(int256(fee)));
    }

    /// @notice Donate all of this pool's recorded claims to its currently in-range LPs.
    /// @dev Anyone can pay for this operation; no caller reward. With zero in-range liquidity it
    /// reverts NoLiquidity and preserves the claims. Must be called while PoolManager is locked.
    /// LP fee-growth accounting rounds down as in v4; small donations can leave rounding dust.
    function donateFees(PoolKey calldata key) external {
        if (donationState != DonationState.Idle) revert DonationInProgress();
        if (address(key.hooks) != address(this)) revert InvalidPool();
        donationPool = key.toId();
        donationState = DonationState.Pending;
        poolManager.unlock(abi.encode(key));
        // A legitimate manager must have consumed exactly one expected callback.
        if (donationState != DonationState.Executing) revert UnexpectedUnlock();
        donationState = DonationState.Idle;
        donationPool = PoolId.wrap(bytes32(0));
    }

    /// @notice PoolManager-only settlement callback for a pending donateFees call.
    /// @dev Consumes the pending callback before external calls. Claims are burned for positive
    /// transient credit, then donate debits the same amounts. A revert rolls back every effect.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        if (donationState != DonationState.Pending) revert UnexpectedUnlock();
        PoolKey memory key = abi.decode(data, (PoolKey));
        PoolId id = key.toId();
        if (PoolId.unwrap(id) != PoolId.unwrap(donationPool)) revert UnexpectedUnlock();
        donationState = DonationState.Executing;
        if (poolManager.getLiquidity(id) == 0) revert NoLiquidity();

        AccruedFees memory fees = accrued[id];
        delete accrued[id];
        if (fees.amount0 != 0) poolManager.burn(address(this), key.currency0.toId(), fees.amount0);
        if (fees.amount1 != 0) poolManager.burn(address(this), key.currency1.toId(), fees.amount1);
        poolManager.donate(key, fees.amount0, fees.amount1, "");
        emit FeesDonated(id, fees.amount0, fees.amount1);
        return "";
    }
}
