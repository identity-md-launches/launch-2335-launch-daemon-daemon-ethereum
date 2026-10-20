// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

/// @notice Stands in for the IMD launch factory in tests: deploys the hook with CREATE2, opens the
/// pool, holds the seeded position and collects its fees with a zero liquidity change.
contract LaunchFactoryMock is IUnlockCallback {
    error HookTookFees(int128 amount0, int128 amount1);

    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    /// @dev Returns address(0) when the constructor reverts, so a test can assert on a refused deployment.
    function tryDeploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
    }

    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0), "LaunchFactoryMock: hook deployment reverted");
    }

    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24) {
        return manager.initialize(key, sqrtPriceX96);
    }

    /// @notice Adds `liquidity` (positive), removes it (negative) or collects fees (zero) on the factory's position.
    function modify(PoolKey memory key, int24 tickLower, int24 tickUpper, int256 liquidity)
        external
        returns (int128 amount0, int128 amount1)
    {
        (amount0, amount1) =
            abi.decode(manager.unlock(abi.encode(key, tickLower, tickUpper, liquidity)), (int128, int128));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "LaunchFactoryMock: not manager");
        (PoolKey memory key, int24 tickLower, int24 tickUpper, int256 liquidity) =
            abi.decode(data, (PoolKey, int24, int24, int256));
        (BalanceDelta delta,) = manager.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidity, salt: 0}),
            ""
        );
        int128 a0 = delta.amount0();
        int128 a1 = delta.amount1();
        // A collect that would have the position pay is what the real factory's PoolFees refuses.
        if (liquidity == 0 && (a0 < 0 || a1 < 0)) revert HookTookFees(a0, a1);
        _settle(key.currency0, a0);
        _settle(key.currency1, a1);
        return abi.encode(a0, a1);
    }

    function _settle(Currency currency, int128 amount) private {
        if (amount < 0) {
            uint256 owed = uint256(uint128(-amount));
            if (currency.isAddressZero()) {
                manager.settle{value: owed}();
            } else {
                manager.sync(currency);
                require(IERC20(Currency.unwrap(currency)).transfer(address(manager), owed), "transfer failed");
                manager.settle();
            }
        } else if (amount > 0) {
            manager.take(currency, address(this), uint256(uint128(amount)));
        }
    }

    receive() external payable {}
}
