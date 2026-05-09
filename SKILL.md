# PrivyStack — FHEVM Agent Skill

> **Instruction for AI coding agents:** Read this file completely before writing any FHEVM contract,
> test, or frontend code. Then load the relevant sub-skill file listed in §1 before generating output.

---

## §1 — Sub-Skill Routing

Load the sub-skill that matches the developer's request. Do not skip this step.

| Developer asks about | Load this file |
|---|---|
| Solidity contracts, encrypted types, FHE operations, access control, ERC-7984, Gateway decryption | [`skills/fhevm-contracts.md`](skills/fhevm-contracts.md) |
| Hardhat setup, writing tests, mocking FHE, deploying to Zama devnet | [`skills/fhevm-testing.md`](skills/fhevm-testing.md) |
| fhevmjs, encrypting values in the browser, EIP-712 user decryption, wagmi integration | [`skills/fhevm-frontend.md`](skills/fhevm-frontend.md) |

Copy-paste ready templates live in [`templates/`](templates/). Compiled and tested examples live in [`examples/`](examples/).

---

## §2 — FHEVM Architecture

**Fully Homomorphic Encryption Virtual Machine (FHEVM)** by Zama enables smart contracts to compute on encrypted data without ever decrypting it on-chain.

```
Browser (fhevmjs)
  │  createEncryptedInput(contract, user) → input.add64(value) → { handles, inputProof }
  ▼
Smart Contract
  │  TFHE.asEuint64(handle, inputProof)    ← decode + verify ZK proof
  │  TFHE.add(a, b)                        ← FHE arithmetic
  │  TFHE.gt(a, b)  →  ebool              ← FHE comparison
  │  TFHE.select(cond, x, y)              ← FHE conditional (no branching)
  │  TFHE.allowThis(result)               ← REQUIRED: re-authorize after every op
  │  TFHE.allow(result, userAddress)      ← grant user re-encryption access
  ▼
Zama Gateway (decryption oracle)
  │  Gateway.requestDecryption(handles, callback.selector, ...)
  │  → async → callback(requestId, plaintext1, plaintext2, ...)
  ▼
Public state OR user re-encryption via EIP-712
```

Key constraint: **encrypted values are never readable on-chain.** Public results come through the Gateway callback. Private results come through client-side re-encryption.

---

## §3 — The 6 Rules That Must Never Be Broken

> Violating any one of these produces code that reverts, silently corrupts state, or leaks private data.

---

### Rule 1 — User-supplied encrypted values require `einput` + `inputProof`

The `inputProof` is a ZK proof that the ciphertext is valid, belongs to the correct user, and targets the correct contract. Without it, anyone can submit forged or replayed ciphertexts.

```solidity
// ✅ CORRECT
function vote(einput encryptedChoice, bytes calldata inputProof) external {
    euint8 choice = TFHE.asEuint8(encryptedChoice, inputProof);
}

// ❌ WRONG — no proof, attacker can replay or forge ciphertexts
function vote(euint8 choice) external { ... }
```

---

### Rule 2 — Call `TFHE.allowThis(result)` after every FHE operation

Each FHE operation produces a new ciphertext handle. The contract loses access to that handle at the end of the transaction unless `allowThis` is called. Omitting it causes silent state corruption on the next interaction.

```solidity
// ✅ CORRECT
euint64 newBalance = TFHE.add(balance, amount);
TFHE.allowThis(newBalance);           // re-authorize the contract
_balances[msg.sender] = newBalance;

// ❌ WRONG — contract cannot read newBalance in the next transaction
euint64 newBalance = TFHE.add(balance, amount);
_balances[msg.sender] = newBalance;
```

---

### Rule 3 — View functions must return the encrypted handle, not a cast

`euint64` is a `uint256` ciphertext handle, not a numeric value. Casting it to `uint64` returns garbage — the raw pointer, not the balance.

```solidity
// ✅ CORRECT — caller decrypts client-side via fhevmjs reencrypt()
function balanceOf(address account) external view returns (euint64) {
    return _balances[account];
}

// ❌ WRONG — returns the handle value (a uint256 pointer), not the balance
function balanceOf(address account) external view returns (uint64) {
    return uint64(_balances[account]);
}
```

---

### Rule 4 — Public decryption must go through Gateway, not `TFHE.decrypt()`

`TFHE.decrypt()` does not exist in transactions. Public reveal requires an async request to the Zama Gateway, which calls back with the plaintext.

```solidity
// ✅ CORRECT
function revealResults() external {
    TFHE.allowTransient(_encryptedTally, address(Gateway));
    uint256[] memory cts = new uint256[](1);
    cts[0] = Gateway.toUint256(_encryptedTally);
    Gateway.requestDecryption(cts, this.revealCallback.selector, 0, block.timestamp + 100, false);
}

function revealCallback(uint256 /*requestId*/, uint64 result) external onlyGateway {
    publicTally = result;
}

// ❌ WRONG — reverts; TFHE.decrypt() cannot be called in a transaction
uint64 tally = TFHE.decrypt(_encryptedTally);
```

---

### Rule 5 — Never use encrypted values in `require()` conditions

An encrypted value is a ciphertext handle (a `uint256`). Comparing it with `> 0` always evaluates the handle, not the underlying value — the result is meaningless or always true.

```solidity
// ✅ CORRECT — check initialization, not value
require(TFHE.isInitialized(_balance), "Balance not set");

// ❌ WRONG — evaluates the handle (always non-zero once set)
require(_balance > 0, "Insufficient balance");
```

---

### Rule 6 — Grant access to every party that needs the ciphertext

