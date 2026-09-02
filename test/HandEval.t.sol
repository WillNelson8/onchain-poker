// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {HandEval} from "../src/HandEval.sol";

contract HandEvalTest is Test {
    // card = suit * 13 + rank, rank 0='2' .. 12='A', suit 0=c 1=d 2=h 3=s

    function _h(uint8 a, uint8 b, uint8 c, uint8 d, uint8 e, uint8 f, uint8 g)
        internal
        pure
        returns (uint8[7] memory out)
    {
        out[0] = a;
        out[1] = b;
        out[2] = c;
        out[3] = d;
        out[4] = e;
        out[5] = f;
        out[6] = g;
    }

    // Ah 2h 3h 4h 5h Kc 9d  -- the steel wheel
    function _steelWheel() internal pure returns (uint8[7] memory) {
        return _h(38, 26, 27, 28, 29, 11, 20);
    }

    // 7c 7d 7h 7s Ac 2d 3h
    function _quads() internal pure returns (uint8[7] memory) {
        return _h(5, 18, 31, 44, 12, 13, 27);
    }

    // 9c 9d 9h 5c 5d 5h 2s -- two trips, lower plays as the pair
    function _fullHouse() internal pure returns (uint8[7] memory) {
        return _h(7, 20, 33, 3, 16, 29, 39);
    }

    // Kc Jc 8c 5c 2c Ad 9h -- five clubs, ace is off-suit
    function _flush() internal pure returns (uint8[7] memory) {
        return _h(11, 9, 6, 3, 0, 25, 33);
    }

    // 2c 3d 4h 5s 6c Kd 9h
    function _sixHighStraight() internal pure returns (uint8[7] memory) {
        return _h(0, 14, 28, 42, 4, 24, 33);
    }

    // Ac 2d 3h 4s 5c Kd 9h -- the wheel
    function _wheel() internal pure returns (uint8[7] memory) {
        return _h(12, 13, 27, 41, 3, 24, 33);
    }

    // 7c 7d 7h Ac Kd 5s 2h
    function _trips() internal pure returns (uint8[7] memory) {
        return _h(5, 18, 31, 12, 24, 42, 26);
    }

    // 7c 7d 5h 5s Ac Kd 2h
    function _twoPair() internal pure returns (uint8[7] memory) {
        return _h(5, 18, 29, 42, 12, 24, 26);
    }

    // Ac Ad Kh Qs 9c 5d 2h
    function _pair() internal pure returns (uint8[7] memory) {
        return _h(12, 25, 37, 49, 7, 16, 26);
    }

    // Ac Kd Qh 9s 7c 5d 2h
    function _highCard() internal pure returns (uint8[7] memory) {
        return _h(12, 24, 36, 46, 5, 16, 26);
    }

    function test_Categories() public pure {
        assertEq(HandEval.score(_steelWheel()) >> 20, HandEval.STRAIGHT_FLUSH);
        assertEq(HandEval.score(_quads()) >> 20, HandEval.QUADS);
        assertEq(HandEval.score(_fullHouse()) >> 20, HandEval.FULL_HOUSE);
        assertEq(HandEval.score(_flush()) >> 20, HandEval.FLUSH);
        assertEq(HandEval.score(_sixHighStraight()) >> 20, HandEval.STRAIGHT);
        assertEq(HandEval.score(_wheel()) >> 20, HandEval.STRAIGHT);
        assertEq(HandEval.score(_trips()) >> 20, HandEval.TRIPS);
        assertEq(HandEval.score(_twoPair()) >> 20, HandEval.TWO_PAIR);
        assertEq(HandEval.score(_pair()) >> 20, HandEval.PAIR);
        assertEq(HandEval.score(_highCard()) >> 20, HandEval.HIGH_CARD);
    }

    // The whole ranking of poker, as one chain of inequalities.
    function test_TheLadder() public pure {
        uint256 sf = HandEval.score(_steelWheel());
        uint256 q = HandEval.score(_quads());
        uint256 fh = HandEval.score(_fullHouse());
        uint256 fl = HandEval.score(_flush());
        uint256 st6 = HandEval.score(_sixHighStraight());
        uint256 wh = HandEval.score(_wheel());
        uint256 tr = HandEval.score(_trips());
        uint256 tp = HandEval.score(_twoPair());
        uint256 pr = HandEval.score(_pair());
        uint256 hc = HandEval.score(_highCard());

        assertGt(sf, q);
        assertGt(q, fh);
        assertGt(fh, fl);
        assertGt(fl, st6);
        assertGt(st6, wh); // six-high beats the wheel
        assertGt(wh, tr);
        assertGt(tr, tp);
        assertGt(tp, pr);
        assertGt(pr, hc);
    }

    // A property, not an example: any hand out of any seven cards must
    // land in a real category, and reordering the cards must not change
    // the answer. That second part catches a whole class of index bugs.
    function testFuzz_OrderIndependentAndInRange(uint256 entropy) public pure {
        uint8[7] memory cards;
        uint8[7] memory shuffled;
        for (uint256 i; i < 7; ++i) {
            cards[i] = uint8(uint256(keccak256(abi.encode(entropy, i))) % 52);
            shuffled[6 - i] = cards[i];
        }

        uint256 s = HandEval.score(cards);
        assertLe(s >> 20, HandEval.STRAIGHT_FLUSH);
        assertEq(s, HandEval.score(shuffled), "order changed the score");
    }
}
