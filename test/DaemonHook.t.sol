// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {DaemonHook} from "../src/DaemonHook.sol";
import {DaemonToken} from "../src/DaemonToken.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {LaunchFactoryMock} from "./utils/LaunchFactoryMock.sol";
import {MockERC20} from "./utils/MockERC20.sol";

contract DaemonHookTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    /// @dev 1e8 DAEMON per ETH (10 ETH for the whole 1e9 supply): sqrt(1e8) * 2^96.
    uint160 constant SQRT_PRICE_LAUNCH = 10_000 * 79228162514264337593543950336;
    uint24 constant LP_FEE = 12_500;
    int24 constant TICK_SPACING = 60;
    uint160 constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG;
    address constant OWNER = address(0x0A11E5);
    uint128 constant SEED_LIQUIDITY = 1e21;

    PoolManager manager;
    DaemonToken token;
    LaunchFactoryMock factory;
    DaemonHook hook;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;

    PoolKey key; // the launch pool, on the hook
    PoolKey plainKey; // the same pool with no hook, as the reference for "the hook changes nothing"
    int24 lower;
    int24 upper;

    receive() external payable {}

    function setUp() public {
        manager = new PoolManager(address(this));
        token = new DaemonToken();
        factory = new LaunchFactoryMock(manager);
        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);

        hook = DaemonHook(_deployHook(address(factory), address(token), OWNER));

        key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
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
    // Deployment and permissions
    // ---------------------------------------------------------------------------------------------

    function test_constructorRecordsItsArgumentsAndOwner() public view {
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.factory(), address(factory));
        assertEq(hook.token(), address(token));
        assertEq(hook.owner(), OWNER);
        assertTrue(hook.owner() != address(factory), "the factory must not own the hook");
        assertTrue(hook.owner() != address(this), "the deployer's caller must not own the hook");
        assertEq(hook.LP_FEE(), LP_FEE);
        assertEq(hook.TICK_SPACING(), TICK_SPACING);
        assertFalse(hook.initialized());
        assertEq(PoolId.unwrap(hook.poolId()), bytes32(0));
    }

    function test_permissionsMatchTheAddressBits() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize);
        assertTrue(p.beforeSwap);
        assertTrue(p.afterSwap);
        assertFalse(p.afterInitialize);
        assertFalse(p.beforeAddLiquidity);
        assertFalse(p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
        assertFalse(p.beforeSwapReturnDelta, "a zero-fee hook must not be able to return a swap delta");
        assertFalse(p.afterSwapReturnDelta, "a zero-fee hook must not be able to return a swap delta");
        assertFalse(p.afterAddLiquidityReturnDelta);
        assertFalse(p.afterRemoveLiquidityReturnDelta);
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, FLAGS);
        Hooks.validateHookPermissions(IHooks(address(hook)), p);
    }

    function test_deploymentAtAnAddressWithOtherBitsReverts() public {
        bytes memory code = _creationCode(address(factory), address(token), OWNER);
        (, bytes32 salt) = HookMiner.find(address(factory), Hooks.BEFORE_INITIALIZE_FLAG, code);
        address deployed = factory.tryDeploy(code, salt);
        assertEq(deployed, address(0), "a hook whose address disagrees with its permissions must not deploy");
    }

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(DaemonHook.ZeroAddress.selector);
        new DaemonHook(IPoolManager(address(0)), address(factory), address(token), OWNER);
        vm.expectRevert(DaemonHook.ZeroAddress.selector);
        new DaemonHook(manager, address(0), address(token), OWNER);
        vm.expectRevert(DaemonHook.ZeroAddress.selector);
        new DaemonHook(manager, address(factory), address(0), OWNER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new DaemonHook(manager, address(factory), address(token), address(0));
    }

    // ---------------------------------------------------------------------------------------------
    // Initialization
    // ---------------------------------------------------------------------------------------------

    function test_factoryInitializesTheLaunchPool() public {
        vm.expectEmit(true, false, false, true, address(hook));
        emit DaemonHook.PoolInitialized(key.toId(), SQRT_PRICE_LAUNCH);
        int24 tick = factory.initialize(key, SQRT_PRICE_LAUNCH);
        assertEq(tick, TickMath.getTickAtSqrtPrice(SQRT_PRICE_LAUNCH));
        assertTrue(hook.initialized());
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(key.toId()));
        (uint160 price,, uint24 protocolFee, uint24 lpFee) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(price, SQRT_PRICE_LAUNCH);
        assertEq(lpFee, LP_FEE, "the pool opens at the standard LP fee");
        assertEq(protocolFee, 0);
    }

    function test_initializationFromAnyoneButTheFactoryReverts() public {
        address stranger = address(0xBAD);
        vm.prank(stranger);
        vm.expectRevert(
            _wrapped(IHooks.beforeInitialize.selector, abi.encodeWithSelector(DaemonHook.NotFactory.selector, stranger))
        );
        manager.initialize(key, SQRT_PRICE_1_1);
        assertFalse(hook.initialized());

        // Not even the hook's owner.
        vm.prank(OWNER);
        vm.expectRevert(
            _wrapped(IHooks.beforeInitialize.selector, abi.encodeWithSelector(DaemonHook.NotFactory.selector, OWNER))
        );
        manager.initialize(key, SQRT_PRICE_1_1);
        assertFalse(hook.initialized());
    }

    function test_initializationOfAnotherPairReverts() public {
        // A token/token pool where DAEMON is not paired with native ETH.
        MockERC20 other = new MockERC20("Other", "OTHER", 0);
        PoolKey memory bad = key;
        if (address(other) < address(token)) {
            bad.currency0 = Currency.wrap(address(other));
        } else {
            bad.currency0 = Currency.wrap(address(token));
            bad.currency1 = Currency.wrap(address(other));
        }
        vm.expectRevert(
            _wrapped(IHooks.beforeInitialize.selector, abi.encodeWithSelector(DaemonHook.NotNativePair.selector))
        );
        factory.initialize(bad, SQRT_PRICE_1_1);

        // Native ETH against a token that is not DAEMON.
        bad = key;
        bad.currency1 = Currency.wrap(address(other));
        vm.expectRevert(
            _wrapped(
                IHooks.beforeInitialize.selector, abi.encodeWithSelector(DaemonHook.WrongToken.selector, address(other))
            )
        );
        factory.initialize(bad, SQRT_PRICE_1_1);
        assertFalse(hook.initialized());
    }

    function test_initializationAtAnotherFeeOrSpacingReverts() public {
        PoolKey memory bad = key;
        bad.fee = 3_000;
        vm.expectRevert(
            _wrapped(
                IHooks.beforeInitialize.selector, abi.encodeWithSelector(DaemonHook.WrongFee.selector, uint24(3_000))
            )
        );
        factory.initialize(bad, SQRT_PRICE_1_1);

        bad = key;
        bad.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        vm.expectRevert(
            _wrapped(
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(DaemonHook.WrongFee.selector, LPFeeLibrary.DYNAMIC_FEE_FLAG)
            )
        );
        factory.initialize(bad, SQRT_PRICE_1_1);

        bad = key;
        bad.fee = 0;
        vm.expectRevert(
            _wrapped(IHooks.beforeInitialize.selector, abi.encodeWithSelector(DaemonHook.WrongFee.selector, uint24(0)))
        );
        factory.initialize(bad, SQRT_PRICE_1_1);

        bad = key;
        bad.tickSpacing = 10;
        vm.expectRevert(
            _wrapped(
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(DaemonHook.WrongTickSpacing.selector, int24(10))
            )
        );
        factory.initialize(bad, SQRT_PRICE_1_1);
        assertFalse(hook.initialized());
    }

    function test_onlyOnePoolCanEverBeInitialized() public {
        factory.initialize(key, SQRT_PRICE_1_1);
        // The manager's own guard is PoolAlreadyInitialized; the hook refuses first, and would also
        // refuse a second key, which here can only differ by failing another check anyway.
        vm.prank(address(manager));
        vm.expectRevert(DaemonHook.AlreadyInitialized.selector);
        hook.beforeInitialize(address(factory), key, SQRT_PRICE_1_1);
    }

    function test_beforeInitializeRefusesCallersOtherThanThePoolManager() public {
        vm.prank(address(factory));
        vm.expectRevert(DaemonHook.NotPoolManager.selector);
        hook.beforeInitialize(address(factory), key, SQRT_PRICE_1_1);
        vm.expectRevert(DaemonHook.NotPoolManager.selector);
        hook.beforeInitialize(address(factory), key, SQRT_PRICE_1_1);
        assertFalse(hook.initialized());
    }

    // ---------------------------------------------------------------------------------------------
    // Swaps: zero hook fee, zero deltas, standard LP fee only
    // ---------------------------------------------------------------------------------------------

    function test_swapCallbacksRefuseCallersOtherThanThePoolManager() public {
        _openLaunchPool(SQRT_PRICE_1_1);
        SwapParams memory params = SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1);
        vm.expectRevert(DaemonHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, params, "");
        vm.expectRevert(DaemonHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");
    }

    function test_swapCallbacksRefuseAnyPoolButTheLaunchPool() public {
        SwapParams memory params = SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1);
        // Before the launch pool exists, nothing is accepted.
        vm.prank(address(manager));
        vm.expectRevert(DaemonHook.WrongPool.selector);
        hook.beforeSwap(address(this), key, params, "");

        _openLaunchPool(SQRT_PRICE_1_1);
        PoolKey memory other = key;
        other.fee = 3_000;
        vm.prank(address(manager));
        vm.expectRevert(DaemonHook.WrongPool.selector);
        hook.beforeSwap(address(this), other, params, "");
        vm.prank(address(manager));
        vm.expectRevert(DaemonHook.WrongPool.selector);
        hook.afterSwap(address(this), other, params, BalanceDelta.wrap(0), "");
    }

    function test_swapCallbacksReturnZeroDeltaAndNoFeeOverride() public {
        _openLaunchPool(SQRT_PRICE_1_1);
        SwapParams memory params = SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1);
        vm.prank(address(manager));
        (bytes4 sel, BeforeSwapDelta delta, uint24 feeOverride) = hook.beforeSwap(address(this), key, params, "");
        assertEq(sel, IHooks.beforeSwap.selector);
        assertEq(BeforeSwapDelta.unwrap(delta), 0);
        assertEq(BeforeSwapDeltaLibrary.getSpecifiedDelta(delta), 0);
        assertEq(BeforeSwapDeltaLibrary.getUnspecifiedDelta(delta), 0);
        assertEq(feeOverride, 0, "no LP fee override");

        vm.prank(address(manager));
        (bytes4 sel2, int128 afterDelta) = hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");
        assertEq(sel2, IHooks.afterSwap.selector);
        assertEq(afterDelta, 0);
    }

    function test_buyAndSellExactInputMatchAHooklessPoolAndLeaveTheHookEmpty() public {
        _openLaunchPool(SQRT_PRICE_1_1);
        // Buy: ETH in, DAEMON out.
        BalanceDelta hooked = _swap(key, true, -1 ether);
        BalanceDelta plain = _swap(plainKey, true, -1 ether);
        assertEq(hooked.amount0(), -1 ether, "exact input charged");
        assertGt(hooked.amount1(), 0, "output received");
        assertEq(BalanceDelta.unwrap(hooked), BalanceDelta.unwrap(plain), "buy: hook changed the trade");
        _assertHookHoldsNothing();

        // Sell: DAEMON in, ETH out.
        hooked = _swap(key, false, -1 ether);
        plain = _swap(plainKey, false, -1 ether);
        assertEq(hooked.amount1(), -1 ether, "exact input charged");
        assertGt(hooked.amount0(), 0, "output received");
        assertEq(BalanceDelta.unwrap(hooked), BalanceDelta.unwrap(plain), "sell: hook changed the trade");
        _assertHookHoldsNothing();
    }

    function test_buyAndSellExactOutputMatchAHooklessPoolAndLeaveTheHookEmpty() public {
        _openLaunchPool(SQRT_PRICE_1_1);
        BalanceDelta hooked = _swap(key, true, 1 ether);
        BalanceDelta plain = _swap(plainKey, true, 1 ether);
        assertEq(hooked.amount1(), 1 ether, "exact output delivered");
        assertLt(hooked.amount0(), 0, "input charged");
        assertEq(BalanceDelta.unwrap(hooked), BalanceDelta.unwrap(plain), "buy: hook changed the trade");
        _assertHookHoldsNothing();

        hooked = _swap(key, false, 1 ether);
        plain = _swap(plainKey, false, 1 ether);
        assertEq(hooked.amount0(), 1 ether, "exact output delivered");
        assertLt(hooked.amount1(), 0, "input charged");
        assertEq(BalanceDelta.unwrap(hooked), BalanceDelta.unwrap(plain), "sell: hook changed the trade");
        _assertHookHoldsNothing();
    }

    function test_swapsWorkAtTheLaunchOpeningPrice() public {
        _openLaunchPool(SQRT_PRICE_LAUNCH);
        BalanceDelta hooked = _swap(key, true, -0.01 ether);
        BalanceDelta plain = _swap(plainKey, true, -0.01 ether);
        assertEq(BalanceDelta.unwrap(hooked), BalanceDelta.unwrap(plain));
        // 1e8 DAEMON per ETH, less the 1.25% LP fee (987,500 at most) and the price impact of a
        // 0.01 ETH buy against 1e21 liquidity (about 9% at this price).
        assertGt(hooked.amount1(), 850_000 ether);
        assertLt(hooked.amount1(), 987_500 ether);
        _assertHookHoldsNothing();
    }

    /// @dev The pool's ETH balance is only what the swaps settled; the hook never took or minted a claim.
    function test_swapOnAPoolSeededWithTokensOnlyNeedsNoEthInTheManager() public {
        // Seed a range entirely below the current tick: with ETH as currency0 such a position holds
        // DAEMON (currency1) only, so the manager starts with no ETH at all. A buy moves into it.
        factory.initialize(key, SQRT_PRICE_1_1);
        factory.modify(key, -3 * TICK_SPACING, -TICK_SPACING, int256(uint256(SEED_LIQUIDITY)));
        assertEq(address(manager).balance, 0, "no ETH in the manager before the first buy");
        BalanceDelta d = _swap(key, true, -0.001 ether);
        assertEq(d.amount0(), -0.001 ether);
        assertGt(d.amount1(), 0);
        assertEq(address(manager).balance, 0.001 ether, "the manager holds exactly the buyer's ETH");
        _assertHookHoldsNothing();
    }

    function testFuzz_swapsNeverChangeTheTradeOrFundTheHook(uint96 amountIn, bool zeroForOne) public {
        amountIn = uint96(bound(amountIn, 1e6, 100 ether));
        _openLaunchPool(SQRT_PRICE_1_1);
        BalanceDelta hooked = _swap(key, zeroForOne, -int256(uint256(amountIn)));
        BalanceDelta plain = _swap(plainKey, zeroForOne, -int256(uint256(amountIn)));
        assertEq(BalanceDelta.unwrap(hooked), BalanceDelta.unwrap(plain), "the hook changed the trade");
        if (zeroForOne) assertEq(hooked.amount0(), -int256(uint256(amountIn)));
        else assertEq(hooked.amount1(), -int256(uint256(amountIn)));
        _assertHookHoldsNothing();
    }

    // ---------------------------------------------------------------------------------------------
    // LP fee and the factory's collect
    // ---------------------------------------------------------------------------------------------

    function test_lpFeeAccruesToTheFactoryPositionAndCollectPassesThrough() public {
        factory.initialize(key, SQRT_PRICE_1_1);
        factory.modify(key, lower, upper, int256(uint256(SEED_LIQUIDITY)));

        _swap(key, true, -1 ether);
        _swap(key, false, -1 ether);

        uint256 ethBefore = address(factory).balance;
        uint256 tokBefore = token.balanceOf(address(factory));
        (int128 fee0, int128 fee1) = factory.modify(key, lower, upper, 0);
        assertGt(fee0, 0, "ETH LP fees accrued to the factory position");
        assertGt(fee1, 0, "DAEMON LP fees accrued to the factory position");
        // 1.25% of a 1 ETH exact-input buy is 0.0125 ETH, all of it to liquidity (one position).
        assertApproxEqAbs(uint256(uint128(fee0)), 0.0125 ether, 1e6);
        assertApproxEqAbs(uint256(uint128(fee1)), 0.0125 ether, 1e6);
        assertEq(address(factory).balance - ethBefore, uint256(uint128(fee0)));
        assertEq(token.balanceOf(address(factory)) - tokBefore, uint256(uint128(fee1)));
        _assertHookHoldsNothing();
    }

    function test_factoryCanRemoveItsLiquidity() public {
        factory.initialize(key, SQRT_PRICE_1_1);
        factory.modify(key, lower, upper, int256(uint256(SEED_LIQUIDITY)));
        (int128 a0, int128 a1) = factory.modify(key, lower, upper, -int256(uint256(SEED_LIQUIDITY)));
        assertGt(a0, 0);
        assertGt(a1, 0);
        assertEq(IPoolManager(address(manager)).getLiquidity(key.toId()), 0);
    }

    function test_anyoneCanAddAndRemoveLiquidity() public {
        _openLaunchPool(SQRT_PRICE_1_1);
        BalanceDelta added = lpRouter.modifyLiquidity{value: 10 ether}(
            key, ModifyLiquidityParams(lower, upper, 1e18, bytes32(uint256(1))), ""
        );
        assertLt(added.amount0(), 0);
        assertLt(added.amount1(), 0);
        BalanceDelta removed =
            lpRouter.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, -1e18, bytes32(uint256(1))), "");
        assertGt(removed.amount0(), 0);
        assertGt(removed.amount1(), 0);
        _assertHookHoldsNothing();
    }

    // ---------------------------------------------------------------------------------------------
    // No admin surface: the owner cannot enable a fee, pause or claim anything
    // ---------------------------------------------------------------------------------------------

    function test_ownerHasNoFeeOrPauseEntryPoint() public {
        _openLaunchPool(SQRT_PRICE_1_1);
        string[14] memory signatures = [
            "setFee(uint24)",
            "setHookFee(uint24)",
            "setSwapFee(uint24)",
            "setFeeBps(uint256)",
            "setFeeRecipient(address)",
            "setTreasury(address)",
            "setLPFee(uint24)",
            "updateDynamicLPFee(uint24)",
            "pause()",
            "setPaused(bool)",
            "claimFees()",
            "collectFees(address)",
            "withdraw(address,uint256)",
            "setGame(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], uint256(100_000), uint256(1));
            vm.prank(OWNER);
            (bool ok,) = address(hook).call(data);
            assertFalse(ok, signatures[i]);
        }
        // Trades are unchanged afterwards.
        BalanceDelta hooked = _swap(key, true, -1 ether);
        BalanceDelta plain = _swap(plainKey, true, -1 ether);
        assertEq(BalanceDelta.unwrap(hooked), BalanceDelta.unwrap(plain));
        _assertHookHoldsNothing();
    }

    function test_ownershipIsTransferableButPowerless() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xBAD)));
        hook.transferOwnership(address(0xBAD));

        vm.prank(OWNER);
        hook.transferOwnership(address(0xCAFE));
        assertEq(hook.owner(), address(0xCAFE));
        // The owner still cannot open the pool: only the factory can.
        vm.prank(address(0xCAFE));
        vm.expectRevert(
            _wrapped(
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(DaemonHook.NotFactory.selector, address(0xCAFE))
            )
        );
        manager.initialize(key, SQRT_PRICE_1_1);
    }

    function test_undeclaredCallbacksRevert() public {
        ModifyLiquidityParams memory lp = ModifyLiquidityParams(lower, upper, 1, 0);
        BalanceDelta zero = BalanceDelta.wrap(0);
        vm.startPrank(address(manager));
        vm.expectRevert(DaemonHook.HookNotImplemented.selector);
        hook.afterInitialize(address(factory), key, SQRT_PRICE_1_1, 0);
        vm.expectRevert(DaemonHook.HookNotImplemented.selector);
        hook.beforeAddLiquidity(address(this), key, lp, "");
        vm.expectRevert(DaemonHook.HookNotImplemented.selector);
        hook.afterAddLiquidity(address(this), key, lp, zero, zero, "");
        vm.expectRevert(DaemonHook.HookNotImplemented.selector);
        hook.beforeRemoveLiquidity(address(this), key, lp, "");
        vm.expectRevert(DaemonHook.HookNotImplemented.selector);
        hook.afterRemoveLiquidity(address(this), key, lp, zero, zero, "");
        vm.expectRevert(DaemonHook.HookNotImplemented.selector);
        hook.beforeDonate(address(this), key, 1, 1, "");
        vm.expectRevert(DaemonHook.HookNotImplemented.selector);
        hook.afterDonate(address(this), key, 1, 1, "");
        vm.stopPrank();
    }

    /// @dev No proxy and no self-destruct in reachable runtime code, and under the EIP-170 limit.
    function test_runtimeCodeHasNoEscapeHatch() public view {
        bytes memory code = address(hook).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        bool reachable = true;
        for (uint256 i = 0; i < code.length; i++) {
            uint8 op = uint8(code[i]);
            if (op == 0x5B) reachable = true;
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            if (reachable) {
                assertTrue(op != 0xF4, "DELEGATECALL");
                assertTrue(op != 0xF2, "CALLCODE");
                assertTrue(op != 0xFF, "SELFDESTRUCT");
            }
            if (op == 0x00 || op == 0x56 || op == 0xF3 || op == 0xFD || op == 0xFE || op == 0xFF) reachable = false;
        }
    }

    function test_hookCannotReceiveEth() public {
        (bool ok,) = address(hook).call{value: 1 wei}("");
        assertFalse(ok, "the hook has no receive function and holds no funds");
        assertEq(address(hook).balance, 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    function _creationCode(address factory_, address token_, address owner_) internal view returns (bytes memory) {
        return abi.encodePacked(type(DaemonHook).creationCode, abi.encode(manager, factory_, token_, owner_));
    }

    function _deployHook(address factory_, address token_, address owner_) internal returns (address) {
        bytes memory code = _creationCode(factory_, token_, owner_);
        (address predicted, bytes32 salt) = HookMiner.find(address(factory), FLAGS, code);
        address deployed = factory.deploy(code, salt);
        assertEq(deployed, predicted);
        return deployed;
    }

    /// @dev Opens the launch pool from the factory and seeds the same full-range liquidity on it and
    /// on the hookless twin.
    function _openLaunchPool(uint160 sqrtPriceX96) internal {
        factory.initialize(key, sqrtPriceX96);
        factory.modify(key, lower, upper, int256(uint256(SEED_LIQUIDITY)));
        manager.initialize(plainKey, sqrtPriceX96);
        lpRouter.modifyLiquidity{value: 1e24}(
            plainKey, ModifyLiquidityParams(lower, upper, int256(uint256(SEED_LIQUIDITY)), 0), ""
        );
    }

    function _swap(PoolKey memory k, bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        uint256 value = 0;
        if (zeroForOne) value = amountSpecified < 0 ? uint256(-amountSpecified) : 1e24;
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        return swapRouter.swap{value: value}(
            k, SwapParams(zeroForOne, amountSpecified, limit), PoolSwapTest.TestSettings(false, false), ""
        );
    }

    function _assertHookHoldsNothing() internal view {
        assertEq(address(hook).balance, 0, "hook holds ETH");
        assertEq(token.balanceOf(address(hook)), 0, "hook holds DAEMON");
        assertEq(manager.balanceOf(address(hook), 0), 0, "hook holds an ETH claim");
        assertEq(manager.balanceOf(address(hook), uint256(uint160(address(token)))), 0, "hook holds a DAEMON claim");
    }

    /// @dev The ERC-7751 wrapper the PoolManager puts around a hook's revert.
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
