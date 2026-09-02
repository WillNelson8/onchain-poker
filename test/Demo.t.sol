// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2 as console} from "forge-std/Test.sol";
import {Table} from "../src/Table.sol";
import {MockChip} from "./mocks/MockChip.sol";
import {MockDeck} from "./mocks/MockDeck.sol";
import {PassiveVault} from "../src/PassiveVault.sol";

contract DemoTest is Test {
    Table table;
    MockChip chip;
    MockDeck deck;
    PassiveVault vault;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant BUY_IN = 100e18;
    uint256 constant ANTE = 2e18;
    uint256 constant BET = 5e18;

    function setUp() public {
        chip = new MockChip();
        deck = new MockDeck();
        vault = new PassiveVault(chip);
        table = new Table(chip, deck, vault, BUY_IN, ANTE, BET);

        address[2] memory players = [alice, bob];
        for (uint256 i; i < 2; ++i) {
            chip.mint(players[i], 500e18);
            vm.prank(players[i]);
            chip.approve(address(table), type(uint256).max);
            vm.prank(players[i]);
            table.buyIn();
        }
    }

    function _name(uint8 card) internal pure returns (string memory) {
        string[13] memory r = ["2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K", "A"];
        string[4] memory s = ["c", "d", "h", "s"];
        return string.concat(r[card % 13], s[card / 13]);
    }

    function _revealed() internal view returns (uint256) {
        uint8 st = table.street();
        if (st == 0) return 0;
        if (st == 1) return 3;
        if (st == 2) return 4;
        return 5;
    }

    function _boardStr() internal view returns (string memory out) {
        uint256 n = _revealed();
        for (uint256 i; i < n; ++i) {
            out = string.concat(out, _name(table.board(i)), " ");
        }
    }

    function _money(string memory label) internal view {
        console.log(
            string.concat(
                "    ",
                label,
                "  alice ",
                vm.toString(table.stack(alice) / 1e18),
                " | bob ",
                vm.toString(table.stack(bob) / 1e18),
                " | pot ",
                vm.toString(table.pot() / 1e18)
            )
        );
        // The invariant, printed every time so you can watch it hold.
        console.log(
            string.concat(
                "    table holds ",
                vm.toString(chip.balanceOf(address(table)) / 1e18),
                ", owes ",
                vm.toString(table.totalAccounted() / 1e18)
            )
        );
    }

    function _bothCheck() internal {
        vm.prank(table.seats(table.actor()));
        table.act(Table.Action.Check);
        vm.prank(table.seats(table.actor()));
        table.act(Table.Action.Check);
    }

    function test_Demo() public {
        console.log("=== onchain-poker | phase 5 ===");
        console.log("");
        _money("seated ");

        table.startHand();
        console.log("");
        console.log("  antes posted, deck requested");
        _money("preflop");

        // alice Ac Ad | bob 7c 7d | board Ah 2s 9c Kd 4h
        deck.setHand([uint8(12), 25, 5, 18, 38, 39, 7, 24, 28]);
        deck.fulfil();
        table.deal();

        console.log("");
        console.log(
            string.concat(
                "  dealt -- alice ",
                _name(table.hole(0, 0)),
                " ",
                _name(table.hole(0, 1)),
                "   bob ",
                _name(table.hole(1, 0)),
                " ",
                _name(table.hole(1, 1))
            )
        );

        _bothCheck();
        console.log("");
        console.log(string.concat("  flop   ", _boardStr()));
        _money("       ");

        _bothCheck();
        console.log(string.concat("  turn   ", _boardStr()));

        _bothCheck();
        console.log(string.concat("  river  ", _boardStr()));

        _bothCheck();
        console.log("");
        console.log("  showdown -- alice has trip aces, bob a pair of sevens");
        _money("final  ");

        assertEq(table.stack(alice), BUY_IN + ANTE);
        assertEq(chip.balanceOf(address(table)), table.totalAccounted());
    }
}
