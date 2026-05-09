/**
 * Frontend integration snippets for FHEVM contracts.
 * Copy and adapt these patterns into your Next.js / React app.
 */

import { createInstance, FhevmInstance } from "fhevmjs";
import { BrowserProvider, Contract } from "ethers";

// ─── 1. Initialize FHEVM instance ─────────────────────────────────────────────

let _instance: FhevmInstance | null = null;

export async function getFhevmInstance(): Promise<FhevmInstance> {
  if (_instance) return _instance;
  if (!window.ethereum) throw new Error("No wallet detected");

  _instance = await createInstance({
    kmsContractAddress: process.env.NEXT_PUBLIC_KMS_CONTRACT!,
    aclContractAddress: process.env.NEXT_PUBLIC_ACL_CONTRACT!,
    network: window.ethereum,
    gatewayUrl: process.env.NEXT_PUBLIC_GATEWAY_URL!,
  });

  return _instance;
}

// ─── 2. Encrypt a vote and submit ─────────────────────────────────────────────

export async function submitEncryptedVote(
  contractAddress: string,
  abi: any[],
  voteChoice: 0 | 1 | 2          // 0=NO 1=YES 2=ABSTAIN
): Promise<void> {
  const provider = new BrowserProvider(window.ethereum);
  const signer   = await provider.getSigner();
  const userAddr = await signer.getAddress();

  const instance = await getFhevmInstance();

  // Encrypt the vote choice (euint8 on-chain)
  const input = instance.createEncryptedInput(contractAddress, userAddr);
  input.add8(voteChoice);
  const { handles, inputProof } = await input.encrypt();

  const contract = new Contract(contractAddress, abi, signer);
  const tx = await contract.vote(handles[0], inputProof);
  await tx.wait();
}

// ─── 3. Encrypt a token transfer amount ───────────────────────────────────────

export async function encryptedTransfer(
  tokenAddress: string,
  abi: any[],
  recipient: string,
  amount: bigint                   // e.g., 100_000_000n for 100 tokens (6 decimals)
): Promise<void> {
  const provider = new BrowserProvider(window.ethereum);
  const signer   = await provider.getSigner();
  const userAddr = await signer.getAddress();

  const instance = await getFhevmInstance();

  const input = instance.createEncryptedInput(tokenAddress, userAddr);
  input.add64(amount);
  const { handles, inputProof } = await input.encrypt();

  const contract = new Contract(tokenAddress, abi, signer);
  const tx = await contract.transfer(recipient, handles[0], inputProof);
  await tx.wait();
}

// ─── 4. Decrypt user's own balance (EIP-712 re-encryption) ────────────────────

export async function getMyDecryptedBalance(
  tokenAddress: string,
  abi: any[]
): Promise<bigint> {
  const provider = new BrowserProvider(window.ethereum);
  const signer   = await provider.getSigner();
  const userAddr = await signer.getAddress();

  const instance = await getFhevmInstance();

  // One-time keypair for this session
  const { publicKey, privateKey } = instance.generateKeypair();

  // EIP-712 message — user signs to authorize re-encryption
  const eip712 = instance.createEIP712(publicKey, tokenAddress);
  const signature = await signer.signTypedData(
    eip712.domain,
    { Reencrypt: eip712.types.Reencrypt },
    eip712.message
  );

  // Read the encrypted balance handle from contract
  const contract = new Contract(tokenAddress, abi, provider);
  const handle   = await contract.balanceOf(userAddr);

  // Re-encrypt under user's public key and decrypt locally
  const plainBalance = await instance.reencrypt(
    handle,
    privateKey,
    publicKey,
    signature,
    tokenAddress,
    userAddr
  );

  return plainBalance; // bigint
}

// ─── 5. Read public decrypted results (after Gateway callback) ────────────────

export async function getVotingResults(
  votingAddress: string,
  abi: any[]
): Promise<{ yes: bigint; no: bigint; abstain: bigint; revealed: boolean }> {
  const provider = new BrowserProvider(window.ethereum);
  const contract = new Contract(votingAddress, abi, provider);

  const [yes, no, abstain, revealed] = await Promise.all([
    contract.yesCount(),
    contract.noCount(),
    contract.abstainCount(),
    contract.resultsRevealed(),
  ]);

  return { yes, no, abstain, revealed };
}
