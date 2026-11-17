// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test, Vm } from "forge-std/Test.sol";
import { RewardDistributor } from "src/blocker/RewardDistributor.sol";
import { RewardConfig } from "src/runtime/RewardConfig.sol";
import { IRewardConfig } from "src/runtime/IRewardConfig.sol";
import { EpochConfig } from "src/runtime/EpochConfig.sol";
import { Timestamp } from "src/runtime/Timestamp.sol";
import { IValidatorPerformanceTracker } from "src/blocker/IValidatorPerformanceTracker.sol";
import { SystemAddresses } from "src/foundation/SystemAddresses.sol";
import { ValidatorConsensusInfo } from "src/foundation/Types.sol";
import { NotAllowed } from "src/foundation/SystemAccessControl.sol";

contract MockReconfigurationForRewards {
    uint64 public lastReconfigurationTime;
    uint64 public currentEpoch;

    function set(
        uint64 last,
        uint64 epoch
    ) external {
        lastReconfigurationTime = last;
        currentEpoch = epoch;
    }
}

contract MockValidatorSet {
    ValidatorConsensusInfo[] internal _validators;

    function add(
        address pool,
        uint256 power,
        uint64 index
    ) external {
        _validators.push(ValidatorConsensusInfo(pool, "", "", power, index, "", ""));
    }

    /// Adds a validator with key material and addresses of realistic sizes
    function addFull(
        address pool,
        uint256 power,
        uint64 index
    ) external {
        _validators.push(
            ValidatorConsensusInfo(pool, new bytes(48), new bytes(96), power, index, new bytes(60), new bytes(60))
        );
    }

    function getActiveValidators() external view returns (ValidatorConsensusInfo[] memory) {
        return _validators;
    }
}

contract MockPerformance {
    IValidatorPerformanceTracker.IndividualPerformance[] internal _perf;

    function add(
        uint64 successful,
        uint64 failed
    ) external {
        _perf.push(IValidatorPerformanceTracker.IndividualPerformance(successful, failed));
    }

    function getAllPerformances() external view returns (IValidatorPerformanceTracker.IndividualPerformance[] memory) {
        return _perf;
    }
}

/// @notice Stands in for the native mint precompile: only the distributor may mint; records mints and
///         answers abi-encoded true. Kept to one storage write so it fits the distributor's per-mint
///         gas like the real precompile (9000 gas).
contract MockMint {
    mapping(address => uint256) public minted;

    fallback(
        bytes calldata data
    ) external returns (bytes memory) {
        require(msg.sender == SystemAddresses.REWARD_DISTRIBUTOR, "caller");
        require(data.length == 53 && uint8(data[0]) == 1, "bad input");
        minted[address(bytes20(data[1:21]))] += uint256(bytes32(data[21:53]));
        return abi.encode(true);
    }
}

/// @notice A precompile that rejects every mint
contract RejectingMint {
    fallback() external {
        revert("nope");
    }
}

/// @notice A precompile that halts, consuming all the gas it was given (like a failing precompile)
contract HaltingMint {
    fallback() external {
        assembly {
            invalid()
        }
    }
}

