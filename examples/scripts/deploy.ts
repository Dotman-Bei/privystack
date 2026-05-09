import { ethers } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying with:", deployer.address);
  console.log("Balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "ETH\n");

  // ── ConfidentialVoting ──────────────────────────────────────────────────────
  const Voting = await ethers.getContractFactory("ConfidentialVoting");
  const voting = await Voting.deploy(
    "Should we upgrade the PrivyStack protocol?",
    7 * 24 * 3600
  );
  await voting.waitForDeployment();
  const votingAddr = await voting.getAddress();
  console.log("ConfidentialVoting deployed to:", votingAddr);

  // ── ConfidentialToken (ERC-7984) ────────────────────────────────────────────
  const Token = await ethers.getContractFactory("ConfidentialToken");
  const token = await Token.deploy("PrivyToken", "PRVY", 1_000_000n);
  await token.waitForDeployment();
  const tokenAddr = await token.getAddress();
  console.log("ConfidentialToken deployed to: ", tokenAddr);

  console.log("\n── .env.local values for frontend ──");
  console.log(`NEXT_PUBLIC_VOTING_CONTRACT=${votingAddr}`);
  console.log(`NEXT_PUBLIC_TOKEN_CONTRACT=${tokenAddr}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
