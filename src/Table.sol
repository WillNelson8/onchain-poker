// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Table
/// @notice Seats and stacks. Phase 1: no cards, no betting, no yield.
contract Table {
    using SafeERC20 for IERC20;

    uint256 public constant SEAT_COUNT = 2;

    // immutable = set once in the constructor, then baked into the
    // bytecode. Cheaper to read than storage, and can never change.
    IERC20 public immutable chip;
    uint256 public immutable buyInAmount;

    address[SEAT_COUNT] public seats;
    mapping(address => uint256) public stack;
    uint256 public pot;

    // Custom errors cost far less gas than require("string") and
    // give callers something machine-readable to catch.
    error TableFull();
    error AlreadySeated();
    error NotSeated();

    event SatDown(address indexed player, uint256 seat, uint256 amount);
    event StoodUp(address indexed player, uint256 seat, uint256 amount);

    constructor(IERC20 chip_, uint256 buyInAmount_) {
        chip = chip_;
        buyInAmount = buyInAmount_;
    }

    function seatOf(address player) public view returns (uint256 seat, bool seated) {
        for (uint256 i; i < SEAT_COUNT; ++i) {
            if (seats[i] == player) return (i, true);
        }
        return (0, false);
    }

    function buyIn() external {
        (, bool seated) = seatOf(msg.sender);
        if (seated) revert AlreadySeated();

        uint256 seat = SEAT_COUNT;
        for (uint256 i; i < SEAT_COUNT; ++i) {
            if (seats[i] == address(0)) {
                seat = i;
                break;
            }
        }
        if (seat == SEAT_COUNT) revert TableFull();

        // Checks, then Effects, then Interactions. State is fully
        // updated BEFORE any external call. Do this every single time.
        seats[seat] = msg.sender;
        stack[msg.sender] = buyInAmount;

        chip.safeTransferFrom(msg.sender, address(this), buyInAmount);
        emit SatDown(msg.sender, seat, buyInAmount);
    }

    /// @dev TODO Phase 3: gate this on `phase == Phase.Idle`.
    /// Once hands exist, an unguarded cashOut is the most obvious
    /// exploit in the game — a losing player stands up and walks off
    /// with chips already committed to the pot.
    function cashOut() external {
        (uint256 seat, bool seated) = seatOf(msg.sender);
        if (!seated) revert NotSeated();

        uint256 amount = stack[msg.sender];
        stack[msg.sender] = 0;
        seats[seat] = address(0);

        chip.safeTransfer(msg.sender, amount);
        emit StoodUp(msg.sender, seat, amount);
    }

    /// @notice Every chip the contract believes it owes.
    /// @dev The whole project hangs off this equalling the real balance.
    function totalAccounted() public view returns (uint256 total) {
        for (uint256 i; i < SEAT_COUNT; ++i) {
            total += stack[seats[i]];
        }
        total += pot;
    }
}