Three access methods exist for three different purposes. Using the wrong one (or omitting one) causes access denied on re-encryption or Gateway decryption.

```solidity
TFHE.allowThis(ct);                    // contract retains access across transactions
TFHE.allow(ct, userAddress);           // user can re-encrypt it via EIP-712
TFHE.allowTransient(ct, address(Gateway)); // required immediately before requestDecryption
```

---

## §4 — Encrypted Type Reference

| Type | Size | Typical use |
|---|---|---|
| `ebool` | 1 bit | Conditions, flags, access checks |
| `euint8` | 8 bits | Votes, small enums, ratings (0–255) |
| `euint16` | 16 bits | Scores, counters |
| `euint32` | 32 bits | Timestamps, medium counters |
| `euint64` | 64 bits | Token balances, transfer amounts |
| `euint128` | 128 bits | Large token amounts |
| `euint256` | 256 bits | Arbitrary precision values |
| `eaddress` | 160 bits | Hidden recipient or owner addresses |
| `einput` | — | External parameter type — always paired with `bytes calldata inputProof` |

---

## §5 — Required Solidity Imports

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "fhevm/lib/TFHE.sol";

// Required only when using Gateway for public decryption:
import "fhevm/gateway/GatewayCaller.sol";
```

`hardhat.config.ts` must set `evmVersion: "cancun"`. This is non-negotiable — FHEVM uses EVM opcodes introduced in Cancun.

---

## §6 — Anti-Patterns and Correct Replacements

| Anti-pattern | Why it fails | Correct pattern |
|---|---|---|
| `function f(euint64 amount) external` | No ZK proof — forged ciphertexts accepted | `function f(einput amount, bytes calldata proof) external` |
| No `TFHE.allowThis()` after FHE op | Contract loses handle access next transaction | `TFHE.allowThis(result)` immediately after every op |
| `require(encryptedVal > 0)` | Evaluates the handle pointer, not the value | `require(TFHE.isInitialized(encryptedVal))` |
| `TFHE.decrypt(x)` in a transaction | Function does not exist in txs — reverts | `Gateway.requestDecryption(...)` + callback |
| `return uint64(encryptedBalance)` | Returns the handle pointer as a number | Return `euint64`; user decrypts via `fhevmjs.reencrypt()` |
| `TFHE.sub(a, b)` without a guard | Underflow wraps silently — no revert | `TFHE.select(TFHE.ge(a, b), TFHE.sub(a, b), a)` |
| FHE operations inside a `for` loop | Each op is an on-chain FHE call — prohibitively expensive | Precompute or batch inputs off-chain |
| Missing `TFHE.allowTransient` before `requestDecryption` | Gateway access denied — decryption request fails | `TFHE.allowTransient(ct, address(Gateway))` first |

---

## §7 — Quick Start: Prompt → Pattern → Output

### "Write me a confidential voting contract using FHEVM"

**Sub-skill to load:** `skills/fhevm-contracts.md` → §3, §4, §5, §6

**Patterns to apply:**
- `vote(einput encryptedChoice, bytes calldata inputProof)` — never `vote(euint8 choice)`
- `TFHE.asEuint8(encryptedChoice, inputProof)` to decode the vote
- `TFHE.eq(choice, 1)` + `TFHE.select(...)` to branch conditionally on an encrypted value
- `TFHE.allowThis(...)` after every tally update
- `TFHE.allowTransient(...)` + `Gateway.requestDecryption(...)` + `onlyGateway` callback to reveal results

**Reference output:** [`templates/ConfidentialVoting.sol`](templates/ConfidentialVoting.sol)

---

### "Build a confidential ERC-7984 token with encrypted balances"

**Sub-skill to load:** `skills/fhevm-contracts.md` → §9, §10, §11

**Patterns to apply:**
- `mapping(address => euint64) private _encryptedBalances`
- `transfer(address to, einput encryptedAmount, bytes calldata inputProof)` — never `transfer(address, uint64)`
- Underflow guard: `TFHE.select(TFHE.ge(fromBal, amount), TFHE.sub(fromBal, amount), fromBal)`
- `balanceOf()` returns `euint64` handle — the caller decrypts client-side
- `TFHE.allowThis(balance)` + `TFHE.allow(balance, userAddress)` after every balance write

**Reference output:** [`templates/ConfidentialToken.sol`](templates/ConfidentialToken.sol)

---

### "Show me how to encrypt a transfer amount in the frontend"

**Sub-skill to load:** `skills/fhevm-frontend.md` → §2, §3, §4

**Patterns to apply:**
- `createInstance({ kmsContractAddress, aclContractAddress, network, gatewayUrl })` — once at app startup
- `instance.createEncryptedInput(contractAddress, userAddress)` → `input.add64(amount)` → `await input.encrypt()`
- Pass `handles[0]` and `inputProof` to the contract call — both are required
- User balance read: `generateKeypair` → `createEIP712` → `signTypedData` → `reencrypt(handle, ...)`

**Reference output:** [`templates/frontend-snippet.ts`](templates/frontend-snippet.ts)

---

## §8 — External References

| Resource | URL |
|---|---|
| Zama FHEVM documentation | https://docs.zama.ai/fhevm |
| fhevmjs (client-side library) | https://github.com/zama-ai/fhevmjs |
| Hardhat project template | https://github.com/zama-ai/fhevm-hardhat-template |
| OpenZeppelin Confidential Contracts | https://github.com/zama-ai/fhevm-contracts |
| ERC-7984 specification | https://eips.ethereum.org/EIPS/eip-7984 |
| Zama devnet faucet | https://faucet.zama.ai |
| Zama devnet explorer | https://explorer.devnet.zama.ai |
