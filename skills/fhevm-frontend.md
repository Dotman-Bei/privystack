# FHEVM Frontend Skill

> Reference for building frontends that interact with FHEVM contracts.
> Read this entire file before writing any client-side code.

---

## 1. Install fhevmjs

```bash
npm install fhevmjs viem wagmi @wagmi/core
```

`fhevmjs` handles:
- Client-side encryption of user values
- Input proof generation
- Re-encryption (user decryption via EIP-712)

---

## 2. Initialize the FHEVM Instance

Do this once at app startup. The instance is bound to a specific network.

```typescript
// lib/fhevm.ts
import { createInstance, FhevmInstance } from "fhevmjs";

let instance: FhevmInstance | null = null;

export async function getFhevmInstance(provider: any): Promise<FhevmInstance> {
  if (instance) return instance;

  instance = await createInstance({
    kmsContractAddress: process.env.NEXT_PUBLIC_KMS_CONTRACT!,
    aclContractAddress: process.env.NEXT_PUBLIC_ACL_CONTRACT!,
    network: provider,               // window.ethereum or a viem provider
    gatewayUrl: process.env.NEXT_PUBLIC_GATEWAY_URL!,
  });

  return instance;
}

// Known addresses for Zama devnet
export const ZAMA_ADDRESSES = {
  kmsContract: "0x904Cf2f48De9eDA5bC3E929Daf0Dd06A2e5B0b4",  // devnet
  aclContract: "0xFee8407e2f5e3Ee68ad77cAE98c434e637f516F",  // devnet
  gatewayUrl:  "https://gateway.devnet.zama.ai",
};
```

---

## 3. Encrypt a Value (Before Sending to Contract)

Always encrypt on the client side. Never send plaintext to the contract.

```typescript
import { getFhevmInstance } from "@/lib/fhevm";

async function encryptAndVote(
  contractAddress: string,
  userAddress: string,
  voteChoice: number,   // 0=NO, 1=YES, 2=ABSTAIN (plaintext — gets encrypted)
  provider: any,
  signer: any
) {
  const instance = await getFhevmInstance(provider);

  // Create encrypted input — bound to (contract, user) pair
  const input = instance.createEncryptedInput(contractAddress, userAddress);
  input.add8(voteChoice);                          // match the euint8 on-chain
  const { handles, inputProof } = await input.encrypt();

  // handles[0] is the einput (encrypted value handle)
  // inputProof is the ZK proof bytes
  const contract = new ethers.Contract(contractAddress, VOTING_ABI, signer);
  const tx = await contract.vote(handles[0], inputProof);
  await tx.wait();
}
```

### Encrypting multiple values in one call

```typescript
const input = instance.createEncryptedInput(contractAddress, userAddress);
input.add64(transferAmount);     // first param
input.add8(someFlag);            // second param
const { handles, inputProof } = await input.encrypt();

// handles[0] → first einput, handles[1] → second einput
await contract.transfer(recipient, handles[0], handles[1], inputProof);
```

---

## 4. User Decryption — EIP-712 Re-encryption Flow

This is how a user decrypts their own encrypted data (e.g., their balance).
The contract never reveals the plaintext on-chain — it re-encrypts under the user's public key.

```typescript
import { getFhevmInstance } from "@/lib/fhevm";

async function getMyBalance(
  contractAddress: string,
  userAddress: string,
  provider: any,
  signer: any
): Promise<bigint> {
  const instance = await getFhevmInstance(provider);

  // Step 1: Generate a one-time keypair
  const { publicKey, privateKey } = instance.generateKeypair();

  // Step 2: Create EIP-712 message (user signs to prove they own the address)
  const eip712 = instance.createEIP712(publicKey, contractAddress);

  // Step 3: Ask user to sign (MetaMask popup — NO gas)
  const signature = await signer.signTypedData(
    eip712.domain,
    { Reencrypt: eip712.types.Reencrypt },
    eip712.message
  );

  // Step 4: Get the encrypted handle from contract
  const contract = new ethers.Contract(contractAddress, TOKEN_ABI, provider);
  const handle = await contract.balanceOf(userAddress);

  // Step 5: Re-encrypt the handle under the user's public key & decrypt locally
  const decryptedBalance = await instance.reencrypt(
    handle,
    privateKey,
    publicKey,
    signature,
    contractAddress,
    userAddress
  );

  return decryptedBalance; // bigint plaintext
}
```

