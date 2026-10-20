// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {DaemonHook} from "../src/DaemonHook.sol";
import {DaemonToken} from "../src/DaemonToken.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {LaunchFactoryMock} from "./utils/LaunchFactoryMock.sol";

/// @notice Edge and failure paths of the DAEMON launch hook, fuzzed where the input space is wide:
/// every initialization parameter the hook checks, every caller it must refuse, every key it must
/// refuse, and the opening price the launch reports.
contract DaemonHookEdgesTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    /// @dev 1e8 DAEMON per ETH: the 10 ETH opening cap for the whole 1e9 supply.
    uint160 constant SQRT_PRICE_LAUNCH = 10_000 * 79228162514264337593543950336;
    uint24 constant LP_FEE = 12_500;
    int24 constant TICK_SPACING = 60;
    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint160 constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG;
    address constant OWNER = address(0x0A11E5);
    uint128 constant SEED_LIQUIDITY = 1e21;

    PoolManager manager;
    DaemonToken token;
    LaunchFactoryMock factory;
    DaemonHook hook;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;
    PoolKey key;
    PoolKey plainKey;
    int24 lower;
    int24 upper;

    receive() external payable {}

    function setUp() public {
        manager = new PoolManager(address(this));
        token = new DaemonToken();
        factory = new LaunchFactoryMock(manager);
        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);

        bytes memory code = abi.encodePacked(
            type(DaemonHook).creationCode, abi.encode(manager, address(factory), address(token), OWNER)
        );
        (, bytes32 salt) = HookMiner.find(address(factory), FLAGS, code);
        hook = DaemonHook(factory.deploy(code, salt));

        key = PoolKey(
            CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(token)), LP_FEE, TICK_SPACING, IHooks(address(hook))
        );
        plainKey = key;
        plainKey.hooks = IHooks(address(0));
        lower = TickMath.minUsableTick(TICK_SPACING);
        upper = TickMath.maxUsableTick(TICK_SPACING);

        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(lpRouter), type(uint256).max);
        vm.deal(address(this), 1e27);
        vm.deal(address(factory), 1e24);
        token.transfer(address(factory), 1e26);
    }

    // ---------------------------------------------------------------------------------------------
    // Initialization: each checked parameter, fuzzed
    // ---------------------------------------------------------------------------------------------

    function testFuzz_initializationFromAnySenderButTheFactoryReverts(address sender) public {
        vm.assume(sender != address(factory));
        vm.prank(sender);
        vm.expectRevert(
            _wrapped(IHooks.beforeInitialize.selector, abi.encodeWithSelector(DaemonHook.NotFactory.selector, sender))
        );
        manager.initialize(key, SQRT_PRICE_LAUNCH);
        assertFalse(hook.initialized());
    }

    function testFuzz_initializationAtAnyOtherFeeReverts(uint24 fee) public {
        fee = uint24(bound(fee, 0, 1_000_000));
        if (fee == LP_FEE) fee = LP_FEE + 1;
        PoolKey memory bad = key;
        bad.fee = fee;
        vm.expectRevert(
            _wrapped(IHooks.beforeInitialize.selector, abi.encodeWithSelector(DaemonHook.WrongFee.selector, fee))
        );
        factory.initialize(bad, SQRT_PRICE_LAUNCH);
        assertFalse(hook.initialized());
    }

    function testFuzz_initializationAtAnyOtherTickSpacingReverts(int24 spacing) public {
        spacing = int24(bound(int256(spacing), 1, 32_767));
        if (spacing == TICK_SPACING) spacing = TICK_SPACING + 1;
        PoolKey memory bad = key;
        bad.tickSpacing = spacing;
        vm.expectRevert(
            _wrapped(
                IHooks.beforeInitialize.selector, abi.encodeWithSelector(DaemonHook.WrongTickSpacing.selector, spacing)
            )
        );
        factory.initialize(bad, SQRT_PRICE_LAUNCH);
        assertFalse(hook.initialized());
    }

    function testFuzz_initializationAgainstAnyOtherTokenReverts(address other) public {
        vm.assume(other != address(0) && other != address(token));
        PoolKey memory bad = key;
        bad.currency1 = Currency.wrap(other);
        vm.expectRevert(
            _wrapped(IHooks.beforeInitialize.selector, abi.encodeWithSelector(DaemonHook.WrongToken.selector, other))
        );
        factory.initialize(bad, SQRT_PRICE_LAUNCH);
        assertFalse(hook.initialized());
    }

    /// @dev DAEMON as currency0 against a token sorting above it: the pair is not native ETH.
    function test_initializationWithDaemonAsCurrency0Reverts() public {
        PoolKey memory bad = key;
        bad.currency0 = Currency.wrap(address(token));
        bad.currency1 = Currency.wrap(address(type(uint160).max));
        vm.expectRevert(
            _wrapped(IHooks.beforeInitialize.selector, abi.encodeWithSelector(DaemonHook.NotNativePair.selector))
        );
        factory.initialize(bad, SQRT_PRICE_LAUNCH);
    }

    /// @dev The factory may open the pool at whatever price the launch derives; the hook does not
    /// second-guess it.
    function testFuzz_factoryOpensThePoolAtAnyValidPrice(uint160 price) public {
        price = uint160(bound(price, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));
        factory.initialize(key, price);
        assertTrue(hook.initialized());
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(key.toId()));
        (uint160 p,,, uint24 lpFee) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(p, price);
        assertEq(lpFee, LP_FEE);
    }

    /// @dev Through the manager, the hook's own guard fires before the manager's
    /// PoolAlreadyInitialized, for the same key and for any other key.
    function test_factoryCannotInitializeASecondTimeThroughTheManager() public {
        factory.initialize(key, SQRT_PRICE_LAUNCH);
        vm.expectRevert(
            _wrapped(IHooks.beforeInitialize.selector, abi.encodeWithSelector(DaemonHook.AlreadyInitialized.selector))
        );
        factory.initialize(key, SQRT_PRICE_1_1);

        PoolKey memory other = key;
        other.fee = 3_000;
        vm.expectRevert(
            _wrapped(IHooks.beforeInitialize.selector, abi.encodeWithSelector(DaemonHook.AlreadyInitialized.selector))
        );
        factory.initialize(other, SQRT_PRICE_1_1);
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(key.toId()), "the recorded pool must not change");
    }

    /// @dev A refused initialization leaves nothing behind: the factory can still open the pool after.
    function test_aRefusedAttemptDoesNotBlockTheFactory() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        manager.initialize(key, SQRT_PRICE_1_1);
        PoolKey memory bad = key;
        bad.fee = 3_000;
        vm.expectRevert();
        factory.initialize(bad, SQRT_PRICE_LAUNCH);

        factory.initialize(key, SQRT_PRICE_LAUNCH);
        assertTrue(hook.initialized());
    }

    function test_noTradeOrLiquidityBeforeTheFactoryOpensThePool() public {
        vm.expectRevert(Pool.PoolNotInitialized.selector);
        swapRouter.swap{value: 1 ether}(
            key, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1), PoolSwapTest.TestSettings(false, false), ""
        );
        vm.expectRevert(Pool.PoolNotInitialized.selector);
        lpRouter.modifyLiquidity{value: 1 ether}(key, ModifyLiquidityParams(lower, upper, 1e18, 0), "");
    }

    // ---------------------------------------------------------------------------------------------
    // Callback access: any non-manager caller, any foreign key
    // ---------------------------------------------------------------------------------------------

    function testFuzz_swapCallbacksRefuseAnyCallerButTheManager(address caller, address senderField, bool zeroForOne)
        public
    {
        vm.assume(caller != address(manager));
        factory.initialize(key, SQRT_PRICE_1_1);
        SwapParams memory params = SwapParams(zeroForOne, -1 ether, SQRT_PRICE_1_1);
        vm.startPrank(caller);
        vm.expectRevert(DaemonHook.NotPoolManager.selector);
        hook.beforeSwap(senderField, key, params, "");
        vm.expectRevert(DaemonHook.NotPoolManager.selector);
        hook.afterSwap(senderField, key, params, BalanceDelta.wrap(0), "");
        vm.expectRevert(DaemonHook.NotPoolManager.selector);
        hook.beforeInitialize(address(factory), key, SQRT_PRICE_1_1);
        vm.stopPrank();
    }

    /// @dev Even with the manager as caller, a key differing from the launch pool in any field is refused.
    function testFuzz_swapCallbacksRefuseAnyKeyButTheLaunchPool(uint8 field, uint256 value) public {
        factory.initialize(key, SQRT_PRICE_1_1);
        PoolKey memory other = key;
        field = field % 5;
        if (field == 0) {
            other.currency0 = Currency.wrap(address(uint160(bound(value, 1, type(uint160).max))));
        } else if (field == 1) {
            other.currency1 = Currency.wrap(address(uint160(value) ^ uint160(address(token)) | 1));
        } else if (field == 2) {
            other.fee =
                uint24(bound(value, 0, type(uint24).max)) == LP_FEE ? 0 : uint24(bound(value, 0, type(uint24).max));
        } else if (field == 3) {
            other.tickSpacing = int24(int256(bound(value, 61, 32_767)));
        } else {
            other.hooks = IHooks(address(uint160(value) | 1));
        }
        vm.assume(PoolId.unwrap(other.toId()) != PoolId.unwrap(key.toId()));

        SwapParams memory params = SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1);
        vm.startPrank(address(manager));
        vm.expectRevert(DaemonHook.WrongPool.selector);
        hook.beforeSwap(address(this), other, params, "");
        vm.expectRevert(DaemonHook.WrongPool.selector);
        hook.afterSwap(address(this), other, params, BalanceDelta.wrap(0), "");
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------------
    // Trades: hook data is ignored, the owner is powerless, the opening cap is what the README reports
    // ---------------------------------------------------------------------------------------------

    function testFuzz_hookDataNeverChangesATrade(bytes calldata hookData, uint96 amount, bool zeroForOne) public {
        uint256 amt = bound(amount, 1e6, 50 ether);
        _openBoth(SQRT_PRICE_1_1);
        BalanceDelta hooked = _swap(key, zeroForOne, -int256(amt), hookData);
        BalanceDelta plain = _swap(plainKey, zeroForOne, -int256(amt), "");
        assertEq(BalanceDelta.unwrap(hooked), BalanceDelta.unwrap(plain));
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
    }

    function test_renouncedOwnershipChangesNothing() public {
        _openBoth(SQRT_PRICE_1_1);
        vm.prank(OWNER);
        hook.renounceOwnership();
        assertEq(hook.owner(), address(0));
        BalanceDelta hooked = _swap(key, true, -1 ether, "");
        BalanceDelta plain = _swap(plainKey, true, -1 ether, "");
        assertEq(BalanceDelta.unwrap(hooked), BalanceDelta.unwrap(plain));
        (int128 fee0,) = factory.modify(key, lower, upper, 0);
        assertGt(fee0, 0, "the factory still collects its LP fee");
    }

    /// @dev The opening price the launch reports: 1e8 DAEMON per ETH, so the whole 1,000,000,000
    /// supply is worth 10 ETH at the pool's own opening price, at the standard 1.25% LP fee.
    function test_openingPriceIsTheReportedTenEthCap() public {
        factory.initialize(key, SQRT_PRICE_LAUNCH);
        (uint160 p,,, uint24 lpFee) = IPoolManager(address(manager)).getSlot0(key.toId());
        // DAEMON is currency1: price = DAEMON per ETH = (p / 2^96)^2.
        uint256 daemonPerEth = (uint256(p) * uint256(p)) >> 192;
        assertEq(daemonPerEth, 1e8);
        assertEq(SUPPLY / daemonPerEth, 10 ether, "initial cap of the whole supply in ETH");
        assertEq(lpFee, 12_500, "standard platform LP fee, 1.25%");
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.decimals(), 18);
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    function _openBoth(uint160 price) internal {
        factory.initialize(key, price);
        factory.modify(key, lower, upper, int256(uint256(SEED_LIQUIDITY)));
        manager.initialize(plainKey, price);
        lpRouter.modifyLiquidity{value: 1e24}(
            plainKey, ModifyLiquidityParams(lower, upper, int256(uint256(SEED_LIQUIDITY)), 0), ""
        );
    }

    function _swap(PoolKey memory k, bool zeroForOne, int256 amountSpecified, bytes memory hookData)
        internal
        returns (BalanceDelta)
    {
        uint256 value = zeroForOne ? uint256(-amountSpecified) : 0;
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        return swapRouter.swap{value: value}(
            k, SwapParams(zeroForOne, amountSpecified, limit), PoolSwapTest.TestSettings(false, false), hookData
        );
    }

    function _wrapped(bytes4 callback, bytes memory reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            callback,
            reason,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }
}
