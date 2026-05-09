# FHEVM Contracts Skill

> Reference for writing correct Solidity contracts using FHEVM / Zama Protocol.
> Read this entire file before writing any contract code.

---

## 1. Development Environment Setup

### Option A — Zama's official Hardhat template (recommended)

```bash
git clone https://github.com/zama-ai/fhevm-hardhat-template my-project
cd my-project
npm install
```

The template ships with correct `hardhat.config.ts`, network configs for Zama devnet, and a mock FHE environment for local testing. Use this as the starting point for every FHEVM project.

### Option B — Add FHEVM to an existing Hardhat project

```bash
npm install fhevm @openzeppelin/contracts
npm install --save-dev @nomicfoundation/hardhat-toolbox typescript ts-node
```

Then update `hardhat.config.ts`:

```typescript
import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.24",
    settings: {
      optimizer: { enabled: true, runs: 200 },
      evmVersion: "cancun",   // REQUIRED — transient storage opcodes
    },
  },
  networks: {
    hardhat: { chainId: 31337 },
    zama: {
      url: process.env.ZAMA_RPC_URL || "https://devnet.zama.ai",
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
      chainId: 9000,
    },
  },
};
export default config;
```

### Option C — Use OpenZeppelin Confidential Contracts base library

```bash
npm install fhevm fhevm-contracts @openzeppelin/contracts
```

This gives access to `ConfidentialERC20`, `ConfidentialERC20Mintable`, and other audited base contracts.

### Verify setup

```bash
npx hardhat compile   # must succeed with 0 errors
npx hardhat test      # runs against local mock FHE (no network needed)
```

---

## 2. Encrypted Types & Declaration

Declare encrypted state variables using `e`-prefixed types:

```solidity
import "fhevm/lib/TFHE.sol";

contract MyContract {
    euint64  private _encryptedBalance;   // token balance
    euint8   private _encryptedVote;      // vote choice (0=no, 1=yes, 2=abstain)
    ebool    private _encryptedFlag;      // boolean condition
    eaddress private _encryptedRecipient; // hidden address
}
```

---

## 3. Input Proofs — What, Why, and How

### What is an input proof?

An input proof is a **Zero-Knowledge proof** that accompanies every user-supplied encrypted value. It proves two things to the contract:

1. The ciphertext is well-formed (not corrupted or fabricated).
2. The user who submitted it actually encrypted it with *their* key — not someone else's ciphertext replayed.

Without an input proof, an attacker could copy another user's ciphertext and submit it as their own input, effectively replaying or forging encrypted values.

### Why are input proofs required?

| Threat | Without proof | With proof |
|---|---|---|
| Ciphertext replay | Attacker reuses Alice's encrypted `1000` as their own deposit | Proof ties ciphertext to submitter's address — reuse fails |
| Forged ciphertext | Attacker submits garbage bytes as a euint64 | Proof verifies well-formedness — malformed input reverts |
| Key mismatch | User submits a ciphertext encrypted under wrong key | Proof verifies encryption was done under the network's KMS public key |

### How to use input proofs in Solidity

```solidity
// CORRECT — einput is the ciphertext handle, inputProof is the ZK proof
function deposit(einput encryptedAmount, bytes calldata inputProof) external {
    // TFHE.asEuint64 verifies the proof on-chain before accepting the value
    euint64 amount = TFHE.asEuint64(encryptedAmount, inputProof);
    TFHE.allowThis(amount);
    _encryptedBalance = TFHE.add(_encryptedBalance, amount);
    TFHE.allowThis(_encryptedBalance);
}

// WRONG — accepts raw euint64, bypasses proof validation entirely
function deposit(euint64 amount) external { ... } // ❌ forgeable
```

### How fhevmjs generates input proofs (client side)

```typescript
const instance = await getFhevmInstance();
const input = instance.createEncryptedInput(contractAddress, userAddress);
input.add64(1000n);                             // encrypt the value
const { handles, inputProof } = await input.encrypt(); // proof generated here

// Both handles[0] AND inputProof are required — never omit inputProof
await contract.deposit(handles[0], inputProof);
```

`input.encrypt()` calls Zama's KMS to generate the ZK proof. It is async and must be awaited.

### One inputProof per transaction (covers multiple inputs)

```typescript
const input = instance.createEncryptedInput(contractAddress, userAddress);
input.add64(transferAmount);   // first euint64
input.add8(someFlag);          // second euint8
const { handles, inputProof } = await input.encrypt();
// Single inputProof covers all values in the same encrypt() call
await contract.transfer(recipient, handles[0], handles[1], inputProof);
```

