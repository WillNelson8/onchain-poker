// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title HandEval
/// @notice Scores a 7-card hold'em hand. Pure — no storage, no state, no
/// external calls. Higher score wins; compare two scores directly.
library HandEval {
    uint256 internal constant HIGH_CARD = 0;
    uint256 internal constant PAIR = 1;
    uint256 internal constant TWO_PAIR = 2;
    uint256 internal constant TRIPS = 3;
    uint256 internal constant STRAIGHT = 4;
    uint256 internal constant FLUSH = 5;
    uint256 internal constant FULL_HOUSE = 6;
    uint256 internal constant QUADS = 7;
    uint256 internal constant STRAIGHT_FLUSH = 8;

    // Ranks are 0-12, so 13 is a safe "not found" sentinel.
    uint256 internal constant NONE = 13;

    function score(uint8[7] memory cards) internal pure returns (uint256) {
        uint256[13] memory rankCount;
        uint256[4] memory suitCount;
        uint256[4] memory suitRankMask;
        uint256 rankMask;

        for (uint256 i; i < 7; ++i) {
            uint256 r = cards[i] % 13;
            uint256 s = cards[i] / 13;
            rankCount[r] += 1;
            suitCount[s] += 1;
            rankMask |= (1 << r);
            suitRankMask[s] |= (1 << r);
        }

        uint256[5] memory v;

        // Flush family first: with 7 cards only one suit can reach 5,
        // so the first hit is the only candidate.
        for (uint256 s; s < 4; ++s) {
            if (suitCount[s] >= 5) {
                uint256 sf = _straightHigh(suitRankMask[s]);
                if (sf != NONE) {
                    v[0] = sf;
                    return _pack(STRAIGHT_FLUSH, v);
                }
                _fill(v, 0, 5, suitRankMask[s], 0);
                return _pack(FLUSH, v);
            }
        }

        uint256 quad = NONE;
        uint256 trip = NONE;
        uint256 trip2 = NONE;
        uint256 pair1 = NONE;
        uint256 pair2 = NONE;

        // Walk high to low so the first of each kind found is the best.
        for (uint256 i; i < 13; ++i) {
            uint256 r = 12 - i;
            uint256 n = rankCount[r];
            if (n == 4) {
                if (quad == NONE) quad = r;
            } else if (n == 3) {
                if (trip == NONE) trip = r;
                else if (trip2 == NONE) trip2 = r;
            } else if (n == 2) {
                if (pair1 == NONE) pair1 = r;
                else if (pair2 == NONE) pair2 = r;
            }
        }

        if (quad != NONE) {
            v[0] = quad;
            _fill(v, 1, 1, rankMask, 1 << quad);
            return _pack(QUADS, v);
        }

        // Two trips is a full house: the lower trip plays as the pair.
        if (trip != NONE && (pair1 != NONE || trip2 != NONE)) {
            v[0] = trip;
            uint256 a = pair1 == NONE ? 0 : pair1;
            uint256 b = trip2 == NONE ? 0 : trip2;
            v[1] = a > b ? a : b;
            return _pack(FULL_HOUSE, v);
        }

        uint256 st = _straightHigh(rankMask);
        if (st != NONE) {
            v[0] = st;
            return _pack(STRAIGHT, v);
        }

        if (trip != NONE) {
            v[0] = trip;
            _fill(v, 1, 2, rankMask, 1 << trip);
            return _pack(TRIPS, v);
        }

        if (pair1 != NONE && pair2 != NONE) {
            v[0] = pair1;
            v[1] = pair2;
            _fill(v, 2, 1, rankMask, (1 << pair1) | (1 << pair2));
            return _pack(TWO_PAIR, v);
        }

        if (pair1 != NONE) {
            v[0] = pair1;
            _fill(v, 1, 3, rankMask, 1 << pair1);
            return _pack(PAIR, v);
        }

        _fill(v, 0, 5, rankMask, 0);
        return _pack(HIGH_CARD, v);
    }

    // Five consecutive bits ending at `high`. One AND per candidate.
    function _straightHigh(uint256 mask) private pure returns (uint256) {
        for (uint256 i; i < 9; ++i) {
            uint256 high = 12 - i;
            uint256 need = 0x1F << (high - 4);
            if ((mask & need) == need) return high;
        }
        // The wheel: A,2,3,4,5. Ace is rank 12, so it needs its own mask.
        uint256 wheel = (1 << 12) | 1 | 2 | 4 | 8;
        if ((mask & wheel) == wheel) return 3;
        return NONE;
    }

    // Write the top `count` ranks present in `mask` (skipping `exclude`)
    // into v starting at `start`.
    function _fill(uint256[5] memory v, uint256 start, uint256 count, uint256 mask, uint256 exclude) private pure {
        uint256 idx = start;
        uint256 filled;
        for (uint256 i; i < 13; ++i) {
            if (filled == count) break;
            uint256 r = 12 - i;
            if ((mask & (1 << r)) != 0 && (exclude & (1 << r)) == 0) {
                v[idx] = r;
                idx += 1;
                filled += 1;
            }
        }
    }

    function _pack(uint256 cat, uint256[5] memory v) private pure returns (uint256) {
        return (cat << 20) | (v[0] << 16) | (v[1] << 12) | (v[2] << 8) | (v[3] << 4) | v[4];
    }
}
