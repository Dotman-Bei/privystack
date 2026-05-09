// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "fhevm/lib/TFHE.sol";
import "fhevm/gateway/GatewayCaller.sol";

/// @title Confidential Voting — FHEVM template
/// Votes are encrypted; only the final tally is revealed after voting ends.
contract ConfidentialVoting is GatewayCaller {
    string  public  question;
    uint256 public  deadline;
    bool    public  resultsRevealed;

    uint64  public  yesCount;
    uint64  public  noCount;
    uint64  public  abstainCount;

    euint64 private _encryptedYes;
    euint64 private _encryptedNo;
    euint64 private _encryptedAbstain;

    mapping(address => bool) public hasVoted;

    event VoteCast(address indexed voter);
    event ResultsRequested();
    event ResultsRevealed(uint64 yes, uint64 no, uint64 abstain);

    error AlreadyVoted();
    error VotingClosed();
    error VotingStillOpen();
    error ResultsAlreadyRevealed();

    constructor(string memory _question, uint256 _durationSeconds) {
        question = _question;
        deadline = block.timestamp + _durationSeconds;

        // Initialize tallies to 0
        _encryptedYes     = TFHE.asEuint64(0);
        _encryptedNo      = TFHE.asEuint64(0);
        _encryptedAbstain = TFHE.asEuint64(0);

        TFHE.allowThis(_encryptedYes);
        TFHE.allowThis(_encryptedNo);
        TFHE.allowThis(_encryptedAbstain);
    }

    /// @param encryptedChoice Encrypted vote: 1=YES, 0=NO, 2=ABSTAIN
    /// @param inputProof ZK proof that encryptedChoice is a valid euint8
    function vote(einput encryptedChoice, bytes calldata inputProof) external {
        if (block.timestamp > deadline) revert VotingClosed();
        if (hasVoted[msg.sender])       revert AlreadyVoted();

        hasVoted[msg.sender] = true;

        euint8 choice = TFHE.asEuint8(encryptedChoice, inputProof);

        // Increment the corresponding tally using conditional addition
        // YES:     choice == 1 → add 1 to _encryptedYes
        // NO:      choice == 0 → add 1 to _encryptedNo
        // ABSTAIN: choice == 2 → add 1 to _encryptedAbstain
        ebool isYes     = TFHE.eq(choice, 1);
        ebool isNo      = TFHE.eq(choice, 0);
        ebool isAbstain = TFHE.eq(choice, 2);

        euint64 yesVote     = TFHE.select(isYes,     TFHE.asEuint64(1), TFHE.asEuint64(0));
        euint64 noVote      = TFHE.select(isNo,      TFHE.asEuint64(1), TFHE.asEuint64(0));
        euint64 abstainVote = TFHE.select(isAbstain, TFHE.asEuint64(1), TFHE.asEuint64(0));

        _encryptedYes     = TFHE.add(_encryptedYes,     yesVote);
        _encryptedNo      = TFHE.add(_encryptedNo,      noVote);
        _encryptedAbstain = TFHE.add(_encryptedAbstain, abstainVote);

        TFHE.allowThis(_encryptedYes);
        TFHE.allowThis(_encryptedNo);
        TFHE.allowThis(_encryptedAbstain);

        emit VoteCast(msg.sender);
    }

    /// Request public decryption of the final tally via Zama Gateway
    function revealResults() external {
        if (block.timestamp <= deadline)  revert VotingStillOpen();
        if (resultsRevealed)              revert ResultsAlreadyRevealed();

        TFHE.allowTransient(_encryptedYes,     address(Gateway));
        TFHE.allowTransient(_encryptedNo,      address(Gateway));
        TFHE.allowTransient(_encryptedAbstain, address(Gateway));

        uint256[] memory cts = new uint256[](3);
        cts[0] = Gateway.toUint256(_encryptedYes);
        cts[1] = Gateway.toUint256(_encryptedNo);
        cts[2] = Gateway.toUint256(_encryptedAbstain);

        Gateway.requestDecryption(cts, this.revealCallback.selector, 0, block.timestamp + 100, false);
        emit ResultsRequested();
    }

    /// Called by Zama Gateway after decryption
    function revealCallback(
        uint256 /*requestID*/,
        uint64 _yes,
        uint64 _no,
        uint64 _abstain
    ) external onlyGateway {
        yesCount     = _yes;
        noCount      = _no;
        abstainCount = _abstain;
        resultsRevealed = true;
        emit ResultsRevealed(_yes, _no, _abstain);
    }
}
