# PrivyStack

A skill pack that gives AI coding agents accurate, up-to-date knowledge of FHEVM development.

Without it, agents hallucinate FHEVM APIs — missing input proofs, skipping `TFHE.allowThis`, calling `TFHE.decrypt()` in transactions. With it, they produce correct, working confidential smart contracts on the first attempt.

Supports **Claude Code**, **Cursor**, and **Windsurf**.

---

## How it works

You copy three things into your project: `SKILL.md`, the `skills/` folder, and `templates/`. You then tell your agent (once) to read `SKILL.md` before writing any FHEVM code. From that point on, every contract, test, and frontend snippet it generates follows the correct Zama patterns.

---

## Complete walkthrough — from zero to deployed

### 1. Create your project folder

```bash
mkdir my-fhevm-project
cd my-fhevm-project
```

---

### 2. Copy PrivyStack into it

```bash
git clone https://github.com/Dotman-Bei/privystack .privystack

cp .privystack/SKILL.md .
cp -r .privystack/skills ./skills
cp -r .privystack/templates ./templates
```

Your folder now looks like this:

```
my-fhevm-project/
├── SKILL.md
├── skills/
│   ├── fhevm-contracts.md
│   ├── fhevm-testing.md
│   └── fhevm-frontend.md
└── templates/
    ├── ConfidentialVoting.sol
    ├── ConfidentialToken.sol
    ├── test-template.ts
    └── frontend-snippet.ts
```

---

### 3. Tell your agent to use the skill

Agents do not read `SKILL.md` on their own. You register it once using a config file in your project root.

**Claude Code** — create `CLAUDE.md`:

```markdown
Before writing any FHEVM contract, test, or frontend code:
1. Read SKILL.md in full.
2. Load the relevant sub-skill from skills/ as directed in SKILL.md §1.
3. Follow every rule in SKILL.md §3 without exception.
```

**Cursor** — create `.cursorrules`:

```
Before writing any FHEVM contract, test, or frontend code,
read SKILL.md and load the relevant skills/*.md file listed in §1.
Follow every rule in §3 without exception.
```

**Windsurf** — create `.windsurfrules` with the same content as above, or reference `@SKILL.md` in any chat message.

Claude Code reads `CLAUDE.md` on every startup. Cursor and Windsurf read their rules files as persistent context on every message.

---

### 4. Initialize a Hardhat project

Open your agent's chat (Claude Code, Cursor, or Windsurf) and type this message:

> Read SKILL.md. Then set up a Hardhat TypeScript project for FHEVM development.
> Install all required dependencies and create hardhat.config.ts with the correct settings.

The agent will read the skill, load `skills/fhevm-testing.md`, and generate:

- `package.json` with the correct dependencies
- `hardhat.config.ts` with `evmVersion: "cancun"` and Zama devnet network config
- `tsconfig.json`
- folder structure: `contracts/`, `test/`, `scripts/`

Then install:

```bash
npm install
```

---

### 5. Write a confidential smart contract

Prompt your agent:

```
Write me a confidential voting contract using FHEVM.
Votes must be encrypted. Only the final tally should be revealed after voting ends.
```

The agent reads the skill and applies these patterns automatically:

- `vote(einput encryptedChoice, bytes calldata inputProof)` — correct parameter signature
- `TFHE.asEuint8(encryptedChoice, inputProof)` — validates the ZK proof before use
- `TFHE.select()` instead of `if/else` — no branching on encrypted values
- `TFHE.allowThis(result)` after every FHE operation — prevents state corruption
- `Gateway.requestDecryption()` + `onlyGateway` callback — correct async reveal flow

The output will be equivalent to [`templates/ConfidentialVoting.sol`](templates/ConfidentialVoting.sol).

For a confidential token instead:

```
Build a confidential ERC-7984 token. Balances and transfer amounts must be encrypted.
Include underflow protection and allow users to decrypt their own balance.
```

