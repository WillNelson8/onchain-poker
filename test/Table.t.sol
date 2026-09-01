// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Table} from "../src/Table.sol";
import {MockChip} from "./mocks/MockChip.sol";

contract TableTest is Test {
    Table table;
    MockChip chip;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    uint256 constant BUY_IN = 100e18;

    function setUp() public {
        chip = new MockChip();
        table = new Table(chip, BUY_IN);

        address[3] memory players = [alice, bob, carol];
        for (uint256 i; i < 3; ++i) {
            chip.mint(players[i], 1_000e18);
            // vm.prank makes the NEXT call come from this address.
            vm.prank(players[i]);
            chip.approve(address(table), type(uint256).max);
        }
    }

    function test_BuyIn_SeatsPlayerAndPullsChips() public {
        vm.prank(alice);
        table.buyIn();

        assertEq(table.seats(0), alice);
        assertEq(table.stack(alice), BUY_IN);
        assertEq(chip.balanceOf(address(table)), BUY_IN);
        assertEq(chip.balanceOf(alice), 900e18);
    }

    function test_BuyIn_RevertsIfAlreadySeated() public {
        vm.startPrank(alice);
        table.buyIn();
        vm.expectRevert(Table.AlreadySeated.selector);
        table.buyIn();
        vm.stopPrank();
    }

    function test_BuyIn_RevertsWhenTableFull() public {
        vm.prank(alice);
        table.buyIn();
        vm.prank(bob);
        table.buyIn();

        vm.prank(carol);
        vm.expectRevert(Table.TableFull.selector);
        table.buyIn();
    }

    function test_CashOut_ReturnsChipsAndFreesSeat() public {
        vm.startPrank(alice);
        table.buyIn();
        table.cashOut();
        vm.stopPrank();

        assertEq(table.seats(0), address(0));
        assertEq(table.stack(alice), 0);
        assertEq(chip.balanceOf(alice), 1_000e18);
        assertEq(chip.balanceOf(address(table)), 0);
    }

    // THE ONE THAT MATTERS.
    // Foundry runs this hundreds of times with random `entropy`,
    // producing a different sequence of sit-downs and stand-ups
    // each run. After EVERY action, the books must balance.
    function testFuzz_AlwaysSolvent(uint256 entropy) public {
        address[3] memory players = [alice, bob, carol];

        for (uint256 i; i < 12; ++i) {
            uint256 roll = uint256(keccak256(abi.encode(entropy, i)));
            address who = players[roll % 3];

            vm.prank(who);
            if (roll % 2 == 0) {
                try table.buyIn() {} catch {}
            } else {
                try table.cashOut() {} catch {}
            }

            assertEq(chip.balanceOf(address(table)), table.totalAccounted(), "books do not balance");
        }
    }
}
