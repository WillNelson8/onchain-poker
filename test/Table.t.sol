// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Table} from "../src/Table.sol";
import {MockChip} from "./mocks/MockChip.sol";
import {MockDeck} from "./mocks/MockDeck.sol";

contract TableTest is Test {
    Table table;
    MockChip chip;
    MockDeck deck;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant BUY_IN = 100e18;
    uint256 constant ANTE = 2e18;
    uint256 constant BET = 5e18;

    // 2 of clubs = 0, ace of clubs = 12, 2 of diamonds = 13
    uint8 constant TWO_CLUBS = 0;
    uint8 constant ACE_CLUBS = 12;
    uint8 constant TWO_DIAMONDS = 13;

    function setUp() public {
        chip = new MockChip();
        deck = new MockDeck();
        table = new Table(chip, deck, BUY_IN, ANTE, BET);

        address[2] memory players = [alice, bob];
        for (uint256 i; i < 2; ++i) {
            chip.mint(players[i], 1_000e18);
            vm.prank(players[i]);
            chip.approve(address(table), type(uint256).max);
            vm.prank(players[i]);
            table.buyIn();
        }
    }

    // alice is seat 0, bob is seat 1, dealer starts at seat 0.
    function _dealHand(uint8 card0, uint8 card1) internal {
        table.startHand();
        deck.setCards(card0, card1);
        deck.fulfil();
        table.deal();
    }

    function test_AwaitingDeck_CannotActYet() public {
        table.startHand();
        vm.prank(alice);
        vm.expectRevert(Table.WrongPhase.selector);
        table.act(Table.Action.Check);
    }

    function test_CheckCheck_HigherCardWins() public {
        _dealHand(ACE_CLUBS, TWO_CLUBS); // alice ace, bob deuce

        vm.prank(alice);
        table.act(Table.Action.Check);
        vm.prank(bob);
        table.act(Table.Action.Check);

        // Both anted 2, alice takes the 4 back plus bob's 2.
        assertEq(table.stack(alice), BUY_IN + ANTE);
        assertEq(table.stack(bob), BUY_IN - ANTE);
        assertEq(uint256(table.phase()), 0, "back to Idle");
    }

    function test_BetFold_BettorTakesPot() public {
        _dealHand(TWO_CLUBS, ACE_CLUBS); // bob has the better card

        vm.prank(alice);
        table.act(Table.Action.Bet);
        vm.prank(bob);
        table.act(Table.Action.Fold); // folds the winner

        assertEq(table.stack(alice), BUY_IN + ANTE);
        assertEq(table.stack(bob), BUY_IN - ANTE);
    }

    function test_BetRaiseCall_RoundEndsOnlyAfterTheCall() public {
        _dealHand(ACE_CLUBS, TWO_CLUBS);

        vm.prank(alice);
        table.act(Table.Action.Bet);
        vm.prank(bob);
        table.act(Table.Action.Bet); // a raise

        // Both have acted, but bets are unequal — still live.
        assertEq(uint256(table.phase()), 2, "still Betting");

        vm.prank(alice);
        table.act(Table.Action.Call);

        assertEq(uint256(table.phase()), 0, "hand over");
        assertEq(table.stack(alice), BUY_IN + ANTE + BET * 2);
    }

    function test_Tie_SplitsPot() public {
        _dealHand(TWO_CLUBS, TWO_DIAMONDS); // same rank, different suit

        vm.prank(alice);
        table.act(Table.Action.Check);
        vm.prank(bob);
        table.act(Table.Action.Check);

        assertEq(table.stack(alice), BUY_IN);
        assertEq(table.stack(bob), BUY_IN);
    }

    function test_CannotCashOutMidHand() public {
        _dealHand(ACE_CLUBS, TWO_CLUBS);
        vm.prank(bob);
        vm.expectRevert(Table.WrongPhase.selector);
        table.cashOut();
    }

    function test_NotYourTurn() public {
        _dealHand(ACE_CLUBS, TWO_CLUBS);
        vm.prank(bob); // dealer seat 0 acts first
        vm.expectRevert(Table.NotYourTurn.selector);
        table.act(Table.Action.Check);
    }
}

function testFuzz_SolventThroughRandomHands(uint256 entropy) public {
    for (uint256 hand; hand < 6; ++hand) {
        uint256 roll = uint256(keccak256(abi.encode(entropy, hand)));

        try table.startHand() {}
        catch {
            break;
        }
        deck.setCards(uint8(roll % 52), uint8((roll >> 8) % 52));
        deck.fulfil();
        table.deal();

        // Up to 8 random actions; invalid ones just revert.
        for (uint256 step; step < 8; ++step) {
            uint256 pick = uint256(keccak256(abi.encode(roll, step)));
            address who = (pick % 2 == 0) ? alice : bob;

            vm.prank(who);
            try table.act(Table.Action(uint8(pick >> 8) % 4)) {} catch {}

            assertEq(chip.balanceOf(address(table)), table.totalAccounted(), "books do not balance");
        }
    }

    assertEq(chip.balanceOf(address(table)), table.totalAccounted());
}
