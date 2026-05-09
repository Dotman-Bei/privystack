// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "fhevm/lib/TFHE.sol";
import "fhevm/gateway/GatewayCaller.sol";

/// @title ConfidentialVoting
/// @notice On-chain voting where individual choices stay encrypted forever.
///         Only the aggregate tally is revealed after the voting period ends.
contract ConfidentialVoting is GatewayCaller {

    // ─── State ────────────────────────────────────────────────────────────────

    string  public  question;
    uint256 public  deadline;
    address public  owner;
    bool    public  resultsRevealed;

    // Public tallies — populated after Gateway decryption callback
    uint64  public  yesCount;
    uint64  public  noCount;
    uint64  public  abstainCount;

    // Encrypted running tallies
    euint64 private _encryptedYes;
    euint64 private _encryptedNo;
    euint64 private _encryptedAbstain;

    mapping(address => bool) public hasVoted;

    // ─── Events ───────────────────────────────────────────────────────────────

    event VoteCast(address indexed voter);
    event ResultsRequested(uint256 timestamp);
    event ResultsRevealed(uint64 yes, uint64 no, uint64 abstain);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error AlreadyVoted();
    error VotingClosed();
    error VotingStillOpen();
    error ResultsAlreadyRevealed();
    error OnlyOwner();

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(string memory _question, uint256 _durationSeconds) {
        question = _question;
        deadline = block.timestamp + _durationSeconds;
        owner    = msg.sender;

        _encryptedYes     = TFHE.asEuint64(0);
        _encryptedNo      = TFHE.asEuint64(0);
        _encryptedAbstain = TFHE.asEuint64(0);

        TFHE.allowThis(_encryptedYes);
        TFHE.allowThis(_encryptedNo);
        TFHE.allowThis(_encryptedAbstain);
    }

    // ─── Voting ───────────────────────────────────────────────────────────────

    /// @notice Cast an encrypted vote.
    /// @param encryptedChoice Encrypted euint8: 1=YES, 0=NO, 2=ABSTAIN
    /// @param inputProof      ZK proof validating encryptedChoice
    function vote(einput encryptedChoice, bytes calldata inputProof) external {
        if (block.timestamp > deadline) revert VotingClosed();
        if (hasVoted[msg.sender])       revert AlreadyVoted();

        hasVoted[msg.sender] = true;

        euint8 choice = TFHE.asEuint8(encryptedChoice, inputProof);

        ebool isYes     = TFHE.eq(choice, 1);
        ebool isNo      = TFHE.eq(choice, 0);
        ebool isAbstain = TFHE.eq(choice, 2);

        euint64 yesIncrement     = TFHE.select(isYes,     TFHE.asEuint64(1), TFHE.asEuint64(0));
        euint64 noIncrement      = TFHE.select(isNo,      TFHE.asEuint64(1), TFHE.asEuint64(0));
        euint64 abstainIncrement = TFHE.select(isAbstain, TFHE.asEuint64(1), TFHE.asEuint64(0));

        _encryptedYes     = TFHE.add(_encryptedYes,     yesIncrement);
        _encryptedNo      = TFHE.add(_encryptedNo,      noIncrement);
        _encryptedAbstain = TFHE.add(_encryptedAbstain, abstainIncrement);

        TFHE.allowThis(_encryptedYes);
        TFHE.allowThis(_encryptedNo);
        TFHE.allowThis(_encryptedAbstain);

        emit VoteCast(msg.sender);
    }

    // ─── Reveal ───────────────────────────────────────────────────────────────

    /// @notice Request public decryption of final tally via Zama Gateway.
    ///         Anyone can call after voting ends.
    function revealResults() external {
        if (block.timestamp <= deadline) revert VotingStillOpen();
        if (resultsRevealed)             revert ResultsAlreadyRevealed();

        TFHE.allowTransient(_encryptedYes,     address(Gateway));
        TFHE.allowTransient(_encryptedNo,      address(Gateway));
        TFHE.allowTransient(_encryptedAbstain, address(Gateway));

        uint256[] memory cts = new uint256[](3);
        cts[0] = Gateway.toUint256(_encryptedYes);
        cts[1] = Gateway.toUint256(_encryptedNo);
        cts[2] = Gateway.toUint256(_encryptedAbstain);

        Gateway.requestDecryption(cts, this.revealCallback.selector, 0, block.timestamp + 100, false);

        emit ResultsRequested(block.timestamp);
    }

    /// @notice Callback invoked by Zama Gateway with decrypted values.
    function revealCallback(
        uint256 /*requestID*/,
        uint64 _yes,
        uint64 _no,
        uint64 _abstain
    ) external onlyGateway {
        yesCount        = _yes;
        noCount         = _no;
        abstainCount    = _abstain;
        resultsRevealed = true;

        emit ResultsRevealed(_yes, _no, _abstain);
    }

    // ─── View helpers ─────────────────────────────────────────────────────────

    function isActive() external view returns (bool) {
        return block.timestamp <= deadline && !resultsRevealed;
    }

    function timeRemaining() external view returns (uint256) {
        if (block.timestamp >= deadline) return 0;
        return deadline - block.timestamp;
    }
}
