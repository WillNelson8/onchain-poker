// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

/// @title Shuffler
/// @notice One random word in, one shuffled deck out. Knows no poker.
contract Shuffler is VRFConsumerBaseV2Plus {
    // The async gap made explicit. Nothing else in this contract
    // matters as much as the fact that this enum has to exist.
    enum Status {
        Idle,
        Awaiting,
        Ready
    }

    uint256 public immutable subscriptionId;
    bytes32 public immutable keyHash;

    uint32 public constant CALLBACK_GAS_LIMIT = 300_000;
    uint16 public constant REQUEST_CONFIRMATIONS = 3;

    Status public status;
    uint256 public requestId;
    uint256 public seed;
    uint8[52] public deck;

    error AlreadyAwaiting();
    error UnknownRequest();

    event ShuffleRequested(uint256 indexed requestId);
    event ShuffleReady(uint256 indexed requestId, uint256 seed);

    constructor(address coordinator, uint256 subscriptionId_, bytes32 keyHash_) VRFConsumerBaseV2Plus(coordinator) {
        subscriptionId = subscriptionId_;
        keyHash = keyHash_;
    }

    function requestShuffle() external returns (uint256) {
        if (status == Status.Awaiting) revert AlreadyAwaiting();
        status = Status.Awaiting;

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

    // Chainlink calls this. Not you, not a player — the coordinator,
    // in its own transaction, minutes later. It is `internal`, so
    // nothing outside can fake it, and the base contract checks the
    // caller before it ever reaches here.
    function fulfillRandomWords(uint256 requestId_, uint256[] calldata randomWords) internal override {
        if (requestId_ != requestId) revert UnknownRequest();

        seed = randomWords[0];
        _shuffle(seed);
        status = Status.Ready;

        emit ShuffleReady(requestId_, seed);
    }

    // Fisher-Yates. Walk down the deck, swap each card with a random
    // earlier one. Every permutation equally likely, given a fair seed.
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
}
