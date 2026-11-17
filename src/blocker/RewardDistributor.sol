// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { SystemAddresses } from "../foundation/SystemAddresses.sol";
import { requireAllowed } from "../foundation/SystemAccessControl.sol";
import { IReconfiguration } from "./IReconfiguration.sol";
import { IValidatorPerformanceTracker } from "./IValidatorPerformanceTracker.sol";
import { IValidatorManagement } from "../staking/IValidatorManagement.sol";
import { ITimestamp } from "../runtime/ITimestamp.sol";
import { IRewardConfig } from "../runtime/IRewardConfig.sol";
import { EpochConfig } from "../runtime/EpochConfig.sol";

/// @title RewardDistributor
/// @notice Pays block rewards to validators at each epoch transition
/// @dev Called by Reconfiguration at the start of every epoch transition, while the closing epoch's
///      validator set, performance counters and configuration are still in place. For each
///      validator of the closing epoch:
///
///          reward = votingPower * rateBps / 10_000 * elapsed / year * successful / (successful + failed)
///
///      - votingPower: the validator's bond for the closing epoch (already capped at maximumBond).
///      - rateBps: RewardConfig's yearly rate for the time since rewards started.
///      - elapsed: the closing epoch's length, capped at the configured epoch interval so that a
///        stalled chain does not pay for the time it did not run.
///      - successful / failed: the validator's proposal rounds in the closing epoch. A validator
///        with no rounds gets nothing.
///
///      Rewards are new coins credited to the validator's stake pool through the native mint
///      precompile, which only this contract may call. They land in the pool's balance above its
///      tracked stake, where the staker withdraws them with `StakePool.withdrawRewards`; they do not
///      add voting power. A failed mint is reported by an event and never blocks the transition.
contract RewardDistributor {
    // ========================================================================
    // CONSTANTS
    // ========================================================================

    /// @notice Length of a year: 365.2425 days, in microseconds
    uint256 public constant MICROS_PER_YEAR = 31_556_952 * 1_000_000;

    /// @notice Basis-point denominator
    uint256 public constant BPS = 10_000;

    /// @notice Native mint precompile function selector byte
    uint8 internal constant MINT_FUNCTION_ID = 0x01;

    /// @notice Gas forwarded to each mint
    /// @dev A failing precompile consumes all the gas it is given; the cap keeps one failed mint
    ///      from using up the gas the rest of the distribution and the epoch transition need.
    uint256 public constant MINT_GAS = 30_000;

    // ========================================================================
    // STATE
    // ========================================================================

    /// @notice When rewards started: the start of the first epoch after genesis (microseconds)
    /// @dev The reward rate decays from this time. Zero until the first rewarded transition.
    uint64 public startTimeMicros;

    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice A validator was paid for an epoch
    event ValidatorRewarded(
        uint64 indexed epoch,
        address indexed stakePool,
        uint256 amount,
        uint64 successfulProposals,
        uint64 failedProposals
    );

    /// @notice Minting a validator's reward failed; the validator was not paid for this epoch
    event RewardMintFailed(uint64 indexed epoch, address indexed stakePool, uint256 amount);

    /// @notice Rewards for an epoch were distributed
    event EpochRewardsDistributed(uint64 indexed epoch, uint256 totalAmount, uint64 rateBps, uint64 elapsedMicros);

    // ========================================================================
    // EPOCH TRANSITION (RECONFIGURATION only)
    // ========================================================================

    /// @notice Pay the closing epoch's rewards
    function distributeEpochRewards() external {
        requireAllowed(SystemAddresses.RECONFIGURATION);

        IReconfiguration reconfiguration = IReconfiguration(SystemAddresses.RECONFIGURATION);
        uint64 epochStart = reconfiguration.lastReconfigurationTime();
        // The genesis epoch starts at time zero (the chain clock is set by the first block) and
        // ends at the first block: there is nothing to pay for.
        if (epochStart == 0) {
            return;
        }
        if (startTimeMicros == 0) {
            startTimeMicros = epochStart;
        }

        uint64 now_ = ITimestamp(SystemAddresses.TIMESTAMP).nowMicroseconds();
        uint64 elapsed = now_ > epochStart ? now_ - epochStart : 0;
        uint64 interval = EpochConfig(SystemAddresses.EPOCH_CONFIG).epochIntervalMicros();
        if (elapsed > interval) {
            elapsed = interval;
        }
        uint64 rateBps = IRewardConfig(SystemAddresses.REWARD_CONFIG).rateBpsAt(epochStart - startTimeMicros);
        uint64 epoch = reconfiguration.currentEpoch();
        if (rateBps == 0 || elapsed == 0) {
            emit EpochRewardsDistributed(epoch, 0, rateBps, elapsed);
            return;
        }

        (address[] memory pools, uint256[] memory bonds, uint64[] memory indices) =
            IValidatorManagement(SystemAddresses.VALIDATOR_MANAGER).getActiveValidatorBonds();
        IValidatorPerformanceTracker.IndividualPerformance[] memory performances =
            IValidatorPerformanceTracker(SystemAddresses.PERFORMANCE_TRACKER).getAllPerformances();

        uint256 total;
        uint256 len = pools.length;
        for (uint256 i = 0; i < len; i++) {
            if (indices[i] >= performances.length) {
                continue;
            }
            IValidatorPerformanceTracker.IndividualPerformance memory p = performances[indices[i]];
            uint256 rounds = uint256(p.successfulProposals) + uint256(p.failedProposals);
            if (p.successfulProposals == 0) {
                continue;
            }
            uint256 amount = bonds[i] * rateBps * elapsed * p.successfulProposals / (BPS * MICROS_PER_YEAR * rounds);
            if (amount == 0) {
                continue;
            }
            if (_mint(pools[i], amount)) {
                total += amount;
                emit ValidatorRewarded(epoch, pools[i], amount, p.successfulProposals, p.failedProposals);
            } else {
                emit RewardMintFailed(epoch, pools[i], amount);
            }
        }

        emit EpochRewardsDistributed(epoch, total, rateBps, elapsed);
    }

    // ========================================================================
    // INTERNAL FUNCTIONS
    // ========================================================================

    /// @dev The precompile answers a successful mint with abi-encoded `true`. Anything else, including
    ///      the empty success a call to an account without code returns, counts as failure.
    function _mint(
        address recipient,
        uint256 amount
    ) internal returns (bool) {
        (bool ok, bytes memory ret) = SystemAddresses.NATIVE_MINT_PRECOMPILE.call{ gas: MINT_GAS }(
            abi.encodePacked(MINT_FUNCTION_ID, recipient, amount)
        );
        return ok && ret.length == 32 && abi.decode(ret, (bool));
    }
}
