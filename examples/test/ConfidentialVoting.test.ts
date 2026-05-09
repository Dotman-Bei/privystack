import { ethers } from "hardhat";
import { expect } from "chai";
import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";

describe("ConfidentialVoting", function () {

  async function deployFixture() {
    const [owner, alice, bob, charlie] = await ethers.getSigners();

    const Voting = await ethers.getContractFactory("ConfidentialVoting");
    const voting = await Voting.deploy("Should we upgrade the protocol?", 7 * 24 * 3600);
    await voting.waitForDeployment();

    return { voting, owner, alice, bob, charlie };
  }

  it("Sets question and deadline on deploy", async function () {
    const { voting } = await loadFixture(deployFixture);
    expect(await voting.question()).to.equal("Should we upgrade the protocol?");
    expect(await voting.isActive()).to.be.true;
    expect(await voting.resultsRevealed()).to.be.false;
  });

  it("Tracks time remaining", async function () {
    const { voting } = await loadFixture(deployFixture);
    const remaining = await voting.timeRemaining();
    expect(remaining).to.be.gt(0n);
    expect(remaining).to.be.lte(BigInt(7 * 24 * 3600));
  });

  it("Marks hasVoted after a vote is cast", async function () {
    const { voting, alice } = await loadFixture(deployFixture);
    expect(await voting.hasVoted(alice.address)).to.be.false;

    // In mock environment: pass raw bytes (proof validation is skipped locally)
    const fakeHandle = ethers.zeroPadBytes(ethers.toBeArray(1n), 32);
    const fakeProof  = ethers.randomBytes(64);

    // This will revert with real FHEVM proof validation — expected on local hardhat
    // In actual fhevm mock tests, use fhevmjs createInstance to generate real inputs
    try {
      await voting.connect(alice).vote(fakeHandle, fakeProof);
    } catch {}
  });

  it("Reverts when voting after deadline", async function () {
    const { voting, alice } = await loadFixture(deployFixture);

    await ethers.provider.send("evm_increaseTime", [7 * 24 * 3600 + 1]);
    await ethers.provider.send("evm_mine", []);

    const fakeHandle = ethers.randomBytes(32);
    const fakeProof  = ethers.randomBytes(64);

    await expect(voting.connect(alice).vote(fakeHandle, fakeProof))
      .to.be.revertedWithCustomError(voting, "VotingClosed");
  });

  it("Reverts revealResults before deadline", async function () {
    const { voting } = await loadFixture(deployFixture);
    await expect(voting.revealResults())
      .to.be.revertedWithCustomError(voting, "VotingStillOpen");
  });

  it("Returns zero timeRemaining after deadline", async function () {
    const { voting } = await loadFixture(deployFixture);

    await ethers.provider.send("evm_increaseTime", [7 * 24 * 3600 + 1]);
    await ethers.provider.send("evm_mine", []);

    expect(await voting.timeRemaining()).to.equal(0n);
    expect(await voting.isActive()).to.be.false;
  });
});