---

## 4. FHE Operations

### Arithmetic

```solidity
euint64 a = ...; euint64 b = ...;

euint64 sum  = TFHE.add(a, b);
euint64 diff = TFHE.sub(a, b);   // wraps on underflow — guard with comparison first
euint64 prod = TFHE.mul(a, b);
euint64 div  = TFHE.div(a, 4);   // only plaintext divisor supported
euint64 rem  = TFHE.rem(a, 10);  // only plaintext modulus supported
euint64 neg  = TFHE.neg(a);

// Always allowThis on any result you store
TFHE.allowThis(sum);
```

### Comparison (returns ebool)

```solidity
ebool gt  = TFHE.gt(a, b);   // a > b
ebool lt  = TFHE.lt(a, b);   // a < b
ebool gte = TFHE.ge(a, b);   // a >= b
ebool lte = TFHE.le(a, b);   // a <= b
ebool eq  = TFHE.eq(a, b);   // a == b
ebool neq = TFHE.ne(a, b);   // a != b

// Compare against plaintext scalar (more gas-efficient)
ebool gtFive = TFHE.gt(a, 5);
ebool eqZero = TFHE.eq(a, 0);
```

### Conditional (cmux / select)

```solidity
// if condition then ifTrue else ifFalse  — all encrypted
euint64 result = TFHE.select(condition, ifTrue, ifFalse);

// Example: clamp subtraction to zero instead of underflow
ebool canSubtract = TFHE.ge(balance, amount);
euint64 newBalance = TFHE.select(canSubtract, TFHE.sub(balance, amount), balance);
TFHE.allowThis(newBalance);
```

### Boolean logic

```solidity
ebool a = ...; ebool b = ...;

ebool andResult = TFHE.and(a, b);
ebool orResult  = TFHE.or(a, b);
ebool xorResult = TFHE.xor(a, b);
ebool notResult = TFHE.not(a);
```

### Bitwise operations

```solidity
euint64 shifted = TFHE.shl(value, 3);   // left shift by plaintext
euint64 rshifted = TFHE.shr(value, 2);  // right shift by plaintext
euint64 bitAnd = TFHE.and(a, b);        // bitwise AND (euint types)
euint64 bitOr  = TFHE.or(a, b);         // bitwise OR
euint64 bitXor = TFHE.xor(a, b);        // bitwise XOR
```

### Type conversion

```solidity
euint8  small  = TFHE.asEuint8(myEuint64);   // narrowing — may overflow
euint64 bigger = TFHE.asEuint64(myEuint8);   // widening — safe
ebool   flag   = TFHE.asEbool(myEuint8);     // nonzero → true
```

---

## 5. Access Control — CRITICAL

Every ciphertext handle must be explicitly authorized. Without this, no one can use the value.

```solidity
// Grant the contract itself access (required to store and use the value later)
TFHE.allowThis(ciphertext);

// Grant a specific address permanent access (e.g., a user who should be able to decrypt)
TFHE.allow(ciphertext, userAddress);

// Grant transient access (valid only for the current transaction — use for callbacks)
TFHE.allowTransient(ciphertext, address(gateway));

// Check if an address is authorized
bool canAccess = TFHE.isAllowed(ciphertext, someAddress);
```

### Access control checklist

After EVERY operation that produces a ciphertext:
- [ ] Call `TFHE.allowThis(result)` if storing in contract state
- [ ] Call `TFHE.allow(result, userAddress)` if the user needs to re-encrypt/decrypt it
- [ ] Call `TFHE.allowTransient(result, gatewayAddress)` before requesting decryption

---

## 6. Public Decryption via Gateway

Use the Gateway for public/admin decryption. It is asynchronous (callback-based).

```solidity
import "fhevm/lib/TFHE.sol";
import "fhevm/gateway/GatewayCaller.sol";

contract VotingResults is GatewayCaller {
    uint64 public decryptedTally;
    euint64 private _encryptedTally;

    function requestReveal() external {
        TFHE.allowTransient(_encryptedTally, address(Gateway));

        uint256[] memory cts = new uint256[](1);
        cts[0] = Gateway.toUint256(_encryptedTally);

        // last param: false = non-trustless (faster), true = trustless
        Gateway.requestDecryption(
            cts,
            this.revealCallback.selector,
            0,                        // msg.value for callback gas
            block.timestamp + 100,    // deadline
            false
        );
    }

    // Gateway calls this after decryption
    function revealCallback(uint256 /*requestID*/, uint64 result) external onlyGateway {
        decryptedTally = result;
    }
}
```

