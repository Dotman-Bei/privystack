# FHEVM Testing Skill

> Reference for writing correct tests and deploy scripts for FHEVM contracts.
> Read this entire file before writing any test code.

---

## 1. Hardhat Setup for FHEVM

```bash
npm install --save-dev \
  @nomicfoundation/hardhat-toolbox \
  hardhat \
  typescript \
  ts-node \
  @types/node

npm install fhevm @openzeppelin/contracts dotenv
```

### hardhat.config.ts

```typescript
import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import * as dotenv from "dotenv";

dotenv.config();

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.24",
    settings: {
      optimizer: { enabled: true, runs: 200 },
      evmVersion: "cancun",   // required for FHEVM
    },
  },
  networks: {
    hardhat: { chainId: 31337 },
    zama: {
      url: process.env.ZAMA_RPC_URL || "https://devnet.zama.ai",
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
    },
  },
};

export default config;
```

---

## 2. Testing Architecture

FHEVM tests run against a **mock** FHE environment locally. The mock:
- Encrypts/decrypts values in plaintext (no real FHE overhead)
- Simulates the Gateway callback synchronously
- Lets you inspect encrypted values for assertions

```
test/
├── ConfidentialVoting.test.ts
└── ConfidentialToken.test.ts
```

---

## 3. Test Template

```typescript
import { ethers } from "hardhat";
import { expect } from "chai";
import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { createInstances } from "../test/instance";   // fhevm mock instance helper

describe("ConfidentialVoting", function () {

  async function deployFixture() {
    const [owner, alice, bob] = await ethers.getSigners();
    const instances = await createInstances([owner, alice, bob]);

    const ConfidentialVoting = await ethers.getContractFactory("ConfidentialVoting");
    const voting = await ConfidentialVoting.deploy("Should we upgrade the protocol?", 7 * 24 * 3600);
    await voting.waitForDeployment();

    return { voting, owner, alice, bob, instances };
  }

  it("Should allow alice to cast an encrypted vote", async function () {
    const { voting, alice, instances } = await loadFixture(deployFixture);

    // Encrypt the vote: 1 = YES
    const aliceInstance = instances.alice;
    const input = aliceInstance.createEncryptedInput(
      await voting.getAddress(),
      alice.address
    );
    input.add8(1); // 1 = YES
    const { handles, inputProof } = await input.encrypt();

    // Submit encrypted vote
    const tx = await voting.connect(alice).vote(handles[0], inputProof);
    await tx.wait();

    expect(await voting.hasVoted(alice.address)).to.be.true;
  });

  it("Should prevent double voting", async function () {
    const { voting, alice, instances } = await loadFixture(deployFixture);
    const input = instances.alice.createEncryptedInput(await voting.getAddress(), alice.address);
    input.add8(1);
    const { handles, inputProof } = await input.encrypt();

    await (await voting.connect(alice).vote(handles[0], inputProof)).wait();

    await expect(voting.connect(alice).vote(handles[0], inputProof))
      .to.be.revertedWith("Already voted");
  });

  it("Should reveal correct tally after voting ends", async function () {
    const { voting, alice, bob, instances, owner } = await loadFixture(deployFixture);

    // Alice votes YES (1), Bob votes NO (0)
    for (const [signer, choice] of [[alice, 1], [bob, 0]] as const) {
      const inst = instances[signer.address === alice.address ? "alice" : "bob"];
      const input = inst.createEncryptedInput(await voting.getAddress(), signer.address);
      input.add8(choice);
      const { handles, inputProof } = await input.encrypt();
      await (await voting.connect(signer).vote(handles[0], inputProof)).wait();
    }

    // Fast-forward time past voting period
    await ethers.provider.send("evm_increaseTime", [7 * 24 * 3600 + 1]);
    await ethers.provider.send("evm_mine", []);

    // Request decryption (Gateway mock resolves synchronously in tests)
    await (await voting.connect(owner).revealResults()).wait();

    expect(await voting.yesCount()).to.equal(1n);
    expect(await voting.noCount()).to.equal(1n);
  });
});
```

---

## 4. Creating FHEVM Test Instances

Create `test/instance.ts`:

```typescript
import { ethers } from "hardhat";
import { createInstance as createFhevmInstance } from "fhevm";

export async function createInstances(signers: any[]) {
  const instances: Record<string, any> = {};

  const contractAddress = "0x0000000000000000000000000000000000000000"; // placeholder
  const chainId = (await ethers.provider.getNetwork()).chainId;

  for (const signer of signers) {
    const instance = await createFhevmInstance({
      // In mock mode, these can be placeholder values
      kmsContractAddress: "0x0000000000000000000000000000000000000000",
      aclContractAddress: "0x0000000000000000000000000000000000000000",
      network: ethers.provider,
      chainId: Number(chainId),
    });
    instances[signer.address] = instance;
  }

  // Also key by name for convenience
  if (signers[0]) instances.owner = instances[signers[0].address];
  if (signers[1]) instances.alice = instances[signers[1].address];
  if (signers[2]) instances.bob   = instances[signers[2].address];

  return instances;
}
```

