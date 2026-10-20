// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";

/// @notice Mines a CREATE2 salt that lands a hook on an address whose low 14 bits equal `flags`.
/// @dev Test-only. The launch deployer does the same for the real deployment.
library HookMiner {
    uint256 internal constant MAX_LOOP = 300_000;

    function find(address deployer, uint160 flags, bytes memory creationCode)
        internal
        pure
        returns (address hookAddress, bytes32 salt)
    {
        bytes32 initCodeHash = keccak256(creationCode);
        uint160 want = flags & Hooks.ALL_HOOK_MASK;
        for (uint256 i = 0; i < MAX_LOOP; i++) {
            hookAddress = computeAddress(deployer, bytes32(i), initCodeHash);
            if (uint160(hookAddress) & Hooks.ALL_HOOK_MASK == want) return (hookAddress, bytes32(i));
        }
        revert("HookMiner: no salt found");
    }

    function computeAddress(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }
}
