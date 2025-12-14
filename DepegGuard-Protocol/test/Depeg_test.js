const {expect} = require ("chai");
const {ethers} = require("hardhat");

const FIFTY_ETH = ethers.parseEther("50.0");
const HUNDRED_ETH = ethers.parseEther("100.0");
const THIRTY_DAYS = 30 *24 *60 * 60; //30 days in seconds
const MILD_SEVERITY = 0;


async function deployFakeStablecoin(initialHolder, initialAmount){
    const fakeERC20 = await ethers.getContractFactory("fakeStablecoin");
    const stablecoinContract = await fakeERC20.deploy("fake ETH", "ETH");
    await stablecoinContract.waitForDeployment();
    return stablecoinContract;
}

describe ("DepegInsurance Protocol Integration", function (){

    let InsurancePool, DepegInsuranceNFT;
    let pool, nftContract;
    let owner, lpProvider, policyBuyer;
    let STABLECOIN_ADDRESS;
    let mockOracle;

    
    beforeEach (async function(){

        [owner,lpProvider,policyBuyer] = await ethers.getSigners();

        const deployedStablecoin = await deployFakeStablecoin(policyBuyer, ethers.parseUnits("1000",18));

        STABLECOIN_ADDRESS = await deployedStablecoin.getAddress();

        InsurancePool = await ethers.getContractFactory("InsurancePool");
        pool = await InsurancePool.deploy(owner.address);
        await pool.waitForDeployment();

        DepegInsuranceNFT = await ethers.getContractFactory("DepegInsuranceNFT");
        nftContract = await DepegInsuranceNFT.deploy();
        await nftContract.waitForDeployment()

        await pool.setInsuranceContract(await nftContract.getAddress());
        await nftContract.setInsurancePool(await pool.getAddress());

        await pool.connect(lpProvider).depositLiquidityPool({value : HUNDRED_ETH});
        expect(await pool.getPoolLiquidity()).to.equal(HUNDRED_ETH);

        requiredPremium = await nftContract.calculatePremium(
            HUNDRED_ETH,THIRTY_DAYS,1 //mild
        );

        //deploy mock oracle
        const MockOracle = await ethers.getContractFactory("MockV3Aggregator");
        mockOracle = await MockOracle.deploy(
            "8", 
            100000000n
        );

        await mockOracle.waitForDeployment(); 

        await nftContract.setPriceFeed(
            STABLECOIN_ADDRESS,
            await mockOracle.getAddress()
        );

    });

        describe ("InsurancePool Functionality", function(){
            it("Should allow LP withdrawal if funds dont drop below totalActiveCover",
                async function () {
                    const initialBalance = await ethers.provider.getBalance(lpProvider.address);
                    const withdrawAmount = ethers.parseEther("10");
                }
            )
        });

        describe("TestOracle", function () {
            async function deployContractsFixture() {

                const MockOracle = await ethers.getContractFactory("MockV3Aggregator");
                const mockOracle = await MockOracle.deploy(
                    "8", // decimals
                    100000000n// initialAnswer
                );

                await mockOracle.waitForDeployment(); 

                const PriceConsumer = await ethers.getContractFactory("PriceConsumerV3");
                
                const mockOracleAddress = await mockOracle.getAddress(); 
                
                const priceConsumer = await PriceConsumer.deploy(
                    mockOracleAddress // mock oracle address
                );
                
                await priceConsumer.waitForDeployment(); 

                return { mockOracle, priceConsumer };
            }

            it("get oracle initial answer", async function () {
                const { mockOracle, priceConsumer } = await deployContractsFixture();
                const answer = await priceConsumer.getLatestPrice();
                console.log(answer);
            });
        });

        describe ("DepegInsuranceNFT policy lifecycle", function (){

            it("User should successfully purchase a policy and update active cover",
                async function(){
                    const coverAmount = FIFTY_ETH;
                    const requiredPremiumForTest = await nftContract.calculatePremium(
                        coverAmount,
                        THIRTY_DAYS,
                        1
                    );

                    const initialPoolCover = await pool.totalActiveCover();
                    const initialPoolBalance = await pool.getPoolLiquidity();

                    await nftContract.connect(policyBuyer).purchasePolicy(
                        STABLECOIN_ADDRESS,
                        coverAmount,
                        30,
                        1,
                        {value: requiredPremiumForTest}
                    );

                    expect(await pool.totalActiveCover()).to.equal(initialPoolCover + coverAmount)

                    expect(await nftContract.ownerOf(1)).to.equal(policyBuyer.address);

                    expect (await pool.getPoolLiquidity()).to.equal(initialPoolBalance + requiredPremiumForTest);

                    expect(await pool.totalActiveCover()).to.equal(FIFTY_ETH);
            });

            it("Should correctly report a depegged price (e.g., 95%)", async function () {
                const DEPEG_PRICE = 97000000n;
                await mockOracle.updateAnswer(DEPEG_PRICE);

                const pricePercentage = await nftContract.testGetPricePercentage(STABLECOIN_ADDRESS);

                expect(pricePercentage).to.equal(97n);
            });

            it("Mild: Should return 0% payout when price is AT the threshold (97%)", async function () {
                const MILD_SEVERITY = 1;
                const payout = await nftContract.testGetPayoutPercentage(MILD_SEVERITY, 97n);
                expect(payout).to.equal(0n);
            });

            it("Should allow the user to file a claim and receive payout upon depeg", async function(){
                    const coverAmount = FIFTY_ETH;
                    const MILD_SEVERITY =0;

                    const requiredPremiumForTest = await nftContract.calculatePremium(
                        coverAmount,
                        THIRTY_DAYS,
                        MILD_SEVERITY
                    );

                    const initialPoolBalance = await pool.getPoolLiquidity();
                    const initialBuyerBalance = await ethers.provider.getBalance(policyBuyer.address);

                    const txPurchase = await nftContract.connect(policyBuyer).purchasePolicy(
                        STABLECOIN_ADDRESS,
                        coverAmount,
                        30,
                        MILD_SEVERITY,
                        {value:requiredPremiumForTest}
                    );

                    const receipt = await txPurchase.wait();
                    const policyMintedEvent = receipt.logs.find(
                        (log) => log.fragment && log.fragment.name === "PolicyMinted"
                    );
                    const currentTokenId = policyMintedEvent.args.tokenId;

                    const depeggedPrice = 95000000n;
                    
                    await mockOracle.updateAnswer(depeggedPrice);

                    const debugPricePercent = await nftContract.testGetPricePercentage(STABLECOIN_ADDRESS);
                    expect(debugPricePercent).to.equal(95n, "Mock price was not set correctly");

                // Payout Percentage = Depeg Threshold - Current Price Percent
                const EXPECTED_PAYOUT_PERCENT = 2n;
                const payoutPercent = await nftContract.testGetPayoutPercentage(MILD_SEVERITY, debugPricePercent);
                expect(payoutPercent).to.equal(EXPECTED_PAYOUT_PERCENT, "Payout percentage calculation is wrong");

                // 50 ETH * 2% = 1 ETH
                const EXPECTED_PAYOUT_AMOUNT = (coverAmount * EXPECTED_PAYOUT_PERCENT) / 100n;

                const tx = await nftContract.connect(policyBuyer).fileClaim(currentTokenId);
        
                expect(await pool.totalActiveCover()).to.equal(0n);

                const policyDetails = await nftContract.getPolicyDetails(currentTokenId);

                expect (policyDetails.isActive).to.be.false;
                expect(tx).to.emit(nftContract,'PolicyClaimed').withArgs(currentTokenId);


            });

        });

        describe("Policy expiry functionality", function (){
                const DURATION_DAYS = 30;
                const durationInSeconds = DURATION_DAYS * 24 * 60 * 60;
                const coverage_amount = FIFTY_ETH;
                let policyTokenId;

                beforeEach (async function (){
                    const requiredPremium = await nftContract.calculatePremium(
                            coverage_amount,
                            durationInSeconds,
                            MILD_SEVERITY
                    );
                    const tx = await nftContract.connect(policyBuyer).purchasePolicy(
                        STABLECOIN_ADDRESS,
                        coverage_amount,
                        DURATION_DAYS,
                        MILD_SEVERITY,
                        { value: requiredPremium }
                    );
                    const receipt = await tx.wait();
                    const policyMintedEvent = receipt.logs.find(
                        (log) => log.fragment && log.fragment.name === "PolicyMinted"
                    );
    
                    policyTokenId = policyMintedEvent.args.tokenId;

                    const policyDetails = await nftContract.getPolicyDetails(policyTokenId);
                    expect(policyDetails.isActive).to.be.true;
                });

                it("Should succesfully expire the policy and reduce pool liability after expiry time", async function(){

                    const durationInSeconds = DURATION_DAYS * 24 * 60 * 60;
                    await ethers.provider.send("evm_increaseTime", [durationInSeconds + 1]);
                    await ethers.provider.send("evm_mine"); 

                    const tx = await nftContract.expirePolicy(policyTokenId);

                    const policyDetails = await nftContract.getPolicyDetails(policyTokenId);
                    expect(policyDetails.isActive).to.be.false;
                    
                    expect(await pool.totalActiveCover()).to.equal(0n);
                });
        });    

});





