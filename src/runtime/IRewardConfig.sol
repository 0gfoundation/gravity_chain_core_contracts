// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IRewardConfig
/// @notice Read-only interface for the block reward schedule
interface IRewardConfig {
    /// @notice Reward rate schedule
    /// @dev The yearly rate starts at `initialRateBps` and is multiplied by
    ///      `decayNumerator / decayDenominator` once per elapsed `decayPeriodMicros`, never going
    ///      below `floorRateBps`. Rates are in basis points of stake per year.
    struct RewardSchedule {
        uint64 initialRateBps;
        uint64 floorRateBps;
        uint64 decayNumerator;
        uint64 decayDenominator;
        uint64 decayPeriodMicros;
    }

    /// @notice The schedule in effect for the current epoch
    function getSchedule() external view returns (RewardSchedule memory);

    /// @notice Yearly reward rate (basis points of stake) after `elapsedMicros` since rewards started
    function rateBpsAt(
        uint64 elapsedMicros
    ) external view returns (uint64);
}