---

## 5. Asserting on Encrypted Values (Mock Only)

In the mock environment you can decrypt values to assert on them:

```typescript
// Re-encrypt for a user and read the plaintext (MOCK ONLY — not real FHE)
const { publicKey, privateKey } = instances.alice.generateKeypair();
const eip712 = instances.alice.createEIP712(publicKey, await token.getAddress());
const signature = await alice.signTypedData(
  eip712.domain,
  { Reencrypt: eip712.types.Reencrypt },
  eip712.message
);

const balanceHandle = await token.balanceOf(alice.address);
const decryptedBalance = await instances.alice.reencrypt(
  balanceHandle,
  privateKey,
  publicKey,
  signature,
  await token.getAddress(),
  alice.address
);

expect(decryptedBalance).to.equal(1000n);
```

---

## 6. Deploy Script

```typescript
// scripts/deploy.ts
import { ethers } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying with:", deployer.address);

  // Deploy ConfidentialVoting
  const Voting = await ethers.getContractFactory("ConfidentialVoting");
  const voting = await Voting.deploy(
    "Should we upgrade the protocol?",
    7 * 24 * 3600  // 1 week
  );
  await voting.waitForDeployment();
  console.log("ConfidentialVoting deployed to:", await voting.getAddress());

  // Deploy ConfidentialToken (ERC-7984)
  const Token = await ethers.getContractFactory("ConfidentialToken");
  const token = await Token.deploy("PrivyToken", "PRVY", 1_000_000n);
  await token.waitForDeployment();
  console.log("ConfidentialToken deployed to:", await token.getAddress());
}

main().catch((err) => { console.error(err); process.exit(1); });
```

---

## 7. Running Tests

```bash
# Compile contracts
npx hardhat compile

# Run all tests (mock FHE — no network needed)
npx hardhat test

# Run a specific test file
npx hardhat test test/ConfidentialVoting.test.ts

# Deploy to local Hardhat node
npx hardhat node &
npx hardhat run scripts/deploy.ts --network localhost

# Deploy to Zama devnet
npx hardhat run scripts/deploy.ts --network zama
```

---

## 8. Deploying to Zama Network (Full Guide)

### Step 1 — Get a funded wallet

```bash
# Zama devnet faucet: https://faucet.zama.ai
# Chain ID: 9000
# RPC URL:  https://devnet.zama.ai
# Explorer: https://explorer.devnet.zama.ai
```

### Step 2 — Configure `.env`

```bash
PRIVATE_KEY=0xYourPrivateKey
ZAMA_RPC_URL=https://devnet.zama.ai
```

### Step 3 — Add Zama to `hardhat.config.ts`

```typescript
networks: {
  zama: {
    url: process.env.ZAMA_RPC_URL || "https://devnet.zama.ai",
    accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
    chainId: 9000,
  },
}
```

### Step 4 — Deploy

```bash
npx hardhat run scripts/deploy.ts --network zama
```

### Step 5 — Verify on-chain

```bash
npx hardhat verify --network zama DEPLOYED_ADDRESS "constructor_arg1" "constructor_arg2"
```

### Key Zama network addresses (devnet)

| Contract | Address |
|---|---|
| KMS (Key Management Service) | `0x904Cf2f48De9eDA5bC3E929Daf0Dd06A2e5B0b4` |
| ACL (Access Control List) | `0xFee8407e2f5e3Ee68ad77cAE98c434e637f516F` |
| Gateway | `0x096b4679d45fB675d4e2c1E4565009Cec99A12B1` |
| TFHE Executor | `0x687408aB54661ba0b4aeF3a44156c616c6955E07` |

These are injected automatically into contracts inheriting `GatewayCaller` — no manual configuration needed in Solidity.

---

## 9. Common Test Mistakes

| Mistake | Fix |
|---|---|
| Using real FHE in local tests | Use mock instance from `fhevm/lib/mock` |
| Not calling `evm_mine` after `evm_increaseTime` | Always mine a block after time travel |
| Asserting on `euint64` handle directly | Re-encrypt + decrypt via instance before asserting |
| Forgetting to `waitForDeployment()` | Always await deployment before interacting |
| Calling `revealResults()` before voting ends | Time-travel past the deadline first |
