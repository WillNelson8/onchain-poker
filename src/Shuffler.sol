// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {IDeckSource} from "./IDeckSource.sol";

/// @title Shuffler
/// @notice One random word in, one shuffled deck out. Knows no poker.
contract Shuffler is VRFConsumerBaseV2Plus, IDeckSource {
    /// @dev The async gap made explicit. Nothing else in this contract
    /// matters as much as the fact that this enum has to exist.
    enum Status {
        Idle,
        Awaiting,
        Ready
    }

    uint256 public immutable subscriptionId;
    bytes32 public immutable keyHash;

    uint32 public constant CALLBACK_GAS_LIMIT = 300_000;
    uint16 public constant REQUEST_CONFIRMATIONS = 3;

    /// @dev After this long, an unanswered request can be superseded.
    /// Without it, one oracle failure bricks the shuffler permanently.
    uint256 public constant REQUEST_TIMEOUT = 1 hours;

    Status public status;
    uint256 public requestId;
    uint256 public requestedAt;
    uint256 public seed;
    uint8[52] public deck;

    error AlreadyAwaiting();

    event ShuffleRequested(uint256 indexed requestId);
    event ShuffleReady(uint256 indexed requestId, uint256 seed);

    constructor(address coordinator, uint256 subscriptionId_, bytes32 keyHash_) VRFConsumerBaseV2Plus(coordinator) {
        subscriptionId = subscriptionId_;
        keyHash = keyHash_;
    }

    function requestShuffle() external returns (uint256) {
        if (status == Status.Awaiting && block.timestamp < requestedAt + REQUEST_TIMEOUT) {
            revert AlreadyAwaiting();
        }

        status = Status.Awaiting;
        requestedAt = block.timestamp;

        requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: keyHash,
                subId: subscriptionId,
                requestConfirmations: REQUEST_CONFIRMATIONS,
                callbackGasLimit: CALLBACK_GAS_LIMIT,
                numWords: 1,
                extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: false}))
            })
        );

        emit ShuffleRequested(requestId);
        return requestId;
    }

    /// @dev Chainlink calls this, in its own transaction, minutes later.
    function fulfillRandomWords(uint256 requestId_, uint256[] calldata randomWords) internal override {
        // Never revert in a VRF callback. The coordinator has already paid
        // for and proved this randomness; reverting burns it and gains
        // nothing. A late answer to a superseded request is simply not
        // interesting, so ignore it and return cleanly.
        if (requestId_ != requestId) return;

        seed = randomWords[0];
        _shuffle(seed);
        status = Status.Ready;

        emit ShuffleReady(requestId_, seed);
    }

    /// @dev Fisher-Yates. Walk down the deck, swap each card with a random
    /// earlier one. Every permutation equally likely, given a fair seed.
    function _shuffle(uint256 seed_) internal {
        for (uint8 i; i < 52; ++i) {
            deck[i] = i;
        }
        for (uint256 i = 51; i > 0; --i) {
            uint256 j = uint256(keccak256(abi.encode(seed_, i))) % (i + 1);
            (deck[i], deck[j]) = (deck[j], deck[i]);
        }
    }

    function fullDeck() external view returns (uint8[52] memory) {
        return deck;
    }

    // ---------------------------------------------------------------
    // IDeckSource
    // ---------------------------------------------------------------

    /// @dev Takes the request id rather than just reporting "ready",
    /// because this contract outlives any single hand. A table that only
    /// asked "are you ready?" would happily deal last hand's deck.
    function isReady(uint256 requestId_) external view returns (bool) {
        return status == Status.Ready && requestId_ == requestId;
    }

    function cardAt(uint256 index) external view returns (uint8) {
        return deck[index];
    }
}