contract RewardDistributorTest is Test {
    RewardDistributor distributor;
    MockReconfigurationForRewards reconfig;
    MockValidatorSet validatorSet;
    MockPerformance performance;
    Timestamp timestamp;

    uint64 constant YEAR = 31_556_952_000_000;
    uint64 constant TWO_HOURS = uint64(2 hours) * 1_000_000;
    uint64 constant T0 = 1_800_000_000_000_000; // chain start, microseconds

    address pool1 = address(0x1001);
    address pool2 = address(0x1002);
    address pool3 = address(0x1003);

    function setUp() public {
        vm.etch(SystemAddresses.REWARD_DISTRIBUTOR, address(new RewardDistributor()).code);
        distributor = RewardDistributor(SystemAddresses.REWARD_DISTRIBUTOR);

        vm.etch(SystemAddresses.RECONFIGURATION, address(new MockReconfigurationForRewards()).code);
        reconfig = MockReconfigurationForRewards(SystemAddresses.RECONFIGURATION);
        vm.etch(SystemAddresses.VALIDATOR_MANAGER, address(new MockValidatorSet()).code);
        validatorSet = MockValidatorSet(SystemAddresses.VALIDATOR_MANAGER);
        vm.etch(SystemAddresses.PERFORMANCE_TRACKER, address(new MockPerformance()).code);
        performance = MockPerformance(SystemAddresses.PERFORMANCE_TRACKER);
        vm.etch(SystemAddresses.NATIVE_MINT_PRECOMPILE, address(new MockMint()).code);

        vm.etch(SystemAddresses.TIMESTAMP, address(new Timestamp()).code);
        timestamp = Timestamp(SystemAddresses.TIMESTAMP);

        vm.etch(SystemAddresses.EPOCH_CONFIG, address(new EpochConfig()).code);
        vm.prank(SystemAddresses.GENESIS);
        EpochConfig(SystemAddresses.EPOCH_CONFIG).initialize(TWO_HOURS);

        vm.etch(SystemAddresses.REWARD_CONFIG, address(new RewardConfig()).code);
        vm.prank(SystemAddresses.GENESIS);
        RewardConfig(SystemAddresses.REWARD_CONFIG).initialize(IRewardConfig.RewardSchedule(800, 250, 7, 8, YEAR));
    }

    function _setTime(
        uint64 micros
    ) internal {
        vm.prank(SystemAddresses.BLOCK);
        timestamp.updateGlobalTime(address(0x1), micros);
    }

    function _distribute() internal {
        vm.prank(SystemAddresses.RECONFIGURATION);
        distributor.distributeEpochRewards();
    }

    function _minted(
        address pool
    ) internal view returns (uint256) {
        return MockMint(payable(SystemAddresses.NATIVE_MINT_PRECOMPILE)).minted(pool);
    }

    function _expected(
        uint256 power,
        uint256 rateBps,
        uint256 elapsed,
        uint256 successful,
        uint256 failed
    ) internal pure returns (uint256) {
        return power * rateBps * elapsed * successful / (10_000 * uint256(YEAR) * (successful + failed));
    }

    function test_RevertWhen_NotReconfiguration() public {
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, address(this), SystemAddresses.RECONFIGURATION));
        distributor.distributeEpochRewards();
    }

    function test_GenesisEpochPaysNothing() public {
        validatorSet.add(pool1, 100 ether, 0);
        performance.add(1, 0);
        _setTime(T0);
        reconfig.set(0, 0);
        _distribute();
        assertEq(_minted(pool1), 0);
        assertEq(distributor.startTimeMicros(), 0);
    }

    function test_PaysByPowerAndPerformance() public {
        validatorSet.add(pool1, 100 ether, 0);
        validatorSet.add(pool2, 300 ether, 1);
        validatorSet.add(pool3, 50 ether, 2);
        performance.add(10, 0); // all rounds proposed
        performance.add(5, 5); // half
        performance.add(0, 7); // none: nothing
        reconfig.set(T0, 3);
        _setTime(T0 + TWO_HOURS);

        vm.recordLogs();
        _distribute();

        uint256 r1 = _expected(100 ether, 800, TWO_HOURS, 10, 0);
        uint256 r2 = _expected(300 ether, 800, TWO_HOURS, 5, 5);
        assertEq(_minted(pool1), r1);
        assertEq(_minted(pool2), r2);
        assertEq(_minted(pool3), 0);
        assertEq(distributor.startTimeMicros(), T0);
        // 100 ether at 8% a year for two hours
        uint256 stake = 100 ether;
        assertApproxEqRel(r1, stake * 8 * 7200 / (100 * 31_556_952), 1e12);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory last = logs[logs.length - 1];
        assertEq(last.topics[0], RewardDistributor.EpochRewardsDistributed.selector);
        assertEq(uint256(last.topics[1]), 3);
        (uint256 total, uint64 rate, uint64 elapsed) = abi.decode(last.data, (uint256, uint64, uint64));
        assertEq(total, r1 + r2);
        assertEq(rate, 800);
        assertEq(elapsed, TWO_HOURS);
    }

    function test_ValidatorWithoutRoundsGetsNothing() public {
        validatorSet.add(pool1, 100 ether, 0);
        performance.add(0, 0);
        reconfig.set(T0, 1);
        _setTime(T0 + TWO_HOURS);
        _distribute();
        assertEq(_minted(pool1), 0);
    }

    function test_IndexOutsidePerformanceIsSkipped() public {
        validatorSet.add(pool1, 100 ether, 5);
        performance.add(10, 0);
        reconfig.set(T0, 1);
        _setTime(T0 + TWO_HOURS);
        _distribute();
        assertEq(_minted(pool1), 0);
    }

    function test_ElapsedCappedAtEpochInterval() public {
        validatorSet.add(pool1, 100 ether, 0);
        performance.add(10, 0);
        reconfig.set(T0, 1);
        _setTime(T0 + 10 * TWO_HOURS); // the chain stalled
        _distribute();
        assertEq(_minted(pool1), _expected(100 ether, 800, TWO_HOURS, 10, 0));
    }

    function test_ShortEpochPaysProportionally() public {
        validatorSet.add(pool1, 100 ether, 0);
        performance.add(10, 0);
        reconfig.set(T0, 1);
        _setTime(T0 + TWO_HOURS / 4);
        _distribute();
        assertEq(_minted(pool1), _expected(100 ether, 800, TWO_HOURS / 4, 10, 0));
    }

    function test_RateDecaysFromFirstEpochStart() public {
        validatorSet.add(pool1, 100 ether, 0);
        performance.add(10, 0);

        reconfig.set(T0, 1);
        _setTime(T0 + TWO_HOURS);
        _distribute();
        uint256 first = _minted(pool1);
        assertEq(first, _expected(100 ether, 800, TWO_HOURS, 10, 0));

        // An epoch starting two years later pays at 612 bps
        uint64 later = T0 + 2 * YEAR;
        reconfig.set(later, 2);
        _setTime(later + TWO_HOURS);
        _distribute();
        assertEq(_minted(pool1) - first, _expected(100 ether, 612, TWO_HOURS, 10, 0));
        assertEq(distributor.startTimeMicros(), T0, "start time is fixed at the first rewarded epoch");
    }

    function test_ZeroRatePaysNothing() public {
        vm.prank(SystemAddresses.GOVERNANCE);
        RewardConfig(SystemAddresses.REWARD_CONFIG).setForNextEpoch(IRewardConfig.RewardSchedule(0, 0, 1, 1, YEAR));
        vm.prank(SystemAddresses.RECONFIGURATION);
        RewardConfig(SystemAddresses.REWARD_CONFIG).applyPendingConfig();

        validatorSet.add(pool1, 100 ether, 0);
        performance.add(10, 0);
        reconfig.set(T0, 1);
        _setTime(T0 + TWO_HOURS);
        _distribute();
        assertEq(_minted(pool1), 0);
    }

    function test_RejectedMintIsReportedAndSkipped() public {
        vm.etch(SystemAddresses.NATIVE_MINT_PRECOMPILE, address(new RejectingMint()).code);
        validatorSet.add(pool1, 100 ether, 0);
        performance.add(10, 0);
        reconfig.set(T0, 1);
        _setTime(T0 + TWO_HOURS);

        uint256 amount = _expected(100 ether, 800, TWO_HOURS, 10, 0);
        vm.expectEmit(true, true, false, true, SystemAddresses.REWARD_DISTRIBUTOR);
        emit RewardDistributor.RewardMintFailed(1, pool1, amount);
        vm.expectEmit(true, false, false, true, SystemAddresses.REWARD_DISTRIBUTOR);
        emit RewardDistributor.EpochRewardsDistributed(1, 0, 800, TWO_HOURS);
        _distribute();
    }

    /// A call to an address without code "succeeds" with no return data; that must not count as minted.
    function test_MissingPrecompileIsReportedAndSkipped() public {
        vm.etch(SystemAddresses.NATIVE_MINT_PRECOMPILE, "");
        validatorSet.add(pool1, 100 ether, 0);
        performance.add(10, 0);
        reconfig.set(T0, 1);
        _setTime(T0 + TWO_HOURS);

        uint256 amount = _expected(100 ether, 800, TWO_HOURS, 10, 0);
        vm.expectEmit(true, true, false, true, SystemAddresses.REWARD_DISTRIBUTOR);
        emit RewardDistributor.RewardMintFailed(1, pool1, amount);
        _distribute();
    }

    /// A halting mint consumes only its own capped gas: the other validators are still paid.
    function test_HaltingMintDoesNotStarveOthers() public {
        vm.etch(SystemAddresses.NATIVE_MINT_PRECOMPILE, address(new HaltingMint()).code);
        for (uint64 i = 0; i < 100; i++) {
            validatorSet.add(address(uint160(0x2000 + i)), 100 ether, i);
            performance.add(10, 0);
        }
        reconfig.set(T0, 1);
        _setTime(T0 + TWO_HOURS);

        vm.recordLogs();
        vm.prank(SystemAddresses.RECONFIGURATION);
        distributor.distributeEpochRewards{ gas: 10_000_000 }();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 failed;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == RewardDistributor.RewardMintFailed.selector) failed++;
        }
        assertEq(failed, 100, "every validator reported, none starved of gas");
        assertEq(logs[logs.length - 1].topics[0], RewardDistributor.EpochRewardsDistributed.selector);
    }

    /// Paying a full validator set (100) stays well inside the gas Reconfiguration gives it.
    function test_GasForFullValidatorSet() public {
        for (uint64 i = 0; i < 100; i++) {
            validatorSet.addFull(address(uint160(0x2000 + i)), 100 ether, i);
            performance.add(10, 1);
        }
        reconfig.set(T0, 1);
        _setTime(T0 + TWO_HOURS);

        uint256 before = gasleft();
        _distribute();
        uint256 used = before - gasleft();
        emit log_named_uint("gas for 100 validators", used);
        assertLt(used, 5_000_000);
        assertGt(_minted(address(uint160(0x2000 + 99))), 0);
    }

    function testFuzz_RewardNeverExceedsMaxRateForEpoch(
        uint128 power,
        uint64 successful,
        uint64 failed,
        uint64 elapsed
    ) public {
        vm.assume(successful > 0);
        validatorSet.add(pool1, power, 0);
        performance.add(successful, failed);
        reconfig.set(T0, 1);
        _setTime(T0 + uint64(bound(elapsed, 1, 100 * uint256(TWO_HOURS))));
        _distribute();
        // At most 8% a year of the stake, for at most one epoch interval
        assertLe(_minted(pool1), uint256(power) * 800 * TWO_HOURS / (10_000 * uint256(YEAR)));
    }
}
