const { ethers } = require("ethers");
// const dotenv = require("dotenv");
// dotenv.config();
const http = require('http')

const MORGOTH_TOKEN_APPROVER_ABI = require('../ABIs/MorgothTokenApprover.json');
const LIMBO_DAO_ABI = require('../ABIs/LimboDAO.json');
const PROPOSAL_FACTORY_ABI = require('../ABIs/ProposalFactory.json');
const UPDATE_MULTIPLE_SOUL_CONFIG_PROPOSAL_ABI = require('../ABIs/UpdateMultipleSoulConfigProposal.json');
const ERC20_ABI = require('../ABIs/ERC20.json');
const LIMBO_ABI = require('../ABIs/Limbo.json');
const TOKEN_PROXY_REGISTRY_ABI = require('../ABIs/TokenProxyRegistry.json');

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
    morgothTokenApprover.displayName = 'MorgothTokenApprover';
    const limboDAO = new ethers.Contract(addresses.LimboDAO, LIMBO_DAO_ABI, wallet);
    limboDAO.displayName = 'LimboDAO';
    const proposalFactory = new ethers.Contract(addresses.ProposalFactory, PROPOSAL_FACTORY_ABI, wallet);
    proposalFactory.displayName = 'ProposalFactory';
    const updateMultipleSoulConfigProposal = new ethers.Contract(addresses.UpdateMultipleSoulConfigProposal, UPDATE_MULTIPLE_SOUL_CONFIG_PROPOSAL_ABI, wallet);
    updateMultipleSoulConfigProposal.displayName = 'UpdateMultipleSoulConfigProposal';
    const aaveContract = new ethers.Contract(addresses.Aave, ERC20_ABI, wallet);
    aaveContract.displayName = 'Aave';
    const eyeContract = new ethers.Contract(addresses.EYE, ERC20_ABI, wallet);
    eyeContract.displayName = 'EYE';
    const limbo = new ethers.Contract(addresses.Limbo, LIMBO_ABI, wallet);
    limbo.displayName = 'Limbo';
    const tokenProxyRegistry = new ethers.Contract(addresses.TokenProxyRegistry, TOKEN_PROXY_REGISTRY_ABI, wallet);
    tokenProxyRegistry.displayName = 'TokenProxyRegistry';

    async function call(contract, methodName, ...args) {
      try {
        console.info(`Calling '${methodName}' method on '${contract.displayName}' contract with the following arguments`, args);
        return contract[methodName](...args);
      } catch (error) {
        console.error(`Failed to call ${contract.displayName}.${methodName}`);
        throw error;
      }
    }

    const isAaveApprovedInMorgoth = await call(
      morgothTokenApprover,
      'approved',
      addresses.Aave,
    );

    if (!isAaveApprovedInMorgoth) {
      const cliffFaceProxyTx = await call(
        morgothTokenApprover,
        'generateCliffFaceProxy',
        addresses.Aave,
        '1000',
        1,
      );
      await cliffFaceProxyTx.wait();
    } else {
      console.log('Aave is already approved in Morgoth');
    }

    const morgothTokenApproverBaseTokenMapping = await call(
      morgothTokenApprover,
      'baseTokenMapping',
      addresses.Aave,
    );

    const cliffFacedAaveAddress = morgothTokenApproverBaseTokenMapping.cliffFace;
    console.log('cliffFaceProxy for Aave', cliffFacedAaveAddress);

    console.log("Parameterizing the UpdateMultipleSoulConfigProposal with token details");
    const parameterizeUpdateMultipleSoulConfigProposalTx = await call(
      updateMultipleSoulConfigProposal,
      'parameterize',
      addresses.Aave,
      '1000',
      1, // threshold
      1, // staking
      0,
      10,
      10,
      10,
      10,
      false,
    );
    await parameterizeUpdateMultipleSoulConfigProposalTx.wait();

    const setUpdateMultipleSoulConfigProposalProxyTx = await call(
      updateMultipleSoulConfigProposal,
      'setProxy',
      ethers.constants.AddressZero,
      cliffFacedAaveAddress,
      0,
    );
    await setUpdateMultipleSoulConfigProposalProxyTx.wait();

    const lockUpdateMultipleSoulConfigProposalTx = await call(
      updateMultipleSoulConfigProposal,
      'lockDown',
    );
    await lockUpdateMultipleSoulConfigProposalTx.wait();

    // 3. Generate Fate by burning EYE tokens
    const limboDAOProposalConfig = await call(limboDAO, 'proposalConfig')
    // const burnAmount = limboDAOProposalConfig.requiredFateStake.div(10).add(1000); // Assuming 10x Fate generation by burning EYE
    const approveEYETx = await call(
      eyeContract,
      'approve',
      addresses.LimboDAO,
      ethers.constants.MaxUint256,
    );
    await approveEYETx.wait();

    const burnTx = await call(limboDAO, 'burnAsset', addresses.EYE, limboDAOProposalConfig.requiredFateStake, false);
    await burnTx.wait();

    // 4. Lodge the proposal using ProposalFactory
    const lodgeTx = await call(proposalFactory, 'lodgeProposal', addresses.UpdateMultipleSoulConfigProposal);
    await lodgeTx.wait();

    // 5. Vote "Yes" on the proposal through LimboDAO
    const voteTx = await call(limboDAO, 'vote', addresses.UpdateMultipleSoulConfigProposal, 1000);
    await voteTx.wait();

    console.log("Waiting for the voting period to pass...");
    await provider.send("evm_increaseTime", [limboDAOProposalConfig.votingDuration.toNumber()]);
    await provider.send("evm_mine", []);

    // 6. Execute the proposal after the voting period has passed
    const executeTx = await call(limboDAO, 'executeCurrentProposal');
    await executeTx.wait();

    const proxyPair = await call(tokenProxyRegistry, 'tokenProxy', addresses.Aave);
    console.info('proxyPair', proxyPair);

    const soul = await call(limbo, 'souls', addresses.Aave, 0);
    console.info('soul', soul);
  } catch (error) {
    console.error("Error listing token for staking in Limbo:", error);
  }
}

listTokenForStakingInLimbo();
