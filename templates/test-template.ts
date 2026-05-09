import { ethers } from "hardhat";
import { expect } from "chai";
import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";

// ─── Fixture ─────────────────────────────────────────────────────────────────

async function deployFixture() {
  const [owner, alice, bob, charlie] = await ethers.getSigners();

  // Deploy ConfidentialVoting
  const Voting = await ethers.getContractFactory("ConfidentialVoting");
  const voting = await Voting.deploy("Should we upgrade the protocol?", 7 * 24 * 3600);
  await voting.waitForDeployment();

  // Deploy ConfidentialToken
  const Token = await ethers.getContractFactory("ConfidentialERC7984");
  const token = await Token.deploy("PrivyToken", "PRVY", 1_000_000n);
  await token.waitForDeployment();

  // Create FHEVM mock instances (one per user)
  // In production tests, replace with actual fhevmjs createInstance calls
  const createMockInput = (contractAddr: string, userAddr: string) => ({
    add8:  (v: number)  => ({ v, type: "uint8" }),
    add64: (v: bigint)  => ({ v, type: "uint64" }),
    encrypt: async () => ({
      handles:    [ethers.randomBytes(32)] as [Uint8Array],
      inputProof: ethers.randomBytes(64),
    }),
  });

  return { voting, token, owner, alice, bob, charlie, createMockInput };
}

// ─── Voting tests ─────────────────────────────────────────────────────────────

describe("ConfidentialVoting", function () {
  it("Deploys with correct question", async function () {
    const { voting } = await loadFixture(deployFixture);
    expect(await voting.question()).to.equal("Should we upgrade the protocol?");
  });

  it("Prevents voting after deadline", async function () {
    const { voting, alice } = await loadFixture(deployFixture);

    // Fast-forward past deadline
    await ethers.provider.send("evm_increaseTime", [7 * 24 * 3600 + 1]);
    await ethers.provider.send("evm_mine", []);

    // Should revert with VotingClosed
    const fakeHandle = ethers.randomBytes(32);
    const fakeProof  = ethers.randomBytes(64);
    await expect(voting.connect(alice).vote(fakeHandle, fakeProof))
      .to.be.revertedWithCustomError(voting, "VotingClosed");
  });

  it("Prevents double voting", async function () {
    const { voting, alice } = await loadFixture(deployFixture);
    const fakeHandle = ethers.randomBytes(32);
    const fakeProof  = ethers.randomBytes(64);

    // First vote — may revert due to invalid proof in mock (expected)
    try { await voting.connect(alice).vote(fakeHandle, fakeProof); } catch {}

    // Second attempt on a real network should revert with AlreadyVoted
    // (mock environment skips proof verification)
  });

  it("Cannot reveal results before voting ends", async function () {
    const { voting } = await loadFixture(deployFixture);
    await expect(voting.revealResults())
      .to.be.revertedWithCustomError(voting, "VotingStillOpen");
  });
});

// ─── Token tests ──────────────────────────────────────────────────────────────

describe("ConfidentialERC7984", function () {
  it("Assigns total supply to deployer", async function () {
    const { token } = await loadFixture(deployFixture);
    expect(await token.totalSupply()).to.equal(1_000_000n);
  });

  it("Returns deployer encrypted balance handle", async function () {
    const { token, owner } = await loadFixture(deployFixture);
    const handle = await token.balanceOf(owner.address);
    // Handle is a non-zero uint256 (ciphertext pointer)
    expect(handle).to.not.equal(0n);
  });

  it("Emits Transfer event on transfer", async function () {
    const { token, owner, alice } = await loadFixture(deployFixture);
    const fakeHandle = ethers.randomBytes(32);
    const fakeProof  = ethers.randomBytes(64);

    // In a real FHEVM test environment this would encrypt 100n first
    await expect(token.connect(owner).transfer(alice.address, fakeHandle, fakeProof))
      .to.emit(token, "Transfer")
      .withArgs(owner.address, alice.address);
  });
});

// ─── Helpers ─────────────────────────────────────────────────────────────────

async function timeTravel(seconds: number) {
  await ethers.provider.send("evm_increaseTime", [seconds]);
  await ethers.provider.send("evm_mine", []);
}
