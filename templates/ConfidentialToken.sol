// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "fhevm/lib/TFHE.sol";
import "fhevm/gateway/GatewayCaller.sol";

/// @title Confidential ERC-7984 Token — FHEVM template
/// Balances and transfer amounts are encrypted. Total supply is public.
contract ConfidentialERC7984 is GatewayCaller {
    mapping(address => euint64) private _encryptedBalances;
    mapping(address => mapping(address => euint64)) private _encryptedAllowances;

    string  public name;
    string  public symbol;
    uint8   public decimals = 6;
    uint64  public totalSupply;

    event Transfer(address indexed from, address indexed to);
    event Approval(address indexed owner, address indexed spender);
    event Wrap(address indexed account, uint64 amount);
    event Unwrap(address indexed account, uint64 amount);

    error InsufficientBalance();

    constructor(string memory _name, string memory _symbol, uint64 _initialSupply) {
        name        = _name;
        symbol      = _symbol;
        totalSupply = _initialSupply;

        euint64 supply = TFHE.asEuint64(_initialSupply);
        _encryptedBalances[msg.sender] = supply;
        TFHE.allowThis(supply);
        TFHE.allow(supply, msg.sender);
    }

    // ─── Transfer ────────────────────────────────────────────────────────────

    function transfer(
        address to,
        einput encryptedAmount,
        bytes calldata inputProof
    ) external returns (bool) {
        euint64 amount = TFHE.asEuint64(encryptedAmount, inputProof);
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        einput encryptedAmount,
        bytes calldata inputProof
    ) external returns (bool) {
        euint64 amount = TFHE.asEuint64(encryptedAmount, inputProof);

        // Deduct from allowance (clamped — cannot underflow)
        euint64 allowance  = _encryptedAllowances[from][msg.sender];
        ebool   hasFunds   = TFHE.ge(allowance, amount);
        euint64 newAllowance = TFHE.select(hasFunds, TFHE.sub(allowance, amount), allowance);
        _encryptedAllowances[from][msg.sender] = newAllowance;
        TFHE.allowThis(newAllowance);
        TFHE.allow(newAllowance, from);
        TFHE.allow(newAllowance, msg.sender);

        _transfer(from, to, amount);
        return true;
    }

    // ─── Approve ─────────────────────────────────────────────────────────────

    function approve(
        address spender,
        einput encryptedAmount,
        bytes calldata inputProof
    ) external returns (bool) {
        euint64 amount = TFHE.asEuint64(encryptedAmount, inputProof);
        _encryptedAllowances[msg.sender][spender] = amount;
        TFHE.allowThis(amount);
        TFHE.allow(amount, msg.sender);
        TFHE.allow(amount, spender);
        emit Approval(msg.sender, spender);
        return true;
    }

    // ─── Balance view (returns handle — user decrypts via EIP-712) ───────────

    function balanceOf(address account) external view returns (euint64) {
        return _encryptedBalances[account];
    }

    function allowance(address owner, address spender) external view returns (euint64) {
        return _encryptedAllowances[owner][spender];
    }

    // ─── Wrapping: ERC-20 → ERC-7984 ─────────────────────────────────────────
    // Mint encrypted tokens in exchange for plaintext ERC-20 tokens (simplified)

    function wrap(uint64 plainAmount) external {
        // In production: pull ERC-20 tokens from msg.sender here
        euint64 minted = TFHE.asEuint64(plainAmount);
        _encryptedBalances[msg.sender] = TFHE.add(_encryptedBalances[msg.sender], minted);
        TFHE.allowThis(_encryptedBalances[msg.sender]);
        TFHE.allow(_encryptedBalances[msg.sender], msg.sender);
        totalSupply += plainAmount;
        emit Wrap(msg.sender, plainAmount);
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    function _transfer(address from, address to, euint64 amount) internal {
        euint64 fromBal = _encryptedBalances[from];
        euint64 toBal   = _encryptedBalances[to];

        // Only move funds if sender has enough (avoid underflow silently)
        ebool   ok         = TFHE.ge(fromBal, amount);
        euint64 newFromBal = TFHE.select(ok, TFHE.sub(fromBal, amount), fromBal);
        euint64 newToBal   = TFHE.select(ok, TFHE.add(toBal, amount),   toBal);

        _encryptedBalances[from] = newFromBal;
        _encryptedBalances[to]   = newToBal;

        TFHE.allowThis(newFromBal); TFHE.allow(newFromBal, from);
        TFHE.allowThis(newToBal);   TFHE.allow(newToBal, to);

        emit Transfer(from, to);
    }
}
