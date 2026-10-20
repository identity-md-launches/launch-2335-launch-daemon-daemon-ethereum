// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";
import {DaemonHook} from "../../src/DaemonHook.sol";
import {DaemonToken} from "../../src/DaemonToken.sol";
import {HookMiner} from "../utils/HookMiner.sol";
import {LaunchFactoryMock} from "../utils/LaunchFactoryMock.sol";

/// @notice Drives the live DAEMON/ETH launch pool and a hookless twin with identical random
/// sequences of swaps, liquidity changes, donations and factory collects, and throws unauthorized
/// calls at the hook in between. Every outcome difference between the two pools, and every
/// unauthorized call that succeeds, is recorded in a ghost counter the invariants hold at zero.
contract DaemonHookHandler is Test {
    using PoolIdLibrary for PoolKey;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    PoolManager public immutable manager;
    DaemonToken public immutable token;
    LaunchFactoryMock public immutable factory;
    DaemonHook public immutable hook;
    PoolSwapTest public immutable swapRouter;
    PoolModifyLiquidityTest public immutable lpRouter;
    PoolDonateTest public immutable donateRouter;
    address public immutable owner;

    PoolKey public key;
    PoolKey public plainKey;
    int24 public immutable lower;
    int24 public immutable upper;

    // Ranges the handler may add liquidity to, and what it holds in each (same on both pools).
    int24[2][4] internal ranges;
    mapping(uint256 => uint128) public liquidityIn;

    // Ghosts: each must stay zero.
    uint256 public ghostTradeMismatches;
    uint256 public ghostLiquidityMismatches;
    uint256 public ghostCollectFailures;
    uint256 public ghostUnauthorizedSuccesses;
    uint256 public ghostOwnerPowerSuccesses;

    // Ghosts that prove the run did something.
    uint256 public ghostSwaps;
    uint256 public ghostCollects;
    uint256 public ghostFactoryFeesCollected0;

    address[4] internal strangers = [address(0xBAD1), address(0xBAD2), address(0xBAD3), address(0)];

    constructor(
        PoolManager manager_,
        DaemonToken token_,
        LaunchFactoryMock factory_,
        DaemonHook hook_,
        PoolKey memory key_,
        PoolKey memory plainKey_,
        address owner_
    ) {
        manager = manager_;
        token = token_;
        factory = factory_;
        hook = hook_;
        key = key_;
        plainKey = plainKey_;
        owner = owner_;
        swapRouter = new PoolSwapTest(manager_);
        lpRouter = new PoolModifyLiquidityTest(manager_);
        donateRouter = new PoolDonateTest(manager_);
        lower = TickMath.minUsableTick(60);
        upper = TickMath.maxUsableTick(60);
        ranges[0] = [lower, upper];
        ranges[1] = [int24(-600), int24(600)];
        ranges[2] = [int24(-6000), int24(-60)];
        ranges[3] = [int24(60), int24(12000)];
        strangers[3] = owner_;
    }

    receive() external payable {}

    function approveRouters() external {
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(lpRouter), type(uint256).max);
        token.approve(address(donateRouter), type(uint256).max);
    }

    // ---------------------------------------------------------------------------------------------
    // Pool actions, mirrored on both pools
    // ---------------------------------------------------------------------------------------------

    function swap(bool zeroForOne, uint256 amount, bool exactInput) external {
        amount = bound(amount, 1, 20 ether);
        int256 specified = exactInput ? -int256(amount) : int256(amount);
        (bool okH, BalanceDelta dH) = _trySwap(key, zeroForOne, specified);
        (bool okP, BalanceDelta dP) = _trySwap(plainKey, zeroForOne, specified);
        if (okH != okP || BalanceDelta.unwrap(dH) != BalanceDelta.unwrap(dP)) ghostTradeMismatches++;
        if (okH) ghostSwaps++;
    }

    function addLiquidity(uint256 rangeSeed, uint256 liquidity) external {
        uint256 r = rangeSeed % 4;
        liquidity = bound(liquidity, 1e6, 1e20);
        (bool okH, BalanceDelta dH) = _tryModify(key, r, int256(liquidity));
        (bool okP, BalanceDelta dP) = _tryModify(plainKey, r, int256(liquidity));
        if (okH != okP || BalanceDelta.unwrap(dH) != BalanceDelta.unwrap(dP)) ghostLiquidityMismatches++;
        if (okH && okP) liquidityIn[r] += uint128(liquidity);
    }

    function removeLiquidity(uint256 rangeSeed, uint256 liquidity) external {
        uint256 r = rangeSeed % 4;
        if (liquidityIn[r] == 0) return;
        liquidity = bound(liquidity, 1, liquidityIn[r]);
        (bool okH, BalanceDelta dH) = _tryModify(key, r, -int256(liquidity));
        (bool okP, BalanceDelta dP) = _tryModify(plainKey, r, -int256(liquidity));
        // The test router refuses a removal worth zero of both currencies; it does so on both pools.
        // What must hold is that the hook never makes the launch pool behave differently.
        if (okH != okP || BalanceDelta.unwrap(dH) != BalanceDelta.unwrap(dP)) ghostLiquidityMismatches++;
        if (okH && okP) liquidityIn[r] -= uint128(liquidity);
    }

    function donate(uint256 amount0, uint256 amount1) external {
        amount0 = bound(amount0, 0, 1 ether);
        amount1 = bound(amount1, 0, 1 ether);
        bool okH = _tryDonate(key, amount0, amount1);
        bool okP = _tryDonate(plainKey, amount0, amount1);
        if (okH != okP) ghostTradeMismatches++;
    }

    /// @dev The factory's fee collect: a zero liquidity change on its seeded position. Must always pass.
    function factoryCollect() external {
        uint256 before = address(factory).balance;
        try factory.modify(key, lower, upper, 0) returns (int128 fee0, int128) {
            ghostCollects++;
            ghostFactoryFeesCollected0 += uint256(uint128(fee0));
            if (address(factory).balance - before != uint256(uint128(fee0))) ghostCollectFailures++;
        } catch {
            ghostCollectFailures++;
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Unauthorized actions: none may succeed
    // ---------------------------------------------------------------------------------------------

    /// @dev Calls a declared callback directly from a non-manager address with a random sender field.
    function callCallbackDirectly(uint256 actorSeed, uint256 which, address senderField, bool zeroForOne) external {
        address actor = strangers[actorSeed % strangers.length];
        SwapParams memory params =
            SwapParams(zeroForOne, -1 ether, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
        bytes memory data;
        which = which % 3;
        if (which == 0) data = abi.encodeCall(IHooks.beforeInitialize, (senderField, key, SQRT_PRICE_1_1));
        else if (which == 1) data = abi.encodeCall(IHooks.beforeSwap, (senderField, key, params, ""));
        else data = abi.encodeCall(IHooks.afterSwap, (senderField, key, params, BalanceDelta.wrap(0), ""));
        vm.prank(actor);
        (bool ok,) = address(hook).call(data);
        if (ok) ghostUnauthorizedSuccesses++;
    }

    /// @dev A stranger (or the owner) tries to open another pool on this hook through the manager.
    function strangerInitialize(uint256 actorSeed, uint24 fee, int24 tickSpacing, uint256 priceSeed) external {
        address actor = strangers[actorSeed % strangers.length];
        PoolKey memory k = key;
        k.fee = uint24(bound(fee, 0, 1_000_000));
        k.tickSpacing = int24(int256(bound(int256(tickSpacing), 1, 32767)));
        uint160 price = uint160(bound(priceSeed, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));
        vm.prank(actor);
        try manager.initialize(k, price) {
            ghostUnauthorizedSuccesses++;
        } catch {}
    }

    /// @dev Even the factory cannot attach a second pool once the launch pool is open.
    function factoryInitializesAgain(uint24 fee, int24 tickSpacing, uint256 priceSeed) external {
        PoolKey memory k = key;
        k.fee = uint24(bound(fee, 0, 1_000_000));
        k.tickSpacing = int24(int256(bound(int256(tickSpacing), 1, 32767)));
        uint160 price = uint160(bound(priceSeed, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));
        try factory.initialize(k, price) {
            ghostUnauthorizedSuccesses++;
        } catch {}
    }

    /// @dev The owner tries common fee/pause/claim selectors with random arguments.
    function ownerTriesToEnableAFee(uint256 sigSeed, uint256 arg) external {
        string[8] memory sigs = [
            "setFee(uint24)",
            "setHookFee(uint256)",
            "setFeeRecipient(address)",
            "setPaused(bool)",
            "claimFees(address)",
            "withdraw(address,uint256)",
            "setTreasury(address)",
            "updateDynamicLPFee(uint24)"
        ];
        bytes memory data = abi.encodeWithSignature(sigs[sigSeed % sigs.length], arg, arg);
        vm.prank(hook.owner());
        (bool ok,) = address(hook).call(data);
        if (ok) ghostOwnerPowerSuccesses++;
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _trySwap(PoolKey memory k, bool zeroForOne, int256 specified) internal returns (bool, BalanceDelta) {
        uint256 value = zeroForOne ? (specified < 0 ? uint256(-specified) : 1_000 ether) : 0;
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        try swapRouter.swap{value: value}(
            k, SwapParams(zeroForOne, specified, limit), PoolSwapTest.TestSettings(false, false), ""
        ) returns (
            BalanceDelta d
        ) {
            return (true, d);
        } catch {
            return (false, BalanceDelta.wrap(0));
        }
    }

    function _tryModify(PoolKey memory k, uint256 r, int256 liquidity) internal returns (bool, BalanceDelta) {
        uint256 value = liquidity > 0 ? 1_000 ether : 0;
        try lpRouter.modifyLiquidity{value: value}(
            k, ModifyLiquidityParams(ranges[r][0], ranges[r][1], liquidity, bytes32(uint256(7))), ""
        ) returns (
            BalanceDelta d
        ) {
            return (true, d);
        } catch {
            return (false, BalanceDelta.wrap(0));
        }
    }

    function _tryDonate(PoolKey memory k, uint256 amount0, uint256 amount1) internal returns (bool) {
        try donateRouter.donate{value: amount0}(k, amount0, amount1, "") {
            return true;
        } catch {
            return false;
        }
    }
}

contract DaemonHookInvariantTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG;
    uint24 constant LP_FEE = 12_500;
    uint128 constant SEED_LIQUIDITY = 1e21;
    address constant OWNER = address(0x0A11E5);

    PoolManager manager;
    DaemonToken token;
    LaunchFactoryMock factory;
    DaemonHook hook;
    DaemonHookHandler handler;
    PoolKey key;
    PoolKey plainKey;
    PoolId launchId;

    function setUp() public {
        manager = new PoolManager(address(this));
        token = new DaemonToken();
        factory = new LaunchFactoryMock(manager);

        bytes memory code = abi.encodePacked(
            type(DaemonHook).creationCode, abi.encode(manager, address(factory), address(token), OWNER)
        );
        (, bytes32 salt) = HookMiner.find(address(factory), FLAGS, code);
        hook = DaemonHook(factory.deploy(code, salt));

        key = PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(token)), LP_FEE, 60, IHooks(address(hook)));
        plainKey = key;
        plainKey.hooks = IHooks(address(0));
        launchId = key.toId();

        handler = new DaemonHookHandler(manager, token, factory, hook, key, plainKey, OWNER);

        int24 lower = TickMath.minUsableTick(60);
        int24 upper = TickMath.maxUsableTick(60);

        // Launch pool: opened and seeded by the factory. Twin: same price and liquidity, no hook.
        vm.deal(address(factory), 1e24);
        token.transfer(address(factory), 1e26);
        factory.initialize(key, SQRT_PRICE_1_1);
        factory.modify(key, lower, upper, int256(uint256(SEED_LIQUIDITY)));

        PoolModifyLiquidityTest seeder = new PoolModifyLiquidityTest(manager);
        token.approve(address(seeder), type(uint256).max);
        vm.deal(address(this), 1e24);
        manager.initialize(plainKey, SQRT_PRICE_1_1);
        seeder.modifyLiquidity{value: 1e24}(
            plainKey, ModifyLiquidityParams(lower, upper, int256(uint256(SEED_LIQUIDITY)), 0), ""
        );

        // Fund the handler generously in both currencies.
        vm.deal(address(handler), 1e30);
        token.transfer(address(handler), token.balanceOf(address(this)));
        handler.approveRouters();

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = DaemonHookHandler.swap.selector;
        selectors[1] = DaemonHookHandler.addLiquidity.selector;
        selectors[2] = DaemonHookHandler.removeLiquidity.selector;
        selectors[3] = DaemonHookHandler.donate.selector;
        selectors[4] = DaemonHookHandler.factoryCollect.selector;
        selectors[5] = DaemonHookHandler.callCallbackDirectly.selector;
        selectors[6] = DaemonHookHandler.strangerInitialize.selector;
        selectors[7] = DaemonHookHandler.factoryInitializesAgain.selector;
        selectors[8] = DaemonHookHandler.ownerTriesToEnableAFee.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    receive() external payable {}

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_hookNeverHoldsValue() public view {
        assertEq(address(hook).balance, 0, "hook holds ETH");
        assertEq(token.balanceOf(address(hook)), 0, "hook holds DAEMON");
        assertEq(manager.balanceOf(address(hook), 0), 0, "hook holds an ETH claim");
        assertEq(manager.balanceOf(address(hook), uint256(uint160(address(token)))), 0, "hook holds a DAEMON claim");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_launchPoolTracksTheHooklessTwinExactly() public view {
        assertEq(handler.ghostTradeMismatches(), 0, "a swap or donation differed from the hookless pool");
        assertEq(handler.ghostLiquidityMismatches(), 0, "a liquidity change differed from the hookless pool");
        (uint160 pH, int24 tH, uint24 protoH, uint24 feeH) = IPoolManager(address(manager)).getSlot0(launchId);
        (uint160 pP, int24 tP,,) = IPoolManager(address(manager)).getSlot0(plainKey.toId());
        assertEq(pH, pP, "price diverged from the hookless pool");
        assertEq(tH, tP, "tick diverged from the hookless pool");
        assertEq(feeH, LP_FEE, "the LP fee is not the standard 1.25%");
        assertEq(protoH, 0, "protocol fee appeared");
        assertEq(
            IPoolManager(address(manager)).getLiquidity(launchId) - SEED_LIQUIDITY,
            IPoolManager(address(manager)).getLiquidity(plainKey.toId()) - SEED_LIQUIDITY,
            "active liquidity diverged"
        );
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_factoryCollectAlwaysPasses() public view {
        assertEq(handler.ghostCollectFailures(), 0, "the factory's fee collect failed or was short-paid");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_noUnauthorizedCallEverSucceeds() public view {
        assertEq(handler.ghostUnauthorizedSuccesses(), 0, "an unauthorized callback or initialization succeeded");
        assertEq(handler.ghostOwnerPowerSuccesses(), 0, "the owner reached a fee or pause entry point");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_theOnePoolNeverChanges() public view {
        assertTrue(hook.initialized(), "the launch pool record was cleared");
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(launchId), "the hook's pool changed");
        assertEq(hook.owner(), OWNER, "ownership moved without the owner");
        assertEq(token.totalSupply(), 1_000_000_000 ether, "DAEMON supply changed");
    }
}