---

## 5. Public Decryption (Gateway — Reading Revealed Results)

When a contract has called `Gateway.requestDecryption()` and the callback has fired,
the result is already in a public state variable — just read it normally.

```typescript
// No FHE operations needed — it's a regular uint64 state variable after decryption
const yesCount = await contract.yesCount();   // public uint64
const noCount  = await contract.noCount();    // public uint64
```

---

## 6. React Hook Pattern

```typescript
// hooks/useFhevm.ts
import { useState, useEffect } from "react";
import { useWalletClient, usePublicClient } from "wagmi";
import { getFhevmInstance } from "@/lib/fhevm";

export function useFhevm() {
  const [ready, setReady] = useState(false);
  const { data: walletClient } = useWalletClient();
  const publicClient = usePublicClient();

  useEffect(() => {
    if (!walletClient || !publicClient) return;
    getFhevmInstance(walletClient).then(() => setReady(true));
  }, [walletClient, publicClient]);

  return { ready };
}
```

---

## 7. wagmi Configuration

```typescript
// lib/wagmi.ts
import { createConfig, http } from "wagmi";
import { mainnet, sepolia } from "wagmi/chains";
import { metaMask, injected } from "wagmi/connectors";

// Zama devnet chain definition
const zamaDevnet = {
  id: 9000,
  name: "Zama Devnet",
  nativeCurrency: { name: "ZAMA", symbol: "ZAMA", decimals: 18 },
  rpcUrls: { default: { http: ["https://devnet.zama.ai"] } },
};

export const wagmiConfig = createConfig({
  chains: [zamaDevnet, sepolia],
  connectors: [metaMask(), injected()],
  transports: {
    [zamaDevnet.id]: http(),
    [sepolia.id]:    http(),
  },
});
```

---

## 8. Environment Variables (.env.local)

```bash
NEXT_PUBLIC_KMS_CONTRACT=0x904Cf2f48De9eDA5bC3E929Daf0Dd06A2e5B0b4
NEXT_PUBLIC_ACL_CONTRACT=0xFee8407e2f5e3Ee68ad77cAE98c434e637f516F
NEXT_PUBLIC_GATEWAY_URL=https://gateway.devnet.zama.ai
NEXT_PUBLIC_VOTING_CONTRACT=0xYourDeployedVotingAddress
NEXT_PUBLIC_TOKEN_CONTRACT=0xYourDeployedTokenAddress
```

---

## 9. Common Frontend Mistakes

| Mistake | Fix |
|---|---|
| Sending plaintext `amount` to encrypted param | Always encrypt via `fhevmjs` first |
| Creating one `FhevmInstance` per component | Create once globally; reuse |
| Calling `reencrypt()` without a user signature | User must sign EIP-712 first |
| Using `ethers.BigNumber` for encrypted handles | Handles are already `bigint` / `0x...` hex |
| Generating a new keypair on every render | Generate once per session; store in state/context |
| Not awaiting `input.encrypt()` | It's async — must `await` before reading `handles` |
| Skipping the `inputProof` param in the contract call | Both `handles[0]` AND `inputProof` are required |

---

## 10. fhevmjs API Cheatsheet

```typescript
// Instance creation
const instance = await createInstance({ kmsContractAddress, aclContractAddress, network, gatewayUrl });

// Encrypt
const input = instance.createEncryptedInput(contractAddr, userAddr);
input.addBool(true);     // ebool
input.add8(255);         // euint8
input.add16(1000);       // euint16
input.add32(100000);     // euint32
input.add64(1000000n);   // euint64
input.add128(bigVal);    // euint128
input.addAddress(addr);  // eaddress
const { handles, inputProof } = await input.encrypt();

// Keypair for re-encryption
const { publicKey, privateKey } = instance.generateKeypair();

// EIP-712 message
const eip712 = instance.createEIP712(publicKey, contractAddress);

// Re-encrypt / user decrypt
const plaintext = await instance.reencrypt(handle, privateKey, publicKey, signature, contractAddr, userAddr);
```
