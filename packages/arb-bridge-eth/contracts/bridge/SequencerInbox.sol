// SPDX-License-Identifier: Apache-2.0

/*
 * Copyright 2021, Offchain Labs, Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

pragma solidity ^0.6.11;

import "./interfaces/ISequencerInbox.sol";
import "./interfaces/IBridge.sol";

import "./Messages.sol";

contract SequencerInbox is ISequencerInbox {
    uint8 internal constant L2_MSG = 3;

    bytes32[] public override inboxAccs;
    uint256 public override messageCount;

    uint256 totalDelayedMessagesRead;

    IBridge public delayedInbox;
    address public sequencer;
    uint256 public override maxDelayBlocks;
    uint256 public override maxDelaySeconds;

    function forceInclusion(
        uint256 _totalDelayedMessagesRead,
        uint8 kind,
        uint256 l1BlockNumber,
        uint256 l1Timestamp,
        uint256 inboxSeqNum,
        uint256 gasPriceL1,
        address sender,
        bytes32 messageDataHash
    ) external {
        require(_totalDelayedMessagesRead > totalDelayedMessagesRead);
        bytes32 messageHash =
            Messages.messageHash(
                kind,
                sender,
                l1BlockNumber,
                l1Timestamp,
                inboxSeqNum,
                gasPriceL1,
                messageDataHash
            );
        require(l1BlockNumber + maxDelayBlocks < block.number);
        require(l1Timestamp + maxDelaySeconds < block.timestamp);

        bytes32 prevAcc = 0;
        if (_totalDelayedMessagesRead > 1) {
            prevAcc = delayedInbox.inboxAccs(_totalDelayedMessagesRead - 2);
        }
        require(
            delayedInbox.inboxAccs(_totalDelayedMessagesRead - 1) ==
                Messages.addMessageToInbox(prevAcc, messageHash)
        );

        uint256 startNum = messageCount;
        includeDelayedMessages(_totalDelayedMessagesRead);
        emit DelayedInboxForced(startNum, _totalDelayedMessagesRead);
    }

    function addSequencerL2BatchFromOrigin(
        bytes calldata transactions,
        uint256[] calldata lengths,
        uint256 l1BlockNumber,
        uint256 timestamp,
        uint256 _totalDelayedMessagesRead
    ) external {
        // solhint-disable-next-line avoid-tx-origin
        require(msg.sender == tx.origin, "origin only");
        uint256 startNum = messageCount;
        addSequencerL2BatchImpl(
            transactions,
            lengths,
            l1BlockNumber,
            timestamp,
            _totalDelayedMessagesRead
        );
        emit SequencerBatchDeliveredFromOrigin(startNum);
    }

    function addSequencerL2Batch(
        bytes calldata transactions,
        uint256[] calldata lengths,
        uint256 l1BlockNumber,
        uint256 timestamp,
        uint256 _totalDelayedMessagesRead
    ) external {
        uint256 startNum = messageCount;
        addSequencerL2BatchImpl(
            transactions,
            lengths,
            l1BlockNumber,
            timestamp,
            _totalDelayedMessagesRead
        );
        emit SequencerBatchDelivered(
            startNum,
            transactions,
            lengths,
            l1BlockNumber,
            timestamp,
            _totalDelayedMessagesRead
        );
    }

    function addSequencerL2BatchImpl(
        bytes calldata transactions,
        uint256[] calldata lengths,
        uint256 l1BlockNumber,
        uint256 timestamp,
        uint256 _totalDelayedMessagesRead
    ) private {
        require(msg.sender == sequencer, "ONLY_SEQUENCER");
        require(l1BlockNumber + maxDelayBlocks >= block.number, "BLOCK_TOO_OLD");
        require(l1BlockNumber <= block.number, "BLOCK_TOO_NEW");
        require(timestamp + maxDelaySeconds >= block.timestamp, "TIME_TOO_OLD");
        require(timestamp <= block.timestamp, "TIME_TOO_NEW");
        require(_totalDelayedMessagesRead >= totalDelayedMessagesRead);

        (bytes32 prevAcc, uint256 count) = includeDelayedMessages(_totalDelayedMessagesRead);

        uint256 offset = 0;
        for (uint256 i = 0; i < lengths.length; i++) {
            bytes32 messageDataHash = keccak256(bytes(transactions[offset:offset + lengths[i]]));
            bytes32 messageHash =
                Messages.messageHash(
                    L2_MSG,
                    msg.sender,
                    l1BlockNumber,
                    timestamp, // solhint-disable-line not-rely-on-time
                    count,
                    tx.gasprice,
                    messageDataHash
                );
            prevAcc = Messages.addMessageToInbox(prevAcc, messageHash);
            offset += lengths[i];
            count++;
        }
        inboxAccs.push(prevAcc);
        messageCount = count;
    }

    function includeDelayedMessages(uint256 _totalDelayedMessagesRead)
        private
        returns (bytes32, uint256)
    {
        bytes32 prevAcc = 0;
        if (inboxAccs.length > 0) {
            prevAcc = inboxAccs[inboxAccs.length - 1];
        }
        uint256 count = messageCount;
        if (_totalDelayedMessagesRead > totalDelayedMessagesRead) {
            bytes32 messageHash =
                keccak256(
                    abi.encodePacked(
                        count,
                        _totalDelayedMessagesRead,
                        totalDelayedMessagesRead,
                        delayedInbox.inboxAccs(_totalDelayedMessagesRead - 1)
                    )
                );
            prevAcc = Messages.addMessageToInbox(prevAcc, messageHash);
            count += _totalDelayedMessagesRead - totalDelayedMessagesRead;
            totalDelayedMessagesRead = _totalDelayedMessagesRead;
        }
        return (prevAcc, count);
    }
}
