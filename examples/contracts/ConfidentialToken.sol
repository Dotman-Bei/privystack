// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "fhevm/lib/TFHE.sol";
import "fhevm/gateway/GatewayCaller.sol";

/// @title ConfidentialToken (ERC-7984)
/// @notice Encrypted ERC-20 token. Balances and transfer amounts are hidden.
///         Total supply is public. Users decrypt their own balance via EIP-712.
contract ConfidentialToken is GatewayCaller {

    // ─── State ────────────────────────────────────────────────────────────────

    string  public name;
    string  public symbol;
    uint8   public constant decimals = 6;
    uint64  public totalSupply;
    address public owner;

    mapping(address => euint64) private _balances;
    mapping(address => mapping(address => euint64)) private _allowances;

    // ─── Events ───────────────────────────────────────────────────────────────

    event Transfer(address indexed from, address indexed to);
    event Approval(address indexed owner, address indexed spender);
    event Mint(address indexed to, uint64 amount);
    event Wrap(address indexed account, uint64 amount);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error OnlyOwner();

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(string memory _name, string memory _symbol, uint64 _initialSupply) {
        name        = _name;
        symbol      = _symbol;
        totalSupply = _initialSupply;
        owner       = msg.sender;

        euint64 supply = TFHE.asEuint64(_initialSupply);
        _balances[msg.sender] = supply;
        TFHE.allowThis(supply);
        TFHE.allow(supply, msg.sender);

        emit Mint(msg.sender, _initialSupply);
    }

    // ─── ERC-7984 Transfer ────────────────────────────────────────────────────

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
        euint64 amount     = TFHE.asEuint64(encryptedAmount, inputProof);
        euint64 currentAllowance = _allowances[from][msg.sender];

        ebool   hasFunds      = TFHE.ge(currentAllowance, amount);
        euint64 newAllowance  = TFHE.select(hasFunds, TFHE.sub(currentAllowance, amount), currentAllowance);

        _allowances[from][msg.sender] = newAllowance;
        TFHE.allowThis(newAllowance);
        TFHE.allow(newAllowance, from);
        TFHE.allow(newAllowance, msg.sender);

        _transfer(from, to, amount);
        return true;
    }

    // ─── ERC-7984 Approve ─────────────────────────────────────────────────────

    function approve(
        address spender,
        einput encryptedAmount,
        bytes calldata inputProof
    ) external returns (bool) {
        euint64 amount = TFHE.asEuint64(encryptedAmount, inputProof);
        _allowances[msg.sender][spender] = amount;
        TFHE.allowThis(amount);
        TFHE.allow(amount, msg.sender);
        TFHE.allow(amount, spender);
        emit Approval(msg.sender, spender);
        return true;
    }

    // ─── Balance queries (returns handle — user decrypts via fhevmjs) ─────────

    function balanceOf(address account) external view returns (euint64) {
        return _balances[account];
    }

    function allowance(address _owner, address spender) external view returns (euint64) {
        return _allowances[_owner][spender];
    }

    // ─── Wrap / Mint (owner only for demo) ───────────────────────────────────

    function mint(address to, uint64 plainAmount) external {
        if (msg.sender != owner) revert OnlyOwner();
        euint64 minted = TFHE.asEuint64(plainAmount);
        _balances[to] = TFHE.isInitialized(_balances[to])
            ? TFHE.add(_balances[to], minted)
            : minted;
        TFHE.allowThis(_balances[to]);
        TFHE.allow(_balances[to], to);
        totalSupply += plainAmount;
        emit Mint(to, plainAmount);
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    function _transfer(address from, address to, euint64 amount) internal {
        euint64 fromBal = _balances[from];
        euint64 toBal   = TFHE.isInitialized(_balances[to]) ? _balances[to] : TFHE.asEuint64(0);

        ebool   ok         = TFHE.ge(fromBal, amount);
        euint64 newFromBal = TFHE.select(ok, TFHE.sub(fromBal, amount), fromBal);
        euint64 newToBal   = TFHE.select(ok, TFHE.add(toBal, amount),   toBal);

        _balances[from] = newFromBal;
        _balances[to]   = newToBal;

        TFHE.allowThis(newFromBal); TFHE.allow(newFromBal, from);
        TFHE.allowThis(newToBal);   TFHE.allow(newToBal, to);

        emit Transfer(from, to);
    }
}
