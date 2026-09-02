// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Anything that can hand the table a shuffled deck.
/// @dev Deliberately async-shaped: request now, cards later. A synchronous
/// interface here would hide the one property that actually matters.
interface IDeckSource {
    function requestShuffle() external returns (uint256 requestId);
    function isReady(uint256 requestId) external view returns (bool);
    function cardAt(uint256 index) external view returns (uint8);
}
