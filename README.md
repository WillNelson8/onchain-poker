# onchain-poker

Heads-up limit hold'em settled entirely by smart contract, with a
yield-funded high-hand prize. Built in public as a learning project.

**Testnet only. Not audited. Not for real money.**

## What it does

Two players buy in with an ERC-20, get two cards each, and play four
betting rounds against five community cards. The contract deals from a
Chainlink VRF shuffle, runs the betting, evaluates seven-card hands, and
settles the pot. Deposits that aren't needed for liquidity are deployed
to a yield strategy, and the interest accumulates into a weekly prize for
the best hand seen.

There is no owner, no admin key, and no pause. Nobody — including the
deployer — can freeze the table or move a player's chips.

## The invariant

Every phase preserves one property, and there is a fuzz test for it that
never gets deleted:

Everything that exists is at least everything that is owed. Chips move
between stacks, the pot, and the vault; the inequality holds after every
single action.

## Design constraints

- Two players, fixed-limit betting, one table per contract.
- Cards are dealt **face up**. Hidden information needs a completely
  different source of randomness — see Phase 7 below.
- Every state has an exit no other player can block: action deadlines
  with `forceFold`, a deck timeout with `abortHand`.
- No all-in yet. A player who cannot cover a call must fold.

## Build phases

| # | Phase | Status |
|---|-------|--------|
| 0 | Toolchain and repo | done |
| 1 | Bank — seats, stacks, solvency invariant | done |
| 2 | Randomness — Chainlink VRF v2.5 | done |
| 3 | Hand lifecycle — dealing, betting, showdown | done |
| 4 | Deadlines, force-fold, abort | done |
| 5 | Four streets, community cards, hand evaluator | done |
| 6 | Yield strategy, liquidity buffer, high-hand prize | done |
| 7 | Hidden cards — mental poker | research |

## Prize economics

Yield is pooled rather than credited to stacks, because per player it is
dust and pooled it is a prize. At $200,000 deposited and 6.5% APY,
compounded:

| Window | Pool |
|--------|------|
| 1 day | $34.51 |
| 1 week | $241.69 |
| 1 month | $1,037.89 |
| 1 year | $13,000.00 |

Spread across 1,000 players that month is $1.04 each — half a percent of
a buy-in, invisible. Concentrated into one prize it is $1,038. That
asymmetry is the whole argument for `skim()` collecting into a single
pool.

Both numbers move with the lending rate, which is the assumption outside
anyone's control: $486 at 3% APY, $1,269 at 8%.

## Layout

## Running it
forge build

## Notes on correctness

The hand evaluator was validated against a brute-force reference that
scores all 21 five-card subsets of every hand: 40,000 random deals, zero
category disagreements, zero ordering disagreements. A property test
also asserts that reordering the input cards cannot change the score,
which catches index bugs no fixture would.

## License

MIT
