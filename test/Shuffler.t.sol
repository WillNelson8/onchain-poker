// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2 as console} from "forge-std/Test.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
import {Shuffler} from "../src/Shuffler.sol";

contract ShufflerTest is Test {
    VRFCoordinatorV2_5Mock coordinator;
    Shuffler shuffler;
    uint256 subId;

    bytes32 constant KEY_HASH = bytes32(uint256(1));

    function setUp() public {
        coordinator = new VRFCoordinatorV2_5Mock(0.1 ether, 1e9, 4e15);
        subId = coordinator.createSubscription();
        coordinator.fundSubscription(subId, 100 ether);

        shuffler = new Shuffler(address(coordinator), subId, KEY_HASH);
        coordinator.addConsumer(subId, address(shuffler));
    }

    function test_StatusMovesIdleAwaitingReady() public {
        assertEq(uint256(shuffler.status()), 0, "should start Idle");

        uint256 reqId = shuffler.requestShuffle();

        // THE POINT OF THIS ENTIRE PHASE.
        // The request returned. Nothing is shuffled. No seed exists.
        // On a real network you would sit here for minutes.
        assertEq(uint256(shuffler.status()), 1, "should be Awaiting");
        assertEq(shuffler.seed(), 0, "no seed yet");

        coordinator.fulfillRandomWords(reqId, address(shuffler));

        assertEq(uint256(shuffler.status()), 2, "should be Ready");
        assertGt(shuffler.seed(), 0, "seed should be set");
    }

    function test_CannotRequestTwiceWhileWaiting() public {
        shuffler.requestShuffle();
        vm.expectRevert(Shuffler.AlreadyAwaiting.selector);
        shuffler.requestShuffle();
    }

    // For ANY seed, the deck must contain all 52 cards exactly once.
    // A shuffle that drops or duplicates a card is the kind of bug
    // that looks fine in every hand until it doesn't.
    function testFuzz_DeckIsAlwaysAPermutation(uint256 entropy) public {
        uint256 reqId = shuffler.requestShuffle();

        uint256[] memory words = new uint256[](1);
        words[0] = entropy;
        coordinator.fulfillRandomWordsWithOverride(reqId, address(shuffler), words);

        bool[52] memory seen;
        for (uint256 i; i < 52; ++i) {
            uint8 card = shuffler.deck(i);
            assertLt(card, 52, "card out of range");
            assertFalse(seen[card], "duplicate card");
            seen[card] = true;
        }
    }

    function test_PrintTopFive() public {
        uint256 reqId = shuffler.requestShuffle();
        coordinator.fulfillRandomWords(reqId, address(shuffler));

        string[4] memory suits = ["clubs", "diamonds", "hearts", "spades"];
        string[13] memory ranks = ["2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K", "A"];

        for (uint256 i; i < 5; ++i) {
            uint8 card = shuffler.deck(i);
            console.log(string.concat(ranks[card % 13], " of ", suits[card / 13]));
        }
    }

    function test_StaleRequestCanBeSuperseded() public {
        shuffler.requestShuffle();

        vm.expectRevert(Shuffler.AlreadyAwaiting.selector);
        shuffler.requestShuffle();

        vm.warp(block.timestamp + 1 hours + 1);
        shuffler.requestShuffle(); // no longer stuck
    }
}

