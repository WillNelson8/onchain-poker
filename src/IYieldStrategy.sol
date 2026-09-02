// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Somewhere the table can park chips that isn't the table.
/// @dev Deliberately dumb. It does not know about players, pots, hands or
/// prizes — it takes assets, returns assets, and reports a total. Anything
/// smarter belongs on the table's side of this boundary.
interface IYieldStrategy {
    function asset() external view returns (address);

    /// @dev Pulls `amount` from msg.sender. Caller must approve first.
    function deposit(uint256 amount) external;

    /// @dev Returns `amount` to msg.sender.
    function withdraw(uint256 amount) external;

    /// @dev What this strategy currently holds, valued in the asset.
    /// The table trusts this number completely.
    function totalAssets() external view returns (uint256);
}