Output equivalent to [`templates/ConfidentialToken.sol`](templates/ConfidentialToken.sol).

---

### 6. Write tests

Prompt your agent:

```
Write Hardhat tests for the ConfidentialVoting contract.
Test that a user can vote, that double voting is rejected, and that the tally
is correct after the voting period ends.
```

The agent loads `skills/fhevm-testing.md` and generates tests that:

- Use the FHEVM mock environment (no real network needed)
- Encrypt inputs with `createEncryptedInput()` before calling contract functions
- Time-travel past the deadline with `evm_increaseTime` + `evm_mine`
- Decrypt results via the mock instance to assert on plaintext values

---

### 7. Compile and run tests locally

```bash
npx hardhat compile
npx hardhat test
```

Tests run entirely locally against a mock FHE environment. No wallet, no network, no gas.

Expected output:

```
  ConfidentialVoting
    ✓ Should allow a user to cast an encrypted vote
    ✓ Should prevent double voting
    ✓ Should reveal correct tally after voting ends

  3 passing (1s)
```

---

### 8. Write a deploy script

Prompt your agent:

```
Write a deploy script for my ConfidentialVoting and ConfidentialToken contracts.
It should print the deployed addresses.
```

Output: a `scripts/deploy.ts` file ready to run against any network.

---

### 9. Get a funded wallet on Zama devnet

Go to [https://faucet.zama.ai](https://faucet.zama.ai) and request test tokens for your wallet address.

| Network detail | Value |
|---|---|
| Chain ID | 9000 |
| RPC URL | https://devnet.zama.ai |
| Explorer | https://explorer.devnet.zama.ai |

---

### 10. Configure your environment

Create a `.env` file in your project root:

```bash
PRIVATE_KEY=0xYourPrivateKey
ZAMA_RPC_URL=https://devnet.zama.ai
```

Add `.env` to your `.gitignore` — never commit private keys.

---

### 11. Deploy to Zama devnet

```bash
npx hardhat run scripts/deploy.ts --network zama
```

Expected output:

```
Deploying with: 0xYourWalletAddress
ConfidentialVoting deployed to: 0xAbc123...
ConfidentialToken deployed to:  0xDef456...
```

---

### 12. Verify on-chain

```bash
npx hardhat verify --network zama 0xAbc123... "Should we upgrade?" 604800
```

Then open [https://explorer.devnet.zama.ai](https://explorer.devnet.zama.ai) and search your contract address.

---

## What's inside

```
SKILL.md                    ← Master skill — agents read this first
skills/
  fhevm-contracts.md        ← Solidity patterns, FHE ops, ERC-7984, Gateway decryption
  fhevm-testing.md          ← Hardhat setup, mock FHE, test patterns, deploy scripts
  fhevm-frontend.md         ← fhevmjs, EIP-712 re-encryption, wagmi integration
templates/
  ConfidentialVoting.sol    ← Production-ready confidential voting contract
  ConfidentialToken.sol     ← ERC-7984 confidential token
  test-template.ts          ← Hardhat test template
  frontend-snippet.ts       ← fhevmjs client-side patterns
examples/                   ← Compiled and tested working contracts
  contracts/
  test/
  scripts/deploy.ts
```

---

## Why this exists

AI agents have no built-in knowledge of FHEVM. Without this skill pack they:

- Accept `euint64` directly as function parameters — skipping the ZK input proof
- Forget `TFHE.allowThis()` — causing silent state corruption on the next transaction
- Call `TFHE.decrypt()` inside transactions — which reverts
- Return `uint64` casts from view functions — returning the handle pointer, not the balance
- Miss `TFHE.allowTransient` before `requestDecryption` — causing Gateway access denied

PrivyStack gives agents the exact patterns they need to generate safe, working FHEVM code on the first attempt.

---

Built for the [Zama FHEVM](https://forms.zama.org/)