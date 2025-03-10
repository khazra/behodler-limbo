// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import "./facades/LimboDAOLike.sol";
import "./facades/Burnable.sol";
import "./facades/BehodlerLike.sol";
import "./facades/FlanLike.sol";
import "./periphery/UniswapV2/interfaces/IUniswapV2Pair.sol";
import "./facades/MigratorLike.sol";
import "./facades/AMMHelper.sol";
import "./facades/AngbandLike.sol";
import "./facades/LimboAddTokenToBehodlerPowerLike.sol";
import "./DAO/Governable.sol";
import "./facades/FlashGovernanceArbiterLike.sol";
import "./openzeppelin/SafeERC20.sol";

/*
Contract: LIMBO is the main staking contract. It corresponds conceptually to Sushi's Masterchef and takes design inspiration from Masterchef.
Context: Limbo is a part of the Behodler ecosystem. All dapps within the Behodler ecosystem either support or are supported by the Behodler AMM.
Purpose: As a single contract store of liquidity, Behodler AMM requires new tokens be initiated with the a TVL equal to the average TVL of existing tokens. 
         In Behodler nomenclature, the total value of all tokens in the AMM is the total value bonded (TVB) and the value of individual tokens is the average value bonded (AVB). 
         The primary goal of Limbo is to raise capital for prospective AMM tokens in order to meet the AVB threshold. 
Secondary goals: since Limbo possesses staking mechanics, a secondary goal is to encourage lockup of protocol tokens.
Types of staking: Staked tokens are either for migration to Behodler or for lockup. The former pools are threshold and the latter are perpetual.
Primary incentive: users staking on Limbo receive the perpetually minted Flan token. 
Economics: When the staked value of a threshold token is migrated to Behodler, SCX is generated. The SCX is used via an external AMM such as Uniswap to prop up the liquidity and value of Flan. 
           Rather than being used to purchase Flan on the open market, the generated SCX is paired with newly minted Flan in a ratio that steers the price of Flan toward parity with Dai.
           This mechanism of pairing and steering the price through minting is known in Behodler as price tilting and effectively doubles the liquidity raised. For instance, suppose we list
           $10000 of a new token on Behodler. We then take $10000 worth of SCX and pair it with $10000 of newly minted Flan, adding $20000 of token liquidity to an external AMM. The extra 
           $10000 will form the price support for newly minted Flan which can be used to encourage future migrations.
           In addition to migration driven liquidity growth, Flan will be rewarded for token lockup. For lockup of Flan, the price support pressure of reduced circulating supply will provide additional 
           runway from which to mint more Flan. For external AMM pair contracts involving SCX or Pyrotokens, the lockup will raise liquidity for those pairs which will promote arbitrage trading of the pairs which will
           lead to additional burning of those tokens. For direct lockup of SCX, additional minting of SCX corresponds algorithmically to increased liquidity on Behodler and an increased SCX price. This raises the AVB of Behodler which creates 
           additional liquidity for Flan during the next migration. Flan therefore has 4 supporting vectors: SCX from migration, price support for SCX via lockup, price support via PyroFlan and indirect price support of Flan and SCX via trading on external pairs (automining).
Nomenclature: Since words like token are incredibly generic, we need to provide context through naming. Sticking to an overall metaphor, to paraphrase MakerDao documentation, reduces code smells.
          1. A token listed on Limbo is a Soul
          2. When a token lists on Behodler, we say the soul is crossing over. The event is a crossing.
          3. A token crosses over when the TVL on Limbo exceeds a threshold.
          4. Tokens which do not cross over such as existing tokens listed on Behodler or the protocol tokens are perpetual souls.

Security note: Since the migration steps generate value transfers between protocols, forced delays should be instituted to close any flash loan or dominant miner ttack vectors.

Basic staking incentives:
For both perpatual and threshold souls, a flan per second statistic is divided proportionately amongst the existing stakers.

Late stakers considerations:
Suppose you're the last person to stake on a threshold soul. That is, your stake takes the soul over the crossing threshold and the soul is locked.
In this instance, you would have earned no Flan, creating a declining incentive for stakers to arrive and in the extreme leading
to a situation of never crossing the threshold for any soul. This is a tragedy of the commons situation that leads to an overly 
inflated and essentially worthless Flan. We need a strategy to ameliorate this. The strategy needs to:
1. provide sufficient incentive for later arrivals.
2. Not punish early stakers and ideally reward them for being early.
3. Not disproportionately inflate the supply of flan.

Crossing incentives:
After a crossing, stakers are no longer able to withdraw their tokens as they'll now be sent to Behodler. They'll therefore need to be compensated for loss of tokens. 
Governance can calibrate two variables on a soul to encourage prospective stakers in threshold souls to breach the threshold:
1. Initial crossing bonus (ICB) is the Flan per token paid to all stakers and is a positive integer.
2. Crossing bonus delta (CBD) is the Flan per token for every second the soul is live. For instance suppose the CBD is 2. From the very first token staked to
the point at which the threshold was crossed, the soul records 10000 seconds passing. This amounts to 2*10000 = 20000 Flan per token.
The ICB and CBD are combined to forma Total Flan Per Token (TF) and the individual user balance is multiplied by TF. For instance, using the example above, suppose the ICB is 10 Flan per token.
This means the total Flan per token paid out is 10 + 20000 = 20010 Flan per token. If a user has 3 T staked, they receive 3*20010 = 60030 Flan as reward for having their T migrated to Behodler.
This is in addition to any Flan their received during the staking phase.
Note: CBD can be negative. This creates a situation where the initial bonus per token is at its highest when the staking round begins. 
For negative CBD, the intent is to create a sense of urgency amongst prospective stakers to push the pool over the threshold. For positive CBD, the intent is to draw marginal stakers into the soul in a desire to receive the crossing bonus while the opportunity still exists.
A negative CBD benefits from strong communal coordination. For instance, if the token listed has a large, active and well heeled community, a negative CBD might act as a rallying cry to ape in. A positive CBD benefits from individually uncoordinated motivations (classical market setting)
States of migration:
1. unset
No staking/unstaking.
2. Staking
Staking/unstaking. If type is threshold, take threshold into account
3. WaitingToCross
Can claim rewards. Can't unstake.
4. CrossedOver
Injected into Behodler

Flash governance:
Since there might be many souls staking, we don't want to have to go through long-to-confirm proposals.
Instead, we want to have the opportunity to flash a governance action quickly. Flash governance happens in the span of 1 transaction.
To protect the community and the integrity of the DAO, all flash governance decisions must be accompanied by a large EYE deposit that presumably is more costly to give up
than the most profitable attack vector. The deposit is locked for a duration long enough for a long form burn proposal to be voted on.

The community can then decide if their governance action was in accord with the wellbeing of Limbo.
If it isn't, they can slash the deposit by betwen 1 and 100%. Flash gov can only move a variable some percentage per day.
Eg. suppose we vote on snapshot to raise the threshold for Sushi to 1200 Sushi from 1180, 1.69%. Some chosen community member flash sets the threshold to the new value.
A malicious flash staker then sets the threshold down to 1150. The community believes that the latter user was acting against the will of the community and a formal proposal is deployed onchain which slashes the user's staked EYE.
The community votes on the proposal and the EYE is slashed. After a fixed timeout, the EYE belonging to the original flash staker.

Rectangle of Fairness:
When new lquidity is added to Behodler, SCX is generated. The fully undiluted price of the new quantity of SCX far exceeds the value of the tokens migrated. Because of the dynamics of Behodler's bonding curve, the 
current value of the AVB is always equal to about 25 SCX. If the AVB increases, the increase shows up as in increase in the SCX price so that the 25 SCX metric still holds. For this reason, only 25 SCX is used to prop up
the liquidity of Flan. The surplus SCX generated is burnt. Because multiplying 25 SCX by the current market price gives us a value equal to the AVB and because we wish to strike a balance between boosting Flan and not over diluting the 
market with too much SCX, this value is known as the Rectangle of Fairness. While 25 SCX is the value of AVB, it's usually desirable to hold back a bit more than 25 for 2 reasons:
1. SCX burns on transfer so that after all open market operations are complete, we'd have less than 25 remaining. 
2. CPMMs such as Uniswap impose hyperbolic price slippage so that trying to withdraw the full balance of SCX results in paying an assymptotically high Flan price. As such we can deploy a bit more than 25 SCX per migrations without worrying about added dilution 
*/
enum SoulState {
  unset,
  staking,
  waitingToCross,
  crossedOver,
  perpetualTerminated
}
enum SoulType {
  uninitialized,
  threshold, //the default soul type is staked and when reaching a threshold, migrates to Behodler
  perpetual //the type of staking pool most people are familiar with.
}

struct Soul {
  uint256 lastRewardTimestamp;
  uint256 accumulatedFlanPerShare;
  uint256 crossingThreshold; //the value at which this soul is elligible to cross over to Behodler
  SoulType soulType;
  SoulState state;
  uint256 flanPerSecond; // fps: we use a helper function to convert min APY into fps
  uint256 aggregateStakedBalance; // this allows for crossOver to occur after perpetual, eliminating an attack vector
}

struct CrossingParameters {
  uint256 stakingBeginsTimestamp; //to calculate bonus
  uint256 stakingEndsTimestamp;
  int256 crossingBonusDelta; //change in teraFlanPerToken per second
  uint256 initialCrossingBonus; //measured in teraFlanPerToken
  bool burnable;
}

struct CrossingConfig {
  address behodler;
  uint256 SCX_fee;
  uint256 migrationInvocationReward; //calling migrate is expensive. The caller should be rewarded in Flan.
  uint256 crossingMigrationDelay; // this ensures that if Flan is successfully attacked, governance will have time to lock Limbo and prevent bogus migrations
  address morgothPower;
  address angband;
  address ammHelper;
}

library SoulLib {
  function set(
    Soul memory soul,
    uint256 crossingThreshold,
    uint256 soulType,
    uint256 state,
    uint256 fps
  ) external pure returns (Soul memory) {
    soul.crossingThreshold = crossingThreshold;
    soul.flanPerSecond = fps;
    if (SoulState(state) == SoulState.perpetualTerminated && SoulType(soulType) != SoulType.perpetual) {
      revert ConflictingStateAndType(state, soulType);
    }
    soul.state = SoulState(state);
    soul.soulType = SoulType(soulType);
    return soul;
  }
}

library CrossingLib {
  function set(
    CrossingParameters storage params,
    FlashGovernanceArbiterLike flashGoverner,
    Soul storage soul,
    uint256 initialCrossingBonus,
    int256 crossingBonusDelta,
    bool burnable,
    uint256 crossingThreshold
  ) external {
    flashGoverner.enforceTolerance(initialCrossingBonus, params.initialCrossingBonus);
    flashGoverner.enforceToleranceInt(crossingBonusDelta, params.crossingBonusDelta);

    params.initialCrossingBonus = initialCrossingBonus;
    params.crossingBonusDelta = crossingBonusDelta;
    params.burnable = burnable;

    flashGoverner.enforceTolerance(crossingThreshold, soul.crossingThreshold);
    soul.crossingThreshold = crossingThreshold;
  }
}

library MigrationLib {
  using SafeERC20 for IERC20;

  /**
   *@dev This lib serves to circumvent EIP 170 while also improving readability by ringfencing MorgothDAO logic from Limbo logic
   *@param token to be migrated (or crossed over) from Limbo to Behodler
   *@param power MorgothDAO power is a spell of sorts that can perform a governance action on Morgoth. Powes have validation rules just like proposals in other DAOs. This power is considered to be prevalidated and ready for repeat execution by Limbo only.
   *@param crossingConfig rules for crossing over the token at hand
   */
  function migrate(
    address token,
    uint256 aggregateStakedBalance,
    LimboAddTokenToBehodlerPowerLike power,
    CrossingParameters memory crossingParams,
    CrossingConfig memory crossingConfig,
    FlanLike flan
  ) external returns (uint256, uint256) {
    power.parameterize(token, crossingParams.burnable);
    //invoke Angband execute on power that migrates token type to Behodler
    uint256 tokenBalance = IERC20(token).balanceOf(address(this));

    //prevents migrating perpetual stakers and errs on the side of security
    tokenBalance = tokenBalance < aggregateStakedBalance ? tokenBalance : aggregateStakedBalance;

    IERC20(token).safeTransfer(crossingConfig.morgothPower, tokenBalance);
    IERC20 scx = IERC20(crossingConfig.behodler);
    uint256 scxBalance = scx.balanceOf(address(this));
    AngbandLike(crossingConfig.angband).executePower(crossingConfig.morgothPower);
    scxBalance = scx.balanceOf(address(this)) - scxBalance;

    //use remaining scx to buy flan and pool it on an external AMM
    IERC20(crossingConfig.behodler).safeTransfer(crossingConfig.ammHelper, scxBalance);
    uint256 lpMinted = AMMHelper(crossingConfig.ammHelper).stabilizeFlan(scxBalance);
    //reward caller and update soul state

    uint256 flanOfCallerBefore = flan.balanceOf(msg.sender);
    uint256 reward = crossingConfig.migrationInvocationReward;
    flan.mint(msg.sender, reward);
    uint256 change = flan.balanceOf(msg.sender) - flanOfCallerBefore;
    if (change != reward) {
      revert InvocationRewardFailed(msg.sender);
    }
    return (tokenBalance, lpMinted);
  }
}

/// @title Limbo
/// @author Justin Goro
/// @notice Tokens are either staked for locking (perpetual) or for migration to the Behodler AMM (threshold).
/// @dev The governance functions are initially unguarded to allow the deploying dev to rapidly set up without having to endure governance imposed time limits on proposals. Ending the config period is a irreversible action.
contract Limbo is Governable {
  using SafeERC20 for IERC20;
  using SoulLib for Soul;
  using MigrationLib for address;
  using CrossingLib for CrossingParameters;

  event SoulUpdated(address indexed soul, uint256 fps);
  event Staked(address indexed staker, address indexed token, uint256 amount);
  event Unstaked(address indexed unstaker, address indexed token, uint256 amount);
  event TokenListed(address indexed token, uint256 amount, uint256 scxfln_LP_minted);

  event ClaimedReward(address indexed staker, address indexed soul, uint256 index, uint256 amount);

  event BonusPaid(address indexed token, uint256 index, address indexed recipient, uint256 bonus);

  struct User {
    uint256 stakedAmount;
    uint256 rewardDebt;
    bool bonusPaid;
  }

  uint256 constant TERA = 1E12;
  bool protocolEnabled = true;

  ///@notice protocol settings for migrating threshold tokens to Behodler
  CrossingConfig public crossingConfig;

  ///@notice Since a token can be listed more than once on Behodler, we index each listing to separate the rewards from each staking event.
  ///@dev tokenAddress->index->stakingInfo
  mapping(address => mapping(uint256 => Soul)) public souls;

  ///@notice Each token maintains its own index to allow Limbo to keep rewards for each staking event separate
  mapping(address => uint256) public latestIndex;

  ///@dev tokenAddress->userAddress->soulIndex->Userinfo
  mapping(address => mapping(address => mapping(uint256 => User))) public userInfo;
  ///@dev token->index->data
  mapping(address => mapping(uint256 => CrossingParameters)) public tokenCrossingParameters;

  ///@dev soul->owner->unstaker->amount
  mapping(address => mapping(address => mapping(address => uint256))) public unstakeApproval;
  FlanLike immutable Flan;

  modifier enabled() {
    if (!protocolEnabled) {
      revert ProtocolDisabled();
    }
    _;
  }

  modifier preventFlashLoanMigration(address token) {
    if (
      block.timestamp - tokenCrossingParameters[token][latestIndex[token]].stakingEndsTimestamp <
      crossingConfig.crossingMigrationDelay
    ) {
      revert MigrationCoolDownActive(token, latestIndex[token], crossingConfig.crossingMigrationDelay);
    }
    _;
  }

  ///@notice refreshes current state of soul.
  function updateSoul(address token) public {
    uint256 latest = latestIndex[token];
    souls[token][latest] = previewSoulUpdate(token, latest);
  }

  constructor(address flan, address limboDAO) Governable(limboDAO) {
    Flan = FlanLike(flan);
  }

  ///@notice configure global migration settings such as the address of Behodler and the minumum delay between end of staking and migration
  function configureCrossingConfig(
    address behodler,
    address angband,
    address ammHelper,
    address morgothPower,
    uint256 migrationInvocationReward,
    uint256 crossingMigrationDelay
  ) public onlySuccessfulProposal {
    crossingConfig.migrationInvocationReward = migrationInvocationReward * (1 ether);
    crossingConfig.behodler = behodler;
    crossingConfig.crossingMigrationDelay = crossingMigrationDelay;
    crossingConfig.angband = angband;
    crossingConfig.ammHelper = ammHelper;
    crossingConfig.morgothPower = morgothPower;
  }

  ///@notice if an exploit in any part of Limbo or its souls is detected, anyone with sufficient EYE balance can disable the protocol instantly
  function disableProtocol() public governanceApproved(true) {
    protocolEnabled = false;
  }

  ///@notice Once disabled, the only way to reenable is via a formal proposal. This forces the community to deliberate on the legitimacy of the disabling that lead to this state. A malicious call to disable can have its EYE slashed.
  function enableProtocol() public onlySuccessfulProposal {
    protocolEnabled = true;
  }

  ///@notice Governance function for rapidly calibrating a soul. Useful for responding to large price movements quickly
  ///@param token Soul to calibrate
  ///@param initialCrossingBonus Of the crossing bonus flan payout, this represents the fixed Flan per token component
  ///@param crossingBonusDelta Of the crossing bonus flan payout, this represents the payout per flan per second that the soul is in staking state
  ///@param fps Flan Per Second staked.
  function adjustSoul(
    address token,
    uint256 initialCrossingBonus,
    int256 crossingBonusDelta,
    uint256 fps
  ) public governanceApproved(false) {
    Soul storage soul = currentSoul(token);
    FlashGovernanceArbiterLike governer = flashGoverner();
    governer.enforceTolerance(soul.flanPerSecond, fps);
    soul.flanPerSecond = fps;

    CrossingParameters storage params = tokenCrossingParameters[token][latestIndex[token]];

    governer.enforceTolerance(params.initialCrossingBonus, initialCrossingBonus);
    governer.enforceTolerance(
      uint256(params.crossingBonusDelta < 0 ? params.crossingBonusDelta * -1 : params.crossingBonusDelta),
      uint256(crossingBonusDelta < 0 ? crossingBonusDelta * -1 : crossingBonusDelta)
    );

    params.initialCrossingBonus = initialCrossingBonus;
    params.crossingBonusDelta = crossingBonusDelta;
  }

  ///@notice Configuration of soul through formal proposal. Should only be called infrequently.
  ///@dev Unlike with flash governance, variable movements are unguarded
  ///@param crossingThreshold The token balance on Behodler that triggers the soul to enter into waitingToCross state
  ///@param soulType Indicates whether the soul is perpetual or threshold
  ///@param state a threshold soul can be either staking, waitingToCross, or CrossedOver. Both soul types can be in unset state.
  ///@param index a token could be initially listed as a threshold soul and then later added as perpetual. An index helps distinguish these two events so that user late to claim rewards have no artificial time constraints imposed on their behaviour
  function configureSoul(
    address token,
    uint256 crossingThreshold,
    uint256 soulType,
    uint256 state,
    uint256 index,
    uint256 fps
  ) public onlySoulUpdateProposal {
    uint256 current = latestIndex[token];
    if (index < current) {
      revert ConfiguringOldSoulsForbidden(token, current, index);
    }
    if (index > current && souls[token][current].state == SoulState.staking) {
      revert StakingInProgress(token, current);
    }

    latestIndex[token] = index > current ? current + 1 : current;

    Soul memory soul = souls[token][index];
    if (soul.state != SoulState.unset && SoulState(state) == SoulState.unset) revert CannotFallBackIntoUnset(token);
    soul = soul.set(crossingThreshold, soulType, state, fps);
    if (SoulState(state) == SoulState.staking) {
      tokenCrossingParameters[token][latestIndex[token]].stakingBeginsTimestamp = block.timestamp;
    }

    souls[token][index] = soul;
    emit SoulUpdated(token, fps);
  }

  ///@notice We need to know how to handle threshold souls at the point of crossing
  ///@param token The soul to configure
  ///@param initialCrossingBonus Of the crossing bonus flan payout, this represents the fixed Flan per token component
  ///@param crossingBonusDelta Of the crossing bonus flan payout, this represents the payout per flan per second that the soul is in staking state
  ///@param burnable For listing on Behodler, is this token going to burn on trade or does it get its own Pyrotoken
  ///@param crossingThreshold The token balance on Behodler that triggers the soul to enter into waitingToCross state
  function configureCrossingParameters(
    address token,
    uint256 initialCrossingBonus,
    int256 crossingBonusDelta,
    bool burnable,
    uint256 crossingThreshold
  ) public governanceApproved(false) {
    CrossingParameters storage params = tokenCrossingParameters[token][latestIndex[token]];
    Soul storage soul = currentSoul(token);
    params.set(flashGoverner(), soul, initialCrossingBonus, crossingBonusDelta, burnable, crossingThreshold);
  }

  function stakeFor(
    address token,
    uint256 amount,
    address recipient
  ) public enabled {
    _stake(token, amount, msg.sender, recipient);
  }

  ///@notice User facing stake function for handling both types of souls
  ///@param token The soul to stake
  ///@param amount The amount of tokens to stake
  /**@dev Can handle fee on transfer tokens but for more exotic tokens such as rebase tokens, use a proxy wrapper. See the TokenProxyRegistry for logistics.
   *The purpose of balance checking before and after transfer of tokens is to account for fee-on-transfer discrepencies so that tokens like SCX can be listed without inducing
   *broken states. The community is encouraged to use proxy wrappers for tokens which may open up Limbo or Beholer exploit vulnerabilities.
   *Security enforcement of tokens listed on Limbo is offloaded to governance so that Limbo isn't required to anticipate every attack vector.
   */
  function stake(address token, uint256 amount) public enabled {
    _stake(token, amount, msg.sender, msg.sender);
  }

  ///@notice User facing unstake function for handling both types of souls. For threshold souls, can only be called during staking phase.
  ///@param token The soul to unstake
  ///@param amount The amount of tokens to unstake
  function unstake(address token, uint256 amount) public enabled {
    _unstake(token, amount, msg.sender, msg.sender, type(uint256).max);
  }

  ///@notice Allows for Limbo to be upgraded 1 user at a time without introducing a system wide security risk. Anticipates moving tokens to Limbo2 (wen Limbo2??)
  ///@dev similar to ERC20.safeTransferFrom, this function allows a user to approve an upgrade contract migrate their staked tokens safely. Use this to unstake from prior rounds
  ///@param index specift which round of staking.
  function unstakeFor(
    address token,
    uint256 amount,
    address holder,
    uint256 index
  ) public {
    _unstake(token, amount, msg.sender, holder, index);
  }

  function _unstake(
    address token,
    uint256 amount,
    address unstaker,
    address holder,
    uint256 index
  ) internal {
    if (unstaker != holder) {
      unstakeApproval[token][holder][unstaker] -= amount;
    }
    uint256 _latestIndex = latestIndex[token];
    index = index > _latestIndex ? _latestIndex : index;
    Soul memory soul = souls[token][index];
    if (soul.state == SoulState.crossedOver || soul.state == SoulState.waitingToCross) {
      revert InvalidSoulState(token, index, uint256(soul.state));
    }

    soul = previewSoulUpdate(token, index);
    User storage user = userInfo[token][holder][index];
    if (user.stakedAmount < amount) {
      revert ExcessiveWithdrawalRequest(token, amount, user.stakedAmount);
    }
    soul.aggregateStakedBalance -= amount;

    uint256 pending = getPending(user, soul);
    if (amount > 0) {
      user.stakedAmount = user.stakedAmount - amount;
      IERC20(token).safeTransfer(address(unstaker), amount);
      rewardAdjustDebt(holder, pending, soul.accumulatedFlanPerShare, user);
      emit ClaimedReward(holder, token, index, pending);
      //the token transfer will show the beneficiary. The unstaked event shows the intiator the unstake call
      emit Unstaked(unstaker, token, amount);
    }
    souls[token][index] = soul;
  }

  ///@notice accumulated flan rewards from staking can be claimed
  ///@param token The soul for which to claim rewards
  ///@param index souls no longer listed may still have unclaimed rewards.
  function claimReward(address token, uint256 index) public enabled {
    Soul memory soul = previewSoulUpdate(token, index);
    User storage user = userInfo[token][msg.sender][index];

    uint256 pending = getPending(user, soul);

    if (pending > 0) {
      rewardAdjustDebt(msg.sender, pending, soul.accumulatedFlanPerShare, user);
      emit ClaimedReward(msg.sender, token, index, pending);
    }
  }

  ///@notice for threshold souls only, claiming the compensation for migration tokens known as the Crossing Bonus
  ///@param token The soul for which to claim rewards
  ///@param index souls no longer listed may still have an unclaimed bonus.
  ///@dev The tera factor is to handle fixed point calculations without significant loss of precision.
  function claimBonus(address token, uint256 index) public enabled {
    Soul storage soul = souls[token][index];
    CrossingParameters storage crossing = tokenCrossingParameters[token][index];
    if (soul.state != SoulState.crossedOver && soul.state != SoulState.waitingToCross) {
      revert InvalidSoulState(token, index, uint256(soul.state));
    }
    User storage user = userInfo[token][msg.sender][index];
    if (user.bonusPaid) {
      revert BonusClaimed(token, index);
    }
    user.bonusPaid = true;
    int256 accumulatedFlanPerTeraToken = crossing.crossingBonusDelta *
      int256(crossing.stakingEndsTimestamp - crossing.stakingBeginsTimestamp);

    //assert signs are the same
    if (accumulatedFlanPerTeraToken * crossing.crossingBonusDelta < 0) {
      revert CrossingBonusInvariant(accumulatedFlanPerTeraToken, crossing.crossingBonusDelta);
    }

    int256 finalFlanPerTeraToken = int256(crossing.initialCrossingBonus) + accumulatedFlanPerTeraToken;

    uint256 flanBonus = 0;

    if (finalFlanPerTeraToken > 0) {
      flanBonus = uint256((int256(user.stakedAmount) * finalFlanPerTeraToken)) / TERA;
      Flan.mint(msg.sender, flanBonus);
    } else {
      revert FlanBonusMustBePositive(token, index, user.stakedAmount, finalFlanPerTeraToken);
    }

    emit BonusPaid(token, index, msg.sender, flanBonus);
  }

  ///@notice migrates threshold token from Limbo to Behodler and orchestrates Flan boosting mechanics. Callers of this function are rewared to compensate for gas expenditure
  /**@dev this function depends on a Morgoth Power. For those unfamiliar, a power is similar to a spell on other DAOs. Morgoth owns Behodler and so the only way to list
   * a token on Behodler is via a Morgoth Power. Permission mapping is handled on Morgoth side. Calling this function assumes that the power has been calibrated and that Limbo has been granted
   * permission on Morgoth to execute migrations to Behodler. The other big depenency is the AMM helper which contains the bulk of the migration logic.
   */
  function migrate(address token, uint256 index) public enabled preventFlashLoanMigration(token) {
    Soul memory soul = souls[token][index];

    if (soul.soulType != SoulType.threshold) {
      revert InvalidSoulType(token, uint256(soul.soulType), uint256(soul.soulType));
    }
    if (soul.state != SoulState.waitingToCross) {
      revert InvalidSoulState(token, index, uint256(soul.state));
    }
    (uint256 tokenBalance, uint256 lpMinted) = token.migrate(
      soul.aggregateStakedBalance,
      LimboAddTokenToBehodlerPowerLike(crossingConfig.morgothPower),
      tokenCrossingParameters[token][latestIndex[token]],
      crossingConfig,
      Flan
    );
    uint256 balanceOfSoulOnBehodler = IERC20(token).balanceOf(crossingConfig.behodler);
    souls[token][index].state = SoulState.crossedOver;
    emit TokenListed(token, tokenBalance, lpMinted);
  }

  ///@notice analogous to ERC20 approve, this function gives third party contracts permission to migrate token balances on Limbo. Useful for both upgrades and third party integrations into Limbo
  function approveUnstake(
    address token,
    address unstaker,
    uint256 amount
  ) external {
    unstakeApproval[token][msg.sender][unstaker] = amount; //token->owner->unstaker->amount
  }

  function _stake(
    address token,
    uint256 amount,
    address payer,
    address recipient
  ) internal {
    uint256 index = latestIndex[token];
    Soul memory soul = souls[token][index];
    if (soul.state != SoulState.staking) {
      revert InvalidSoulState(token, index, uint256(soul.state));
    }

    soul = previewSoulUpdate(token, index);
    User storage user = userInfo[token][recipient][index];

    //dish out accumulated rewards.
    uint256 pending = getPending(user, soul);
    if (pending > 0) {
      Flan.mint(recipient, pending);
    }

    //in the case of FOT or other non traditional tokens, use the limbo proxy.
    IERC20(token).safeTransferFrom(payer, address(this), amount);
    uint256 newBalance = IERC20(token).balanceOf(address(this));

    user.stakedAmount = user.stakedAmount + amount;
    soul.aggregateStakedBalance += amount;
    if (soul.soulType == SoulType.threshold && newBalance > soul.crossingThreshold) {
      soul.state = SoulState.waitingToCross;
      tokenCrossingParameters[token][latestIndex[token]].stakingEndsTimestamp = block.timestamp;
    }
    souls[token][index] = soul;
    user.rewardDebt = (user.stakedAmount * soul.accumulatedFlanPerShare) / TERA;
    emit Staked(recipient, token, user.stakedAmount);
  }

  function rewardAdjustDebt(
    address recipient,
    uint256 pending,
    uint256 accumulatedFlanPerShare,
    User storage user
  ) internal {
    Flan.mint(recipient, pending);
    user.rewardDebt = (user.stakedAmount * accumulatedFlanPerShare) / TERA;
  }

  function currentSoul(address token) internal view returns (Soul storage) {
    return souls[token][latestIndex[token]];
  }

  function getPending(User memory user, Soul memory soul) internal pure returns (uint256) {
    return ((user.stakedAmount * soul.accumulatedFlanPerShare) / TERA) - user.rewardDebt;
  }

  function previewSoulUpdate(address token, uint256 index) internal view returns (Soul memory soul) {
    soul = souls[token][index];
    if (soul.soulType == SoulType.uninitialized) {
      revert InvalidSoul(token);
    }

    uint256 finalTimeStamp = block.timestamp;
    if (soul.state != SoulState.staking && soul.soulType == SoulType.threshold) {
      finalTimeStamp = tokenCrossingParameters[token][index].stakingEndsTimestamp;
    }
    uint256 soulLastRewardTimestamp = soul.lastRewardTimestamp;
    if (finalTimeStamp == soulLastRewardTimestamp) {
      return soul;
    }
    uint256 balance = IERC20(token).balanceOf(address(this));

    if (balance > 0) {
      uint256 flanReward = (finalTimeStamp - soulLastRewardTimestamp) * soul.flanPerSecond;
      soul.accumulatedFlanPerShare = soul.accumulatedFlanPerShare + ((flanReward * TERA) / balance);
    }
    soul.lastRewardTimestamp = finalTimeStamp;
  }
}
