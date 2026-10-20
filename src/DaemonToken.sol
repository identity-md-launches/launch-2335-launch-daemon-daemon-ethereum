// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title DAEMON launch token
/// @notice Standard fixed-supply ERC-20: 1,000,000,000 DAEMON at 18 decimals, minted once to the
/// deployer (the IMD launch factory) and never again.
/// @dev Deliberately minimal. There is no owner, no mint, no burn-from, no pause, no blocklist, no
/// transfer tax and no upgrade path. Every transfer moves exactly what it was asked to move. The
/// launch factory checks that the deployer holds the whole supply right after construction and
/// refuses the launch otherwise, so the constructor takes no arguments and mints to `msg.sender`.
contract DaemonToken is ERC20 {
    /// @notice Whole supply in minor units: 1e9 tokens * 1e18.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;

    constructor() ERC20("DAEMON", "DAEMON") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
