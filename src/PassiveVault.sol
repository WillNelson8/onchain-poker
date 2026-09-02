// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IYieldStrategy} from "./IYieldStrategy.sol";

/// @notice Holds assets and earns nothing. The baseline strategy — swap it
/// for an Aave or Morpho adapter and the table never notices.
contract PassiveVault is IYieldStrategy {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;

    constructor(IERC20 token_) {
        token = token_;
    }

    function asset() external view returns (address) {
        return address(token);
    }

    function deposit(uint256 amount) external {
        token.safeTransferFrom(msg.sender, address(this), amount);
    }

    function withdraw(uint256 amount) external {
        token.safeTransfer(msg.sender, amount);
    }

    function totalAssets() external view returns (uint256) {
        return token.balanceOf(address(this));
    }
}
