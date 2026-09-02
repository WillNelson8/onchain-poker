// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IDeckSource} from "./IDeckSource.sol";

/// @title Table
/// @notice Heads-up, one face-up card each, one fixed-limit betting round.
contract Table {
    using SafeERC20 for IERC20;

    uint256 public constant SEAT_COUNT = 2;
    uint256 public constant MAX_BETS_PER_ROUND = 4;

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

    uint8[SEAT_COUNT] public hole;
    uint256[SEAT_COUNT] public committed;
    bool[SEAT_COUNT] public folded;
    bool[SEAT_COUNT] public hasActed;

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

    event SatDown(address indexed player, uint256 seat, uint256 amount);
    event StoodUp(address indexed player, uint256 seat, uint256 amount);
    event HandStarted(uint256 indexed requestId, uint256 dealerSeat);
    event Dealt(uint8 card0, uint8 card1);
    event Acted(uint256 indexed seat, Action action, uint256 committedNow);
    event HandEnded(uint256 toSeat0, uint256 toSeat1);

    constructor(IERC20 chip_, IDeckSource deckSource_, uint256 buyInAmount_, uint256 ante_, uint256 betSize_) {
        chip = chip_;
        deckSource = deckSource_;
        buyInAmount = buyInAmount_;
        ante = ante_;
        betSize = betSize_;
    }

    // ---------------------------------------------------------------
    // Seats and money — Phase 1, now gated on Phase.Idle
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

    // The Phase 1 TODO, now paid off. Without this line a losing
    // player simply stands up and walks off with committed chips.
    function cashOut() external {
        if (phase != Phase.Idle) revert WrongPhase();
        (uint256 seat, bool seated) = seatOf(msg.sender);
        if (!seated) revert NotSeated();

        uint256 amount = stack[msg.sender];
        stack[msg.sender] = 0;
        seats[seat] = address(0);

        chip.safeTransfer(msg.sender, amount);
        emit StoodUp(msg.sender, seat, amount);
    }

    function totalAccounted() public view returns (uint256 total) {
        for (uint256 i; i < SEAT_COUNT; ++i) {
            total += stack[seats[i]];
        }
        total += pot;
    }

    // ---------------------------------------------------------------
    // The hand
    // ---------------------------------------------------------------

    function startHand() external {
        if (phase != Phase.Idle) revert WrongPhase();
        if (seats[0] == address(0) || seats[1] == address(0)) revert NeedTwoPlayers();

        _commit(0, ante);
        _commit(1, ante);

        pendingRequestId = deckSource.requestShuffle();
        phase = Phase.AwaitingDeck;

        emit HandStarted(pendingRequestId, dealerSeat);
    }

    // Anyone may call this once the oracle has answered. Separating it
    // from startHand is forced by the async gap — the deck does not
    // exist in the transaction that asked for it.
    function deal() external {
        if (phase != Phase.AwaitingDeck) revert WrongPhase();
        if (!deckSource.isReady(pendingRequestId)) revert DeckNotReady();

        hole[0] = deckSource.cardAt(0);
        hole[1] = deckSource.cardAt(1);

        actor = dealerSeat;
        phase = Phase.Betting;

        emit Dealt(hole[0], hole[1]);
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
            // Bet, or a raise if there is already something to call.
            if (betsThisRound >= MAX_BETS_PER_ROUND) revert BettingCapped();
            _commit(seat, toCall + betSize);
            betsThisRound += 1;
        }

        hasActed[seat] = true;
        emit Acted(seat, action, committed[seat]);

        // The rule from step 27, verbatim.
        if (hasActed[0] && hasActed[1] && committed[0] == committed[1]) {
            _showdown();
        } else {
            actor = opp;
        }
    }

    // ---------------------------------------------------------------
    // Settlement
    // ---------------------------------------------------------------

    function _showdown() internal {
        uint8 rank0 = hole[0] % 13;
        uint8 rank1 = hole[1] % 13;

        if (rank0 > rank1) {
            _endHand(pot, 0);
        } else if (rank1 > rank0) {
            _endHand(0, pot);
        } else {
            // Integer division loses the odd chip. If you drop it, the
            // solvency invariant breaks by exactly 1 wei and the fuzz
            // test finds it. Award it to the dealer, which alternates.
            uint256 half = pot / 2;
            uint256 odd = pot - (half * 2);
            if (dealerSeat == 0) _endHand(half + odd, half);
            else _endHand(half, half + odd);
        }
    }

    function _endHand(uint256 toSeat0, uint256 toSeat1) internal {
        pot = 0;
        if (toSeat0 > 0) stack[seats[0]] += toSeat0;
        if (toSeat1 > 0) stack[seats[1]] += toSeat1;

        emit HandEnded(toSeat0, toSeat1);

        delete hole;
        delete committed;
        delete folded;
        delete hasActed;

        betsThisRound = 0;
        actor = 0;
        pendingRequestId = 0;
        dealerSeat = SEAT_COUNT - 1 - dealerSeat;
        phase = Phase.Idle;
    }

    // Chips leave a stack and enter the pot. Both sides of the
    // invariant move together, so totalAccounted() never changes.
    function _commit(uint256 seat, uint256 amount) internal {
        address player = seats[seat];
        if (stack[player] < amount) revert InsufficientStack();
        stack[player] -= amount;
        committed[seat] += amount;
        pot += amount;
    }
}