---

## 7. User Re-encryption (EIP-712)

Users decrypt their own data client-side using a keypair + EIP-712 signature. No Solidity changes needed — the contract just needs to call `TFHE.allow(handle, userAddress)`.

```solidity
function getMyBalance() external view returns (euint64) {
    // Return the handle — user decrypts client-side via fhevmjs
    return _encryptedBalances[msg.sender];
}
// In the constructor or after writing: TFHE.allow(_encryptedBalances[msg.sender], msg.sender);
```

---

## 8. Null / Initialization Checks

```solidity
// CORRECT — use TFHE.isInitialized
require(TFHE.isInitialized(_encryptedBalance), "Balance not set");

// WRONG — encrypted values are NOT comparable to zero directly
require(_encryptedBalance != 0, "..."); // ❌ meaningless — it's a handle
```

---

## 9. OpenZeppelin Confidential Contracts

Zama ships an audited base-contract library. Use it instead of writing from scratch.

```bash
npm install fhevm-contracts
```

```solidity
import "fhevm-contracts/contracts/token/ERC20/ConfidentialERC20.sol";

contract MyToken is ConfidentialERC20 {
    constructor() ConfidentialERC20("MyToken", "MTK") {
        _mint(msg.sender, 1_000_000);
    }
}
```

`ConfidentialERC20` already implements:
- Encrypted balances (`euint64`)
- `transfer`, `transferFrom`, `approve` with `einput + inputProof`
- Correct `TFHE.allowThis` and `TFHE.allow` on every state write
- ERC-7984-compatible interface

Other available base contracts:
- `ConfidentialERC20Mintable` — adds `mint(address, uint64)`
- `ConfidentialERC20Burnable` — adds `burn(einput, bytes)`
- `ConfidentialERC20Votes` — governance voting with encrypted balances

---

## 10. ERC-7984 — Full Custom Implementation + ERC-20 Wrapping

ERC-7984 is the encrypted ERC-20 standard. Balances are `euint64` handles.

### Wrapping: ERC-20 → ERC-7984

