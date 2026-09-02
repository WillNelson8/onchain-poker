// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDeckSource} from "../../src/IDeckSource.sol";

contract MockDeck is IDeckSource {
    uint256 public nextRequestId = 1;
    uint256 public lastRequestId;
    bool public ready;
    uint8[52] public cards;

    constructor() {
        for (uint8 i; i < 52; ++i) {
            cards[i] = i;
        }
    }

    // Rig the hand. This is the whole reason the mock exists.
    function setCards(uint8 c0, uint8 c1) external {
        cards[0] = c0;
        cards[1] = c1;
    }

    function requestShuffle() external returns (uint256) {
        lastRequestId = nextRequestId++;
        ready = false;
        return lastRequestId;
    }

    // Stands in for the oracle's second transaction.
    function fulfil() external {
        ready = true;
    }

    function isReady(uint256 requestId) external view returns (bool) {
        return ready && requestId == lastRequestId;
    }

    function cardAt(uint256 index) external view returns (uint8) {
        return cards[index];
    }

    // [0,1] = seat 0 hole, [2,3] = seat 1 hole, [4..8] = board
    function setHand(uint8[9] calldata nine) external {
        for (uint256 i; i < 9; ++i) {
            cards[i] = nine[i];
        }
    }
}
