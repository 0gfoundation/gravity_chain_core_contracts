// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { SystemAddresses } from "../foundation/SystemAddresses.sol";
import { requireAllowed } from "../foundation/SystemAccessControl.sol";
import { Errors } from "../foundation/Errors.sol";
import { IRewardConfig } from "./IRewardConfig.sol";

/// @title RewardConfig
/// @notice Block reward rate schedule
/// @dev Initialized at genesis, updatable via governance (GOVERNANCE).
///      Uses the pending config pattern: a new schedule is queued and applied at the next epoch
///      boundary, after the closing epoch's rewards were paid with the old one.
///      Decay is always counted from when rewards started (RewardDistributor.startTimeMicros), also
///      for a schedule set later: a new schedule takes effect already decayed for the time elapsed.
contract RewardConfig is IRewardConfig {
    // ========================================================================
    // CONSTANTS
    // ========================================================================

    /// @notice Largest allowed yearly rate: 20% of stake
    uint64 public constant MAX_RATE_BPS = 2000;

    /// @notice Shortest allowed decay period: one day
    /// @dev Keeps `rateBpsAt` cheap and the schedule meaningful.
    uint64 public constant MIN_DECAY_PERIOD_MICROS = uint64(1 days) * 1_000_000;

    // ========================================================================
    // STATE
    // ========================================================================

    RewardSchedule private _schedule;

    RewardSchedule private _pendingSchedule;

    /// @notice Whether a pending schedule exists
    bool public hasPendingConfig;

    bool private _initialized;

    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when the schedule changes (at genesis or at an epoch boundary)
    event RewardScheduleUpdated(RewardSchedule schedule);

    /// @notice Emitted when governance queues a schedule for the next epoch
    event PendingRewardScheduleSet(RewardSchedule schedule);

    /// @notice Emitted when the pending schedule is applied
    event PendingRewardScheduleCleared();

    // ========================================================================
    // INITIALIZATION
    // ========================================================================

    /// @notice Initialize the schedule
    /// @dev Can only be called once by GENESIS
    function initialize(
        RewardSchedule calldata schedule
    ) external {
        requireAllowed(SystemAddresses.GENESIS);
        if (_initialized) {
            revert Errors.RewardConfigAlreadyInitialized();
        }
        _validate(schedule);
        _schedule = schedule;
        _initialized = true;
        emit RewardScheduleUpdated(schedule);
    }

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @notice Whether the contract has been initialized
    function isInitialized() external view returns (bool) {
        return _initialized;
    }

    /// @inheritdoc IRewardConfig
    function getSchedule() external view returns (RewardSchedule memory) {
        _requireInitialized();
        return _schedule;
    }

    /// @notice The pending schedule, if any
    function getPendingConfig() external view returns (bool hasPending, RewardSchedule memory schedule) {
        _requireInitialized();
        return (hasPendingConfig, _pendingSchedule);
    }

    /// @inheritdoc IRewardConfig
    /// @dev Integer basis-point arithmetic, applied once per whole elapsed period. Each step strictly
    ///      lowers a positive rate while `decayNumerator < decayDenominator`, so the loop runs at most
    ///      `initialRateBps` (<= MAX_RATE_BPS) times.
    function rateBpsAt(
        uint64 elapsedMicros
    ) external view returns (uint64) {
        _requireInitialized();
        RewardSchedule memory s = _schedule;
        // uint256: rate * decayNumerator can exceed uint64 for large numerator/denominator pairs
        uint256 rate = s.initialRateBps;
        if (s.decayNumerator < s.decayDenominator) {
            uint64 periods = elapsedMicros / s.decayPeriodMicros;
            while (periods > 0 && rate > s.floorRateBps) {
                rate = rate * s.decayNumerator / s.decayDenominator;
                periods--;
            }
        }
        return rate < s.floorRateBps ? s.floorRateBps : uint64(rate);
    }

    // ========================================================================
    // GOVERNANCE FUNCTIONS (GOVERNANCE only)
    // ========================================================================

    /// @notice Queue a schedule for the next epoch
    function setForNextEpoch(
        RewardSchedule calldata schedule
    ) external {
        requireAllowed(SystemAddresses.GOVERNANCE);
        _requireInitialized();
        _validate(schedule);
        _pendingSchedule = schedule;
        hasPendingConfig = true;
        emit PendingRewardScheduleSet(schedule);
    }

    // ========================================================================
    // EPOCH TRANSITION (RECONFIGURATION only)
    // ========================================================================

    /// @notice Apply the pending schedule at the epoch boundary
    /// @dev No-op without a pending schedule, and before initialization (so an uninitialized
    ///      RewardConfig never blocks an epoch transition)
    function applyPendingConfig() external {
        requireAllowed(SystemAddresses.RECONFIGURATION);
        if (!_initialized || !hasPendingConfig) {
            return;
        }
        _schedule = _pendingSchedule;
        hasPendingConfig = false;
        delete _pendingSchedule;
        emit RewardScheduleUpdated(_schedule);
        emit PendingRewardScheduleCleared();
    }

    // ========================================================================
    // INTERNAL FUNCTIONS
    // ========================================================================

    function _validate(
        RewardSchedule calldata s
    ) internal pure {
        if (s.initialRateBps > MAX_RATE_BPS || s.floorRateBps > s.initialRateBps) {
            revert Errors.InvalidRewardRate(s.initialRateBps, s.floorRateBps, MAX_RATE_BPS);
        }
        if (
            s.decayDenominator == 0 || s.decayNumerator > s.decayDenominator
                || s.decayPeriodMicros < MIN_DECAY_PERIOD_MICROS
        ) {
            revert Errors.InvalidRewardDecay(s.decayNumerator, s.decayDenominator, s.decayPeriodMicros);
        }
    }

    function _requireInitialized() internal view {
        if (!_initialized) {
            revert Errors.RewardConfigNotInitialized();
        }
    }
}