A wrap contract accepts plaintext ERC-20 tokens and mints an equivalent encrypted balance. The user's ERC-20 balance is publicly visible; the ERC-7984 balance is encrypted.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "fhevm/lib/TFHE.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract ERC20Wrapper {
    using SafeERC20 for IERC20;

    IERC20  public immutable underlying;   // the plain ERC-20 token
    mapping(address => euint64) private _encryptedBalances;

    event Wrapped(address indexed account, uint64 amount);
    event Unwrapped(address indexed account, uint64 amount);

    constructor(address _underlying) {
        underlying = IERC20(_underlying);
    }

    /// @notice Wrap plaintext ERC-20 into encrypted ERC-7984 balance.
    /// @param amount Plaintext amount to wrap (pulled from caller's ERC-20 balance).
    function wrap(uint64 amount) external {
        // Pull ERC-20 tokens from caller — requires prior approve()
        underlying.safeTransferFrom(msg.sender, address(this), amount);

        // Mint encrypted equivalent
        euint64 encrypted = TFHE.asEuint64(amount);
        _encryptedBalances[msg.sender] = TFHE.isInitialized(_encryptedBalances[msg.sender])
            ? TFHE.add(_encryptedBalances[msg.sender], encrypted)
            : encrypted;

        TFHE.allowThis(_encryptedBalances[msg.sender]);
        TFHE.allow(_encryptedBalances[msg.sender], msg.sender);

        emit Wrapped(msg.sender, amount);
    }

    /// @notice Unwrap encrypted balance back to plaintext ERC-20.
    ///         Uses Gateway decryption — plaintext amount revealed on-chain.
    function requestUnwrap(uint64 plainAmount) external {
        // Caller declares how much they want to unwrap (plaintext)
        // Contract checks encrypted balance >= plainAmount using FHE
        euint64 bal = _encryptedBalances[msg.sender];
        require(TFHE.isInitialized(bal), "No balance");

        euint64 amount   = TFHE.asEuint64(plainAmount);
        ebool   hasFunds = TFHE.ge(bal, amount);
        euint64 newBal   = TFHE.select(hasFunds, TFHE.sub(bal, amount), bal);

        _encryptedBalances[msg.sender] = newBal;
        TFHE.allowThis(newBal);
        TFHE.allow(newBal, msg.sender);

        // Transfer plaintext ERC-20 back to caller
        // (safe because caller declared the amount — no on-chain decryption needed)
        underlying.safeTransfer(msg.sender, plainAmount);
        emit Unwrapped(msg.sender, plainAmount);
    }

    function balanceOf(address account) external view returns (euint64) {
        return _encryptedBalances[account];
    }
}
```

### Key wrapping rules

- `wrap()` accepts a **plaintext** amount — the ERC-20 transfer is public, but the resulting encrypted balance is hidden.
- `unwrap()` with a **declared plaintext** amount is the simplest pattern (user decides how much). For fully private unwrapping, use Gateway decryption.
- Always `TFHE.allowThis` + `TFHE.allow(_, msg.sender)` on the resulting encrypted balance.

---

## 11. Full Custom ERC-7984 Token (from scratch)

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "fhevm/lib/TFHE.sol";
import "fhevm/gateway/GatewayCaller.sol";

contract ConfidentialERC7984 is GatewayCaller {
    mapping(address => euint64) private _encryptedBalances;
    mapping(address => mapping(address => euint64)) private _encryptedAllowances;

    string public name;
    string public symbol;
    uint64 private _totalSupply;

    event Transfer(address indexed from, address indexed to);
    event Approval(address indexed owner, address indexed spender);

    constructor(string memory _name, string memory _symbol, uint64 initialSupply) {
        name = _name;
        symbol = _symbol;
        _totalSupply = initialSupply;

        euint64 supply = TFHE.asEuint64(initialSupply);
        _encryptedBalances[msg.sender] = supply;
        TFHE.allowThis(supply);
        TFHE.allow(supply, msg.sender);
    }

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

        euint64 currentAllowance = _encryptedAllowances[from][msg.sender];
        ebool sufficient = TFHE.ge(currentAllowance, amount);
        euint64 newAllowance = TFHE.select(sufficient, TFHE.sub(currentAllowance, amount), currentAllowance);

        _encryptedAllowances[from][msg.sender] = newAllowance;
        TFHE.allowThis(newAllowance);
        TFHE.allow(newAllowance, from);
        TFHE.allow(newAllowance, msg.sender);

        _transfer(from, to, amount);
        return true;
    }

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

    function balanceOf(address account) external view returns (euint64) {
        return _encryptedBalances[account];
    }

    function _transfer(address from, address to, euint64 amount) internal {
        euint64 fromBalance = _encryptedBalances[from];

        // Guard against underflow: only subtract if balance is sufficient
        ebool sufficient = TFHE.ge(fromBalance, amount);
        euint64 newFromBalance = TFHE.select(sufficient, TFHE.sub(fromBalance, amount), fromBalance);
        euint64 newToBalance   = TFHE.select(sufficient, TFHE.add(_encryptedBalances[to], amount), _encryptedBalances[to]);

        _encryptedBalances[from] = newFromBalance;
        _encryptedBalances[to]   = newToBalance;

        TFHE.allowThis(newFromBalance); TFHE.allow(newFromBalance, from);
        TFHE.allowThis(newToBalance);   TFHE.allow(newToBalance, to);

        emit Transfer(from, to);
    }
}
```

---

## 12. Common Anti-Patterns (AI agent must avoid these)

| Anti-pattern | Why it breaks | Fix |
|---|---|---|
| `return decryptedValue` in view | Values are handles — not readable as-is | Return `euint64` handle; user decrypts client-side |
| Missing `TFHE.allowThis(result)` | Contract loses access to its own ciphertext | Add after every FHE operation |
| `require(encryptedVal > 0)` | Handle is a uint256 pointer, not the value | Use `TFHE.isInitialized()` |
| `TFHE.decrypt()` in a transaction | Not allowed — decrypt only via Gateway callback or view with re-encryption | Use `Gateway.requestDecryption()` |
| Accepting `euint64` as function param | Bypasses proof validation — attacker can forge | Always use `einput` + `bytes calldata inputProof` |
| Storing result without `allowThis` | Next transaction can't access the handle | Always `TFHE.allowThis(result)` before storing |
| FHE ops inside `for` loops | Gas cost is O(n) and FHE ops are expensive | Precompute or batch off-chain |
| Using `==` on ciphertexts | Compares handles, not values | Use `TFHE.eq(a, b)` which returns `ebool` |
