# onchain-poker

Heads-up poker settled entirely by smart contract, built in public as a
learning project.

## Design constraints

- Two players, fixed-limit betting, one table per contract.
- Cards are dealt **face up** until the hidden-information layer lands.
  Every earlier phase is a real, working game without it.
- Testnet only. Not audited. Not for real money.

## Build phases

| # | Phase | Status |
|---|-------|--------|
| 0 | Toolchain and repo | ✅ |
| 1 | Bank — seats, stacks, solvency invariant | 🔨 |
| 2 | Randomness — Chainlink VRF | — |
| 3 | State machine — one card, face up | — |
| 4 | Deadlines and force-fold | — |
| 5 | Streets, board, hand evaluation | — |
| 6 | Yield layer and high-hand prize | — |
| 7 | Hidden cards — mental poker | — |

## Running it

```
forge build
forge test -vvv
```

## The invariant

Every phase must preserve one property: the table's token balance always
equals the sum of every player's stack plus the pot. There is a fuzz test
for it, and it never gets deleted.

## License

MIT