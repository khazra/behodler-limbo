// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "../DAO/Governable.sol";
import "../facades/LimboLike.sol";
import "../facades/LimboDAOLike.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract SoulReader is Governable {
    LimboLike limbo;

    constructor(address dao) Governable(dao) {
        (address _limbo, , , , , , ) = LimboDAOLike(dao).domainConfig();
        limbo = LimboLike(_limbo);
    }

    function SoulStats(address token)
        public
        view
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        uint256 latestIndex = limbo.latestIndex(token);
        (uint256 allocPoints, , , , , uint256 state, ) = limbo.souls(
            token,
            latestIndex
        );
        uint256 stakeBalance = IERC20(token).balanceOf(address(limbo));
        return (state, stakeBalance, allocPoints);
    }

    function CrossingParameters(address token)
        public
        view
        returns (
            uint256, //allocPOint
            uint16, //exitPenalty
            uint256, //initialCrossingbonus
            int256 //bonusDelta
        )
    {
        uint256 latestIndex = limbo.latestIndex(token);
        (uint256 allocPoints, , , , , , uint16 exitPenalty) = limbo.souls(
            token,
            latestIndex
        );
  

        (, , int256 crossingBonusDelta, uint256 initialCrossingBonus, ) = limbo
        .tokenCrossingParameters(token, latestIndex);
        return (
            allocPoints,
            exitPenalty,
            initialCrossingBonus,
            crossingBonusDelta
        );
    }
}