// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { RewardConfig } from "src/runtime/RewardConfig.sol";
import { IRewardConfig } from "src/runtime/IRewardConfig.sol";
import { SystemAddresses } from "src/foundation/SystemAddresses.sol";
import { Errors } from "src/foundation/Errors.sol";
import { NotAllowed } from "src/foundation/SystemAccessControl.sol";

contract RewardConfigTest is Test {
    RewardConfig config;

    uint64 constant YEAR = 31_556_952_000_000;
    uint64 constant DAY = uint64(1 days) * 1_000_000;

    function _mainnet() internal pure returns (IRewardConfig.RewardSchedule memory) {
        return IRewardConfig.RewardSchedule(800, 250, 7, 8, YEAR);
    }

    function setUp() public {
        vm.etch(SystemAddresses.REWARD_CONFIG, address(new RewardConfig()).code);
        config = RewardConfig(SystemAddresses.REWARD_CONFIG);
    }

    function _init(
        IRewardConfig.RewardSchedule memory s
    ) internal {
        vm.prank(SystemAddresses.GENESIS);
        config.initialize(s);
    }

    function test_Initialize() public {
        _init(_mainnet());
        assertTrue(config.isInitialized());
        IRewardConfig.RewardSchedule memory s = config.getSchedule();
        assertEq(s.initialRateBps, 800);
        assertEq(s.floorRateBps, 250);
        assertEq(s.decayNumerator, 7);
        assertEq(s.decayDenominator, 8);
        assertEq(s.decayPeriodMicros, YEAR);
    }

    function test_RevertWhen_InitializeNotGenesis() public {
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, address(this), SystemAddresses.GENESIS));
        config.initialize(_mainnet());
    }

    function test_RevertWhen_InitializeTwice() public {
        _init(_mainnet());
        vm.prank(SystemAddresses.GENESIS);
        vm.expectRevert(Errors.RewardConfigAlreadyInitialized.selector);
        config.initialize(_mainnet());
    }

    function test_RevertWhen_NotInitialized() public {
        vm.expectRevert(Errors.RewardConfigNotInitialized.selector);
        config.rateBpsAt(0);
    }

    /// The same yearly steps as the main chain's inflation schedule.
    function test_RateFollowsYearlyDecayToFloor() public {
        _init(_mainnet());
        uint64[10] memory expected = [uint64(800), 700, 612, 535, 468, 409, 357, 312, 273, 250];
        for (uint64 y = 0; y < 10; y++) {
            assertEq(config.rateBpsAt(y * YEAR), expected[y]);
            assertEq(config.rateBpsAt(y * YEAR + YEAR - 1), expected[y], "constant within a year");
        }
        assertEq(config.rateBpsAt(100 * YEAR), 250);
        assertEq(config.rateBpsAt(type(uint64).max), 250, "bounded loop at the far end");
    }

    function test_NoDecay() public {
        _init(IRewardConfig.RewardSchedule(500, 0, 1, 1, DAY));
        assertEq(config.rateBpsAt(1000 * YEAR), 500);
    }

    function test_ZeroRate() public {
        _init(IRewardConfig.RewardSchedule(0, 0, 1, 1, DAY));
        assertEq(config.rateBpsAt(0), 0);
    }

    /// Large numerator/denominator pairs (e.g. 1e18 fixed point) do not overflow.
    function test_LargeDecayFactorDoesNotOverflow() public {
        _init(IRewardConfig.RewardSchedule(2000, 0, 999_999_999_999_999_999, 1e18, DAY));
        assertEq(config.rateBpsAt(DAY), 1999);
        assertEq(config.rateBpsAt(100 * YEAR), 0);
    }

    function test_ApplyBeforeInitializeIsNoop() public {
        vm.prank(SystemAddresses.RECONFIGURATION);
        config.applyPendingConfig();
        assertFalse(config.isInitialized());
    }

    function test_RevertWhen_InvalidRate() public {
        vm.startPrank(SystemAddresses.GENESIS);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidRewardRate.selector, 2001, 0, 2000));
        config.initialize(IRewardConfig.RewardSchedule(2001, 0, 7, 8, YEAR));
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidRewardRate.selector, 100, 200, 2000));
        config.initialize(IRewardConfig.RewardSchedule(100, 200, 7, 8, YEAR));
        vm.stopPrank();
    }

    function test_RevertWhen_InvalidDecay() public {
        vm.startPrank(SystemAddresses.GENESIS);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidRewardDecay.selector, 1, 0, YEAR));
        config.initialize(IRewardConfig.RewardSchedule(800, 250, 1, 0, YEAR));
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidRewardDecay.selector, 9, 8, YEAR));
        config.initialize(IRewardConfig.RewardSchedule(800, 250, 9, 8, YEAR));
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidRewardDecay.selector, 7, 8, DAY - 1));
        config.initialize(IRewardConfig.RewardSchedule(800, 250, 7, 8, DAY - 1));
        vm.stopPrank();
    }

    function test_SetForNextEpochAppliesAtBoundary() public {
        _init(_mainnet());
        IRewardConfig.RewardSchedule memory next = IRewardConfig.RewardSchedule(400, 100, 1, 2, YEAR);

        vm.prank(SystemAddresses.GOVERNANCE);
        config.setForNextEpoch(next);
        assertTrue(config.hasPendingConfig());
        assertEq(config.getSchedule().initialRateBps, 800, "not applied before the boundary");

        vm.prank(SystemAddresses.RECONFIGURATION);
        config.applyPendingConfig();
        assertFalse(config.hasPendingConfig());
        assertEq(config.getSchedule().initialRateBps, 400);
        assertEq(config.rateBpsAt(YEAR), 200);
        assertEq(config.rateBpsAt(2 * YEAR), 100);

        // No-op without a pending schedule
        vm.prank(SystemAddresses.RECONFIGURATION);
        config.applyPendingConfig();
        assertEq(config.getSchedule().initialRateBps, 400);
    }

    function test_RevertWhen_SetForNextEpochNotGovernance() public {
        _init(_mainnet());
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, address(this), SystemAddresses.GOVERNANCE));
        config.setForNextEpoch(_mainnet());
    }

    function test_RevertWhen_SetForNextEpochInvalid() public {
        _init(_mainnet());
        vm.prank(SystemAddresses.GOVERNANCE);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidRewardRate.selector, 3000, 0, 2000));
        config.setForNextEpoch(IRewardConfig.RewardSchedule(3000, 0, 7, 8, YEAR));
    }

    function test_RevertWhen_ApplyNotReconfiguration() public {
        _init(_mainnet());
        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, address(this), SystemAddresses.RECONFIGURATION));
        config.applyPendingConfig();
    }
}
