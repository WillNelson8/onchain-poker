// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Table} from "../src/Table.sol";
import {MockChip} from "./mocks/MockChip.sol";
import {MockDeck} from "./mocks/MockDeck.sol";
import {PassiveVault} from "../src/PassiveVault.sol";

contract TableTest is Test {
    Table table;
    MockChip chip;
    MockDeck deck;
    PassiveVault vault;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant BUY_IN = 100e18;
    uint256 constant ANTE = 2e18;
    uint256 constant BET = 5e18;

    // Nine cards: [0,1] alice hole, [2,3] bob hole, [4..8] board.
    // alice Ac Ad | bob 7c 7d | board Ah 2s 9c Kd 4h
    // alice makes trip aces, bob a pair of sevens.
    function _tripsVsPair() internal pure returns (uint8[9] memory n) {
        n = [uint8(12), 25, 5, 18, 38, 39, 7, 24, 28];
    }

    // alice 2c 3c | bob 2d 3d | board Ac Kd Qh Js Tc
    // Both play the board for a broadway straight. Dead tie.
    function _tie() internal pure returns (uint8[9] memory n) {
        n = [uint8(0), 1, 13, 14, 12, 24, 36, 48, 8];
    }

    // alice Ac Ad | bob 7h 3h | board Ah 9h 2h Kd 4c
    // alice has trip aces, bob backs into a flush and wins.
    function _flushBeatsTrips() internal pure returns (uint8[9] memory n) {
        n = [uint8(12), 25, 31, 27, 38, 33, 26, 24, 2];
    }

    function setUp() public {
        chip = new MockChip();
        deck = new MockDeck();
        vault = new PassiveVault(chip);
        table = new Table(chip, deck, vault, BUY_IN, ANTE, BET);

        address[2] memory players = [alice, bob];
        for (uint256 i; i < 2; ++i) {
            chip.mint(players[i], 1_000e18);
            vm.prank(players[i]);
            chip.approve(address(table), type(uint256).max);
            vm.prank(players[i]);
            table.buyIn();
        }
    }

    function _dealHand(uint8[9] memory nine) internal {
        table.startHand();
        deck.setHand(nine);
        deck.fulfil();
        table.deal();
    }

    /// Whoever is to act checks, then whoever is to act next checks.
    /// Works on any street without knowing who the button is.
    function _bothCheck() internal {
        vm.prank(table.seats(table.actor()));
        table.act(Table.Action.Check);
        vm.prank(table.seats(table.actor()));
        table.act(Table.Action.Check);
    }

    function _checkToShowdown() internal {
        _bothCheck(); // preflop
        _bothCheck(); // flop
        _bothCheck(); // turn
        _bothCheck(); // river
    }

    // ---------------------------------------------------------------
    // Hand lifecycle
    // ---------------------------------------------------------------

    function test_AwaitingDeck_CannotActYet() public {
        table.startHand();
        vm.prank(alice);
        vm.expectRevert(Table.WrongPhase.selector);
        table.act(Table.Action.Check);
    }

    function test_FourStreets_TripsBeatsPair() public {
        _dealHand(_tripsVsPair());

        assertEq(table.street(), 0, "preflop");
        _bothCheck();
        assertEq(table.street(), 1, "flop");
        _bothCheck();
        assertEq(table.street(), 2, "turn");
        _bothCheck();
        assertEq(table.street(), 3, "river");
        _bothCheck();

        assertEq(uint256(table.phase()), 0, "hand over");
        assertEq(table.stack(alice), BUY_IN + ANTE, "trip aces wins");
        assertEq(table.stack(bob), BUY_IN - ANTE);
        assertEq(chip.balanceOf(address(table)), table.totalAccounted());
    }

    function test_Flush_BeatsTrips() public {
        _dealHand(_flushBeatsTrips());
        _checkToShowdown();

        assertEq(table.stack(bob), BUY_IN + ANTE, "flush wins");
        assertEq(table.stack(alice), BUY_IN - ANTE);
    }

    function test_Tie_SplitsPot() public {
        _dealHand(_tie());
        _checkToShowdown();

        assertEq(table.stack(alice), BUY_IN);
        assertEq(table.stack(bob), BUY_IN);
    }

    // ---------------------------------------------------------------
    // Betting
    // ---------------------------------------------------------------

    function test_BetRaiseCall_AdvancesStreetOnlyAfterTheCall() public {
        _dealHand(_tripsVsPair());

        vm.prank(alice);
        table.act(Table.Action.Bet);
        vm.prank(bob);
        table.act(Table.Action.Bet); // a raise

        // Both have acted, but the bets are unequal. Still preflop.
        assertEq(table.street(), 0, "still preflop");

        vm.prank(alice);
        table.act(Table.Action.Call);

        assertEq(table.street(), 1, "flop");
        assertEq(uint256(table.phase()), 2, "still betting");
    }

    function test_BetFold_BettorTakesPot() public {
        _dealHand(_flushBeatsTrips()); // bob would have won at showdown

        vm.prank(alice);
        table.act(Table.Action.Bet);
        vm.prank(bob);
        table.act(Table.Action.Fold);

        assertEq(table.stack(alice), BUY_IN + ANTE);
        assertEq(table.stack(bob), BUY_IN - ANTE);
        assertEq(uint256(table.phase()), 0);
    }

    function test_NotYourTurn() public {
        _dealHand(_tripsVsPair());
        vm.prank(bob); // button (seat 0) acts first preflop
        vm.expectRevert(Table.NotYourTurn.selector);
        table.act(Table.Action.Check);
    }

    function test_CannotCashOutMidHand() public {
        _dealHand(_tripsVsPair());
        vm.prank(bob);
        vm.expectRevert(Table.WrongPhase.selector);
        table.cashOut();
    }

    // ---------------------------------------------------------------
    // Deadlines
    // ---------------------------------------------------------------

    function test_ForceFold_RevertsBeforeDeadline() public {
        _dealHand(_tripsVsPair());
        vm.expectRevert(Table.DeadlineNotPassed.selector);
        table.forceFold();
    }

    function test_ForceFold_AfterDeadline() public {
        _dealHand(_tripsVsPair()); // alice to act, and she goes quiet

        vm.warp(block.timestamp + 5 minutes + 1);
        table.forceFold(); // no prank: anyone may call

        assertEq(table.stack(bob), BUY_IN + ANTE);
        assertEq(table.stack(alice), BUY_IN - ANTE);
        assertEq(uint256(table.phase()), 0);
    }

    function test_AbortHand_WhenDeckNeverArrives() public {
        table.startHand();

        vm.warp(block.timestamp + 1 hours + 1);
        table.abortHand();

        assertEq(table.stack(alice), BUY_IN, "ante refunded");
        assertEq(table.stack(bob), BUY_IN, "ante refunded");
        assertEq(table.pot(), 0);
        assertEq(uint256(table.phase()), 0);
    }

    function test_AbortHand_RevertsBeforeDeadline() public {
        table.startHand();
        vm.expectRevert(Table.DeadlineNotPassed.selector);
        table.abortHand();
    }

    function test_SilentOpponent_MoneyStillComesOut() public {
        _dealHand(_tripsVsPair());

        vm.prank(alice);
        table.act(Table.Action.Bet);

        // Bob closes his laptop and never returns.
        vm.warp(block.timestamp + 365 days);
        table.forceFold();

        vm.prank(alice);
        table.cashOut();

        assertEq(chip.balanceOf(alice), 1_000e18 + ANTE);
        assertEq(chip.balanceOf(address(table)), table.totalAccounted());
    }

    // ---------------------------------------------------------------
    // The invariant, through whole random hands
    // ---------------------------------------------------------------

    function testFuzz_SolventThroughRandomHands(uint256 entropy) public {
        for (uint256 h; h < 3; ++h) {
            uint256 roll = uint256(keccak256(abi.encode(entropy, h)));

            try table.startHand() {}
            catch {
                break;
            }

            uint8[9] memory nine;
            for (uint256 i; i < 9; ++i) {
                nine[i] = uint8(uint256(keccak256(abi.encode(roll, i))) % 52);
            }
            deck.setHand(nine);
            deck.fulfil();
            table.deal();

            for (uint256 step; step < 14; ++step) {
                uint256 pick = uint256(keccak256(abi.encode(roll, step, uint256(7))));
                address who = (pick % 2 == 0) ? alice : bob;

                vm.prank(who);
                try table.act(Table.Action(uint8(pick >> 8) % 4)) {} catch {}

                assertEq(chip.balanceOf(address(table)), table.totalAccounted(), "books do not balance");
            }
        }

        assertEq(chip.balanceOf(address(table)), table.totalAccounted());
    }
}
