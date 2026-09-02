// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IYieldStrategy
/// @notice Phase 6. Not wired into Table yet — this file exists so the
/// shape is settled before there's a working game to refactor around.
///
/// Accounting rule this must never break: stacks are denominated in
/// chips, never in strategy shares. A stack worth N shares drifts in
/// value mid-hand, so a pot is worth something different when it's won
/// than when it was built. Yield accrues as a separate pool on top.
///
/// The invariant becomes:
///   idleBalance + strategy.totalAssets() >= totalAccounted()
/// and harvest() may only ever skim the surplus above that line.
interface IYieldStrategy {
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function totalAssets() external view returns (uint256);
    function harvest() external returns (uint256 surplus);
}
