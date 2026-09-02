// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Table} from "../src/Table.sol";
import {PassiveVault} from "../src/PassiveVault.sol";
import {MockChip} from "./mocks/MockChip.sol";
import {MockDeck} from "./mocks/MockDeck.sol";

contract YieldTest is Test {
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
            chip.mint(players[i], 1_000e18);
            vm.prank(players[i]);
            chip.approve(address(table), type(uint256).max);
            vm.prank(players[i]);
            table.buyIn();
        }
    }

    /// alice Ac Ad | bob 7c 7d | board Ah 2s 9c Kd 4h -> alice trip aces
    function _playToShowdown() internal {
        table.startHand();
        deck.setHand([uint8(12), 25, 5, 18, 38, 39, 7, 24, 28]);
        deck.fulfil();
        table.deal();

        for (uint256 i; i < 4; ++i) {
            vm.prank(table.seats(table.actor()));
            table.act(Table.Action.Check);
            vm.prank(table.seats(table.actor()));
            table.act(Table.Action.Check);
        }
    }

    function _solvent() internal view {
        assertGe(table.backing(), table.totalAccounted() + table.prizePool(), "backing does not cover what is owed");
    }

    // ---------------------------------------------------------------
    // Liquidity
    // ---------------------------------------------------------------

    function test_Sweep_LeavesTheBuffer() public {
        assertEq(table.totalAccounted(), 200e18);

        table.sweep();

        assertEq(table.idle(), 40e18, "20% buffer stays put");
        assertEq(vault.totalAssets(), 160e18, "the rest is deployed");
        assertEq(table.backing(), 200e18, "nothing created or destroyed");
        _solvent();
    }

    function test_Sweep_IsIdempotent() public {
        table.sweep();
        uint256 deployed = vault.totalAssets();

        table.sweep();
        assertEq(vault.totalAssets(), deployed, "second sweep does nothing");
    }

    function test_CashOut_PullsFromStrategyWhenShort() public {
        table.sweep(); // only 40 idle, but alice wants 100

        vm.prank(alice);
        table.cashOut();

        assertEq(chip.balanceOf(alice), 1_000e18, "paid in full");
        assertEq(table.totalAccounted(), 100e18, "only bob left");
        _solvent();
    }

    // ---------------------------------------------------------------
    // Yield
    // ---------------------------------------------------------------

    function test_Skim_TakesOnlySurplus() public {
        table.sweep();
        chip.mint(address(vault), 7e18); // a week of interest

        table.skim();
        assertEq(table.prizePool(), 7e18);

        // Calling again finds nothing. No access control needed.
        table.skim();
        table.skim();
        assertEq(table.prizePool(), 7e18, "surplus is not double counted");

        // Player money never moved.
        assertEq(table.stack(alice), BUY_IN);
        assertEq(table.stack(bob), BUY_IN);
        _solvent();
    }

    function test_Skim_DoesNothingWithoutYield() public {
        table.sweep();
        table.skim();
        assertEq(table.prizePool(), 0);
    }

    // ---------------------------------------------------------------
    // The prize
    // ---------------------------------------------------------------

    function test_Showdown_RecordsTheBestHand() public {
        _playToShowdown();

        assertEq(table.bestPlayer(), alice, "trip aces is the hand to beat");
        assertGt(table.bestScore(), 0);
    }

    function test_AwardHighHand_RevertsMidEpoch() public {
        vm.expectRevert(Table.EpochNotOver.selector);
        table.awardHighHand();
    }

    function test_AwardHighHand_PaysTheWalletAndResets() public {
        _playToShowdown();
        chip.mint(address(vault), 7e18);
        table.skim();

        uint256 before = chip.balanceOf(alice);
        vm.warp(block.timestamp + 7 days + 1);
        table.awardHighHand();

        assertEq(chip.balanceOf(alice) - before, 7e18, "prize lands in the wallet");
        assertEq(table.prizePool(), 0);
        assertEq(table.bestScore(), 0, "epoch reset");
        assertEq(table.bestPlayer(), address(0));
        _solvent();
    }

    function test_AwardHighHand_SurvivesAnEmptyEpoch() public {
        vm.warp(block.timestamp + 7 days + 1);
        table.awardHighHand(); // nobody played, nothing to pay

        assertEq(table.prizePool(), 0);
        _solvent();
    }

    // ---------------------------------------------------------------
    // The invariant, with chips deployed and interest landing
    // ---------------------------------------------------------------

    function testFuzz_SolventThroughHandsSweepsAndYield(uint256 entropy) public {
        for (uint256 h; h < 3; ++h) {
            uint256 roll = uint256(keccak256(abi.encode(entropy, h)));

            if (roll % 3 == 0) table.sweep();
            if (roll % 5 == 0) chip.mint(address(vault), (roll % 1e18) + 1);
            if (roll % 7 == 0) table.skim();

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

            for (uint256 step; step < 12; ++step) {
                uint256 pick = uint256(keccak256(abi.encode(roll, step, uint256(3))));

                vm.prank(pick % 2 == 0 ? alice : bob);
                try table.act(Table.Action(uint8(pick >> 8) % 4)) {} catch {}

                _solvent();
            }
        }

        _solvent();
    }
}
