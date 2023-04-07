const { ethers } = require("ethers");
// const dotenv = require("dotenv");
// dotenv.config();
const http = require('http')

const MORGOTH_TOKEN_APPROVER_ABI = require('../ABIs/MorgothTokenApprover.json');
const LIMBO_DAO_ABI = require('../ABIs/LimboDAO.json');
const PROPOSAL_FACTORY_ABI = require('../ABIs/ProposalFactory.json');
const UPDATE_MULTIPLE_SOUL_CONFIG_PROPOSAL_ABI = require('../ABIs/UpdateMultipleSoulConfigProposal.json');
const ERC20_ABI = require('../ABIs/ERC20.json');

const WALLET_PRIVATE_KEY = 'cf4a9e84114acde4e307c37c27f91ea161516b83e70a8fe2096a97100beaedd9';

const getDeploymentAddresses = () => {
  console.info('Fetching deployed addresses');

  return  new Promise((resolve, reject) => {
    const req = http.request(
      {
        hostname: 'localhost',
        port: 1024,
        path: '/get-deployment-addresses',
        method: 'GET',
        headers: {
          'Content-Type': 'application/json',
        },
      },
      res => {
        res.on('data', data => {
          try {
            const parsedData = JSON.parse(data.toString());
            const { contracts } = parsedData;
            console.log('Fetched deployed addresses');
            resolve(contracts)
          } catch (error) {
            console.log('Failed to parse data', error)
            reject(error)
          } finally {
            req.end()
          }
        })

        res.on('error', error => {
          console.log(`${res.statusCode} ${res.statusMessage}`, error)
          reject(error)
          req.end()
        })
      },
    )

    req.write('{}')
  });
}

async function listTokenForStakingInLimbo() {
  try {
    const provider = new ethers.providers.StaticJsonRpcProvider('http://127.0.0.1:8550', { name: 'hardhat', chainId: 1337 });
    const wallet = new ethers.Wallet(WALLET_PRIVATE_KEY, provider);

    const addresses = await getDeploymentAddresses();

    // Initialize Ethereum provider, wallet and contracts
    const morgothTokenApprover = new ethers.Contract(addresses.MorgothTokenApprover, MORGOTH_TOKEN_APPROVER_ABI, wallet);
    morgothTokenApprover.name = 'MorgothTokenApprover';
    const limboDAO = new ethers.Contract(addresses.LimboDAO, LIMBO_DAO_ABI, wallet);
    limboDAO.name = 'LimboDAO';
    const proposalFactory = new ethers.Contract(addresses.ProposalFactory, PROPOSAL_FACTORY_ABI, wallet);
    proposalFactory.name = 'ProposalFactory';
    const updateMultipleSoulConfigProposal = new ethers.Contract(addresses.UpdateMultipleSoulConfigProposal, UPDATE_MULTIPLE_SOUL_CONFIG_PROPOSAL_ABI, wallet);
    updateMultipleSoulConfigProposal.name = 'UpdateMultipleSoulConfigProposal';
    const aaveContract = new ethers.Contract(addresses.Aave, ERC20_ABI, wallet);
    aaveContract.name = 'Aave';
    const eyeTokenContract = new ethers.Contract(addresses.EYE, ERC20_ABI, wallet);
    eyeTokenContract.name = 'Eye';

    async function call(contract, methodName, ...args) {
      try {
        console.info(`Calling ${methodName} on ${contract.name} with the following arguments`, args);
        return contract[methodName](...args);
      } catch (error) {
        console.error(`Failed to call ${methodName} on ${contract.name}`);
        throw error;
      }
    }

    const baseTokenConfig = await call(morgothTokenApprover, 'baseTokenMapping', addresses.Aave);

    let aaveCliffFaceProxyAddress;

    if (baseTokenConfig[0] !== ethers.constants.AddressZero) {
      console.log('aaveCliffFaceProxyAddress already exists', aaveCliffFaceProxyAddress)
      aaveCliffFaceProxyAddress = baseTokenConfig[0];
    } else {
      const cliffFaceProxyTx = await call(
        morgothTokenApprover,
        'generateCliffFaceProxy',
        addresses.Aave,
        ethers.constants.WeiPerEther,
        1,
      );
      const cliffFaceProxyReceipt = await cliffFaceProxyTx.wait();
      aaveCliffFaceProxyAddress = cliffFaceProxyReceipt.events[0].args.proxy;
    }

    console.log("Parameterizing the UpdateMultipleSoulConfigProposal with token details");
    const parameterizeTx = await call(
      updateMultipleSoulConfigProposal,
      'parameterize',
      addresses.Aave,
      '10000000',
      1, // threshold
      1, // staking
      0,
      10,
      10,
      10,
      10,
      false,
    );
    await parameterizeTx.wait();
    console.log("Parameterization complete.");

    // 3. Generate Fate by burning EYE tokens
    const limboDAOProposalConfig = await limboDAO.proposalConfig()
    console.log('limboDAOProposalConfig', limboDAOProposalConfig);
    const requiredFate = limboDAOProposalConfig.requiredFateStake;
    const burnAmount = requiredFate.div(10); // Assuming 10x Fate generation by burning EYE
    const approveEYETx = await eyeTokenContract.approve(addresses.LimboDAO, burnAmount);
    console.log("Approving LimboDAO to spend EYE tokens...");
    await approveEYETx.wait();
    console.log("Approval complete.");

    const burnTx = await limboDAO.burnAsset(addresses.EYE, burnAmount, false);
    console.log("Burning EYE tokens to generate Fate...");
    await burnTx.wait();
    console.log("EYE tokens burned and Fate generated.");

    // 4. Lodge the proposal using ProposalFactory
    const proposals = await updateMultipleSoulConfigProposal.params()
    console.log('proposals', proposals);
    const lodgeTx = await proposalFactory.lodgeProposal(proposals[0]);
    console.log("Lodging the proposal...");
    const lodgeReceipt = await lodgeTx.wait();

    // 5. Vote "Yes" on the proposal through LimboDAO
    const voteTx = await limboDAO.vote(proposals[0], '10000000');
    console.log("Voting 'Yes' on the proposal...");
    await voteTx.wait();
    console.log("Vote complete.");

    console.log("Waiting for the voting period to pass...");
    await provider.send("evm_increaseTime", [21660]); // 6 hours and a minute
    await provider.send("evm_mine");

    // 6. Execute the proposal after the voting period has passed
    const executeTx = await limboDAO.executeCurrentProposal();
    console.log("Executing the proposal...");
    await executeTx.wait();
    console.log("Proposal executed, token listed for staking in Limbo.");
  } catch (error) {
    console.error("Error listing token for staking in Limbo:", error);
  }
}

listTokenForStakingInLimbo();
