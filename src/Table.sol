// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IDeckSource} from "./IDeckSource.sol";
import {IYieldStrategy} from "./IYieldStrategy.sol";
import {HandEval} from "./HandEval.sol";

/// @title Table
/// @notice Heads-up limit hold'em with a yield-funded high-hand prize.
/// @dev Solvency invariant, enforced by the fuzz tests:
///      idle() + strategy.totalAssets() >= totalAccounted() + prizePool
contract Table {
    using SafeERC20 for IERC20;

    uint256 public constant SEAT_COUNT = 2;
    uint256 public constant MAX_BETS_PER_ROUND = 4;
    uint256 public constant ACTION_TIMEOUT = 5 minutes;
    uint256 public constant DECK_TIMEOUT = 1 hours;

    /// @dev 20% of player money stays liquid so an ordinary cash-out
    /// never has to touch the yield source.
    uint256 public constant BUFFER_BPS = 2000;
    uint256 public constant EPOCH = 7 days;

    enum Phase {
        Idle,
        AwaitingDeck,
        Betting
    }

    enum Action {
        Check,
        Bet,
        Call,
        Fold
    }

    IERC20 public immutable chip;
    IDeckSource public immutable deckSource;
    IYieldStrategy public immutable strategy;
    uint256 public immutable buyInAmount;
    uint256 public immutable ante;
    uint256 public immutable betSize;

    address[SEAT_COUNT] public seats;
    mapping(address => uint256) public stack;
    uint256 public pot;

    Phase public phase;
    uint256 public dealerSeat;
    uint256 public pendingRequestId;
    uint256 public actor;
    uint256 public betsThisRound;
    uint256 public deadline;

    /// @dev 0 = preflop, 1 = flop, 2 = turn, 3 = river
    uint8 public street;

    uint8[2][SEAT_COUNT] public hole;
    uint8[5] public board;

    uint256[SEAT_COUNT] public committed;
    bool[SEAT_COUNT] public folded;
    bool[SEAT_COUNT] public hasActed;

    uint256 public prizePool;
    uint256 public epochEnd;
    uint256 public bestScore;
    address public bestPlayer;

    error TableFull();
    error AlreadySeated();
    error NotSeated();
    error WrongPhase();
    error NeedTwoPlayers();
    error NotYourTurn();
    error DeckNotReady();
    error MustCallOrFold();
    error NothingToCall();
    error BettingCapped();
    error InsufficientStack();
    error DeadlineNotPassed();
    error StrategyAssetMismatch();
    error EpochNotOver();

    event SatDown(address indexed player, uint256 seat, uint256 amount);
    event StoodUp(address indexed player, uint256 seat, uint256 amount);
    event HandStarted(uint256 indexed requestId, uint256 dealerSeat);
    event Dealt(uint8 a0, uint8 a1, uint8 b0, uint8 b1);
    event StreetAdvanced(uint8 street);
    event Acted(uint256 indexed seat, Action action, uint256 committedNow);
    event HandEnded(uint256 toSeat0, uint256 toSeat1);
    event ForceFolded(uint256 indexed seat, address caller);
    event HandAborted(uint256 refund0, uint256 refund1);
    event Swept(uint256 amount);
    event Skimmed(uint256 amount);
    event HighHand(address indexed player, uint256 score);
    event HighHandAwarded(address indexed player, uint256 amount);

    constructor(
        IERC20 chip_,
        IDeckSource deckSource_,
        IYieldStrategy strategy_,
        uint256 buyInAmount_,
        uint256 ante_,
        uint256 betSize_
    ) {
        if (strategy_.asset() != address(chip_)) revert StrategyAssetMismatch();

        chip = chip_;
        deckSource = deckSource_;
        strategy = strategy_;
        buyInAmount = buyInAmount_;
        ante = ante_;
        betSize = betSize_;

        epochEnd = block.timestamp + EPOCH;
    }

    // ---------------------------------------------------------------
    // Seats and money
    // ---------------------------------------------------------------

    function seatOf(address player) public view returns (uint256 seat, bool seated) {
        for (uint256 i; i < SEAT_COUNT; ++i) {
            if (seats[i] == player) return (i, true);
        }
        return (0, false);
    }

    function buyIn() external {
        if (phase != Phase.Idle) revert WrongPhase();
        (, bool seated) = seatOf(msg.sender);
        if (seated) revert AlreadySeated();

        uint256 seat = SEAT_COUNT;
        for (uint256 i; i < SEAT_COUNT; ++i) {
            if (seats[i] == address(0)) {
                seat = i;
                break;
            }
        }
        if (seat == SEAT_COUNT) revert TableFull();

        seats[seat] = msg.sender;
        stack[msg.sender] = buyInAmount;

        chip.safeTransferFrom(msg.sender, address(this), buyInAmount);
        emit SatDown(msg.sender, seat, buyInAmount);
    }

    function cashOut() external {
        if (phase != Phase.Idle) revert WrongPhase();
        (uint256 seat, bool seated) = seatOf(msg.sender);
        if (!seated) revert NotSeated();

        uint256 amount = stack[msg.sender];
        stack[msg.sender] = 0;
        seats[seat] = address(0);

        _ensureLiquid(amount);
        chip.safeTransfer(msg.sender, amount);
        emit StoodUp(msg.sender, seat, amount);
    }

    /// @notice What the table owes its players: stacks plus the live pot.
    function totalAccounted() public view returns (uint256 total) {
        for (uint256 i; i < SEAT_COUNT; ++i) {
            total += stack[seats[i]];
        }
        total += pot;
    }

    // ---------------------------------------------------------------
    // Yield
    // ---------------------------------------------------------------

    function idle() public view returns (uint256) {
        return chip.balanceOf(address(this));
    }

    function backing() public view returns (uint256) {
        return idle() + strategy.totalAssets();
    }

    function targetIdle() public view returns (uint256) {
        return (totalAccounted() * BUFFER_BPS) / 10_000;
    }

    /// @notice Move idle chips above the buffer into the yield source.
    /// @dev Permissionless. Nobody has to call it — the table just earns
    /// less if nobody does.
    function sweep() external {
        uint256 target = targetIdle();
        uint256 have = idle();
        if (have <= target) return;

        uint256 amount = have - target;
        chip.forceApprove(address(strategy), amount);
        strategy.deposit(amount);

        emit Swept(amount);
    }

    /// @notice Move unclaimed yield into the prize pool.
    /// @dev Callable by anyone, any number of times. It can only take the
    /// surplus above what is owed, so no amount of calling it touches a
    /// single chip of anyone's stack. Arithmetic beats a modifier.
    function skim() external {
        uint256 owed = totalAccounted() + prizePool;
        uint256 have = backing();
        if (have <= owed) return;

        uint256 surplus = have - owed;
        _ensureLiquid(surplus);
        prizePool += surplus;

        emit Skimmed(surplus);
    }

    /// @notice Pay the epoch's best hand and start a new one.
    function awardHighHand() external {
        if (block.timestamp < epochEnd) revert EpochNotOver();

        address winner = bestPlayer;
        uint256 amount = prizePool;

        prizePool = 0;
        bestScore = 0;
        bestPlayer = address(0);
        epochEnd = block.timestamp + EPOCH;

        if (winner != address(0) && amount > 0) {
            _ensureLiquid(amount);
            chip.safeTransfer(winner, amount);
        }

        emit HighHandAwarded(winner, amount);
    }

    /// @dev Pulls from the strategy only when the buffer is short.
    function _ensureLiquid(uint256 amount) internal {
        uint256 have = idle();
        if (have < amount) {
            strategy.withdraw(amount - have);
        }
    }

    // ---------------------------------------------------------------
    // The hand
    // ---------------------------------------------------------------

    function startHand() external {
        if (phase != Phase.Idle) revert WrongPhase();
        if (seats[0] == address(0) || seats[1] == address(0)) revert NeedTwoPlayers();

        _commit(0, ante);
        _commit(1, ante);

        phase = Phase.AwaitingDeck;
        deadline = block.timestamp + DECK_TIMEOUT;

        pendingRequestId = deckSource.requestShuffle();

        emit HandStarted(pendingRequestId, dealerSeat);
    }

    /// @notice Anyone may call this once the oracle has answered.
    function deal() external {
        if (phase != Phase.AwaitingDeck) revert WrongPhase();
        if (!deckSource.isReady(pendingRequestId)) revert DeckNotReady();

        hole[0][0] = deckSource.cardAt(0);
        hole[0][1] = deckSource.cardAt(1);
        hole[1][0] = deckSource.cardAt(2);
        hole[1][1] = deckSource.cardAt(3);

        street = 0;
        actor = dealerSeat; // heads-up: button acts first preflop
        phase = Phase.Betting;
        deadline = block.timestamp + ACTION_TIMEOUT;

        emit Dealt(hole[0][0], hole[0][1], hole[1][0], hole[1][1]);
    }

    function act(Action action) external {
        if (phase != Phase.Betting) revert WrongPhase();
        (uint256 seat, bool seated) = seatOf(msg.sender);
        if (!seated) revert NotSeated();
        if (seat != actor) revert NotYourTurn();

        uint256 opp = SEAT_COUNT - 1 - seat;
        uint256 toCall = committed[opp] - committed[seat];

        if (action == Action.Fold) {
            folded[seat] = true;
            emit Acted(seat, action, committed[seat]);
            if (opp == 0) _endHand(pot, 0);
            else _endHand(0, pot);
            return;
        }

        if (action == Action.Check) {
            if (toCall != 0) revert MustCallOrFold();
        } else if (action == Action.Call) {
            if (toCall == 0) revert NothingToCall();
            _commit(seat, toCall);
        } else {
            if (betsThisRound >= MAX_BETS_PER_ROUND) revert BettingCapped();
            _commit(seat, toCall + betSize);
            betsThisRound += 1;
        }

        hasActed[seat] = true;
        emit Acted(seat, action, committed[seat]);

        if (hasActed[0] && hasActed[1] && committed[0] == committed[1]) {
            _endBettingRound();
        } else {
            actor = opp;
            deadline = block.timestamp + ACTION_TIMEOUT;
        }
    }

    function forceFold() external {
        if (phase != Phase.Betting) revert WrongPhase();
        if (block.timestamp < deadline) revert DeadlineNotPassed();

        uint256 delinquent = actor;
        uint256 winner = SEAT_COUNT - 1 - delinquent;

        folded[delinquent] = true;
        emit ForceFolded(delinquent, msg.sender);

        if (winner == 0) _endHand(pot, 0);
        else _endHand(0, pot);
    }

    function abortHand() external {
        if (phase != Phase.AwaitingDeck) revert WrongPhase();
        if (block.timestamp < deadline) revert DeadlineNotPassed();

        uint256 refund0 = committed[0];
        uint256 refund1 = committed[1];

        emit HandAborted(refund0, refund1);
        _endHand(refund0, refund1);
    }

    // ---------------------------------------------------------------
    // Streets and settlement
    // ---------------------------------------------------------------

    function _endBettingRound() internal {
        if (street == 3) {
            _showdown();
            return;
        }

        street += 1;
        _revealBoard();

        // `committed` tracks THIS street's bets, so it clears. The chips
        // themselves are already in the pot and stay there.
        delete committed;
        delete hasActed;
        betsThisRound = 0;

        // Heads-up: the button acts first preflop and last after it.
        actor = SEAT_COUNT - 1 - dealerSeat;
        deadline = block.timestamp + ACTION_TIMEOUT;

        emit StreetAdvanced(street);
    }

    function _revealBoard() internal {
        if (street == 1) {
            board[0] = deckSource.cardAt(4);
            board[1] = deckSource.cardAt(5);
            board[2] = deckSource.cardAt(6);
        } else if (street == 2) {
            board[3] = deckSource.cardAt(7);
        } else if (street == 3) {
            board[4] = deckSource.cardAt(8);
        }
    }

    function _sevenCards(uint256 seat) internal view returns (uint8[7] memory out) {
        out[0] = hole[seat][0];
        out[1] = hole[seat][1];
        for (uint256 i; i < 5; ++i) {
            out[2 + i] = board[i];
        }
    }

    function _showdown() internal {
        uint256 s0 = HandEval.score(_sevenCards(0));
        uint256 s1 = HandEval.score(_sevenCards(1));

        // Both hands count for the prize, not just the winner's. Losing
        // with quads should still win you the week.
        _recordHighHand(0, s0);
        _recordHighHand(1, s1);

        if (s0 > s1) {
            _endHand(pot, 0);
        } else if (s1 > s0) {
            _endHand(0, pot);
        } else {
            uint256 half = pot / 2;
            uint256 odd = pot - (half * 2);
            if (dealerSeat == 0) _endHand(half + odd, half);
            else _endHand(half, half + odd);
        }
    }

    function _recordHighHand(uint256 seat, uint256 handScore) internal {
        if (handScore > bestScore) {
            bestScore = handScore;
            bestPlayer = seats[seat];
            emit HighHand(bestPlayer, handScore);
        }
    }

    function _endHand(uint256 toSeat0, uint256 toSeat1) internal {
        pot = 0;
        if (toSeat0 > 0) stack[seats[0]] += toSeat0;
        if (toSeat1 > 0) stack[seats[1]] += toSeat1;

        emit HandEnded(toSeat0, toSeat1);

        delete hole;
        delete board;
        delete committed;
        delete folded;
        delete hasActed;

        street = 0;
        betsThisRound = 0;
        actor = 0;
        pendingRequestId = 0;
        deadline = 0;
        dealerSeat = SEAT_COUNT - 1 - dealerSeat;
        phase = Phase.Idle;
    }

    /// @dev TODO Phase 7: no all-in. A player who cannot cover a call
    /// reverts here and has to fold instead.
    function _commit(uint256 seat, uint256 amount) internal {
        address player = seats[seat];
        if (stack[player] < amount) revert InsufficientStack();
        stack[player] -= amount;
        committed[seat] += amount;
        pot += amount;
    }
}
