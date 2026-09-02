// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2 as console} from "forge-std/Test.sol";
import {Table} from "../src/Table.sol";
import {MockChip} from "./mocks/MockChip.sol";
import {MockDeck} from "./mocks/MockDeck.sol";

contract DemoTest is Test {
    Table table;
    MockChip chip;
    MockDeck deck;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant BUY_IN = 100e18;
    uint256 constant ANTE = 2e18;
    uint256 constant BET = 5e18;

    function setUp() public {
        chip = new MockChip();
        deck = new MockDeck();
        table = new Table(chip, deck, BUY_IN, ANTE, BET);

        address[2] memory players = [alice, bob];
        for (uint256 i; i < 2; ++i) {
            chip.mint(players[i], 500e18);
            vm.prank(players[i]);
            chip.approve(address(table), type(uint256).max);
            vm.prank(players[i]);
            table.buyIn();
        }
    }

    function test_Demo() public {
        console.log("=== onchain-poker | phase 3 ===");
        show("Both seated");

        table.startHand();
        show("Antes posted, deck requested");

        deck.setCards(12, 0); // ace of clubs vs deuce of clubs
        deck.fulfil();
        table.deal();
        console.log("");
        console.log("Dealt: alice = A of clubs, bob = 2 of clubs");

        vm.prank(alice);
        table.act(Table.Action.Bet);
        show("Alice bets");

        vm.prank(bob);
        table.act(Table.Action.Call);
        show("Bob calls -- showdown, ace wins");
    }
}
