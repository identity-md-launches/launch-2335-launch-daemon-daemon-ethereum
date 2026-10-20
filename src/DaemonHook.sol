// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @title DAEMON / native ETH launch hook
/// @notice A zero-fee gate for the DAEMON/ETH Uniswap v4 pool. It exists so that only the launch
/// factory can open the pool this hook is mined for, and so that the pool's economics are exactly
/// the standard platform LP fee and nothing else.
///
/// What it does:
///  - `beforeInitialize` accepts exactly one pool, opened by the launch factory: DAEMON against
///    native ETH, at the standard LP fee tier and tick spacing. Anything else is refused, and a
///    second pool can never be attached to this hook.
///  - `beforeSwap` and `afterSwap` only verify that the PoolManager is calling about that pool and
///    return zero deltas and no LP fee override.
///
/// What it does not do, by construction:
///  - It takes no hook fee, holds no funds, has no fee recipient, treasury, claim, pause or setter.
///    No `*ReturnDelta` permission is declared, so the PoolManager ignores any delta a future bug
///    might return. The owner has no privileged function at all: an extra fee cannot be enabled later.
///  - It declares no liquidity callbacks, so the factory's fee collect (a zero liquidity change)
///    passes through untouched and no owner switch can ever block it.
contract DaemonHook is IHooks, Ownable {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    /// @notice The standard platform LP fee tier the pool opens at (1.25%, in hundredths of a bip).
    uint24 public constant LP_FEE = 12_500;

    /// @notice The tick spacing the launch pool opens with.
    int24 public constant TICK_SPACING = 60;

    /// @notice The PoolManager this hook serves. Only it may call any callback.
    IPoolManager public immutable poolManager;

    /// @notice The launch factory: the only sender allowed to initialize the pool.
    address public immutable factory;

    /// @notice The DAEMON token the pool must pair with native ETH.
    address public immutable token;

    /// @notice Id of the single pool this hook accepted, zero until the factory opens it.
    PoolId public poolId;

    /// @notice True once the launch pool has been initialized.
    bool public initialized;

    /// @notice Emitted when the launch pool is opened by the factory.
    event PoolInitialized(PoolId indexed id, uint160 sqrtPriceX96);

    error NotPoolManager();
    error NotFactory(address sender);
    error AlreadyInitialized();
    error NotNativePair();
    error WrongToken(address currency);
    error WrongFee(uint24 fee);
    error WrongTickSpacing(int24 tickSpacing);
    error WrongPool();
    error HookNotImplemented();
    error ZeroAddress();

    /// @param poolManager_ The chain's Uniswap v4 PoolManager (manifest: "$poolManager").
    /// @param factory_ The IMD launch factory that deploys this hook and opens the pool (manifest: "$factory").
    /// @param token_ The DAEMON token deployed just before this hook (manifest: "$token").
    /// @param owner_ The launch owner (manifest: "$owner"). Holds no power over fees or callbacks.
    /// @dev Makes no external call and requires no address to have code: the launch checks run it on an empty chain.
    constructor(IPoolManager poolManager_, address factory_, address token_, address owner_) Ownable(owner_) {
        if (address(poolManager_) == address(0) || factory_ == address(0) || token_ == address(0)) {
            revert ZeroAddress();
        }
        poolManager = poolManager_;
        factory = factory_;
        token = token_;
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    /// @notice The callbacks this hook implements; its address must carry exactly these bits.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    // ---------------------------------------------------------------------------------------------
    // Initialization
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IHooks
    /// @dev Accepts one pool, once, from the factory: native ETH as currency0 (address zero always
    /// sorts first), DAEMON as currency1, the standard LP fee and tick spacing.
    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        if (sender != factory) revert NotFactory(sender);
        if (initialized) revert AlreadyInitialized();
        if (!key.currency0.isAddressZero()) revert NotNativePair();
        if (Currency.unwrap(key.currency1) != token) revert WrongToken(Currency.unwrap(key.currency1));
        if (key.fee != LP_FEE) revert WrongFee(key.fee);
        if (key.tickSpacing != TICK_SPACING) revert WrongTickSpacing(key.tickSpacing);

        PoolId id = key.toId();
        poolId = id;
        initialized = true;
        emit PoolInitialized(id, sqrtPriceX96);
        return IHooks.beforeInitialize.selector;
    }

    /// @inheritdoc IHooks
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    // ---------------------------------------------------------------------------------------------
    // Swaps: zero hook delta, no LP fee override
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IHooks
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        external
        view
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _requireLaunchPool(key);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @inheritdoc IHooks
    function afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        view
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        _requireLaunchPool(key);
        return (IHooks.afterSwap.selector, 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Callbacks this hook does not declare. The PoolManager never calls them (the address carries no
    // bit for them); if anything else does, they revert.
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IHooks
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    /// @dev The PoolManager only routes a key whose `hooks` field is this contract, and this contract
    /// only ever initializes one pool; a key for any other pool is refused.
    function _requireLaunchPool(PoolKey calldata key) internal view {
        if (!initialized || PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert WrongPool();
    }
}
