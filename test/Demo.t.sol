// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2 as console} from "forge-std/Test.sol";
import {Table} from "../src/Table.sol";
import {MockChip} from "./mocks/MockChip.sol";

contract DemoTest is Test {
    Table table;
    MockChip chip;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        chip = new MockChip();
        table = new Table(chip, 100e18);

        address[2] memory players = [alice, bob];
        for (uint256 i; i < 2; ++i) {
            chip.mint(players[i], 500e18);
            vm.prank(players[i]);
            chip.approve(address(table), type(uint256).max);
        }
    }

    function test_Demo() public {
        console.log("=== onchain-poker | phase 1 ===");
        show("Empty table");

        vm.prank(alice);
        table.buyIn();
        show("Alice buys in for 100");

        vm.prank(bob);
        table.buyIn();
        show("Bob buys in for 100");

        vm.prank(alice);
        table.cashOut();
        show("Alice stands up");
    }

    function show(string memory label) internal view {
        console.log("");
        console.log(label);
        console.log("  seat 0       :", table.seats(0));
        console.log("  seat 1       :", table.seats(1));
        console.log("  alice wallet :", chip.balanceOf(alice) / 1e18);
        console.log("  bob wallet   :", chip.balanceOf(bob) / 1e18);
        console.log("  table holds  :", chip.balanceOf(address(table)) / 1e18);
        console.log("  table owes   :", table.totalAccounted() / 1e18);
    }
}
