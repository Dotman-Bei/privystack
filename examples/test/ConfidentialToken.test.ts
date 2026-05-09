import { ethers } from "hardhat";
import { expect } from "chai";
import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";

describe("ConfidentialToken", function () {

  async function deployFixture() {
    const [owner, alice, bob] = await ethers.getSigners();

    const Token = await ethers.getContractFactory("ConfidentialToken");
    const token = await Token.deploy("PrivyToken", "PRVY", 1_000_000n);
    await token.waitForDeployment();

    return { token, owner, alice, bob };
  }

  it("Sets name, symbol, decimals, totalSupply", async function () {
    const { token } = await loadFixture(deployFixture);
    expect(await token.name()).to.equal("PrivyToken");
    expect(await token.symbol()).to.equal("PRVY");
    expect(await token.decimals()).to.equal(6);
    expect(await token.totalSupply()).to.equal(1_000_000n);
  });

  it("Returns a non-zero encrypted handle for owner balance", async function () {
    const { token, owner } = await loadFixture(deployFixture);
    const handle = await token.balanceOf(owner.address);
    expect(handle).to.not.equal(0n);
  });

  it("Returns zero handle for address with no balance", async function () {
    const { token, alice } = await loadFixture(deployFixture);
    const handle = await token.balanceOf(alice.address);
    // Uninitialized balance — handle should be 0 (not set)
    expect(handle).to.equal(0n);
  });

  it("Allows owner to mint to another address", async function () {
    const { token, owner, alice } = await loadFixture(deployFixture);

    await (await token.connect(owner).mint(alice.address, 500n)).wait();

    const handle = await token.balanceOf(alice.address);
    expect(handle).to.not.equal(0n);
    expect(await token.totalSupply()).to.equal(1_000_500n);
  });

  it("Blocks non-owner from minting", async function () {
    const { token, alice } = await loadFixture(deployFixture);
    await expect(token.connect(alice).mint(alice.address, 100n))
      .to.be.revertedWithCustomError(token, "OnlyOwner");
  });

  it("Emits Transfer event on transfer", async function () {
    const { token, owner, alice } = await loadFixture(deployFixture);

    const fakeHandle = ethers.zeroPadBytes(ethers.toBeArray(100n), 32);
    const fakeProof  = ethers.randomBytes(64);

    await expect(token.connect(owner).transfer(alice.address, fakeHandle, fakeProof))
      .to.emit(token, "Transfer")
      .withArgs(owner.address, alice.address);
  });

  it("Emits Approval event on approve", async function () {
    const { token, owner, alice } = await loadFixture(deployFixture);

    const fakeHandle = ethers.zeroPadBytes(ethers.toBeArray(100n), 32);
    const fakeProof  = ethers.randomBytes(64);

    await expect(token.connect(owner).approve(alice.address, fakeHandle, fakeProof))
      .to.emit(token, "Approval")
      .withArgs(owner.address, alice.address);
  });
});
