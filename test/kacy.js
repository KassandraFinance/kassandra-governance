const { expect } = require("chai");

describe("$KACY contract", function () {
  it("Deployment should assign the total supply of tokens to the owner", async function () {
    const [owner] = await ethers.getSigners();

    const Token = await ethers.getContractFactory("Kacy");

    const kacy = await Token.deploy();

    const ownerBalance = await kacy.balanceOf(owner.address);
    expect(await kacy.totalSupply()).to.equal(ownerBalance);
  });
});
