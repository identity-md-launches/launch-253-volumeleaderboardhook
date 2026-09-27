// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    HookTestBase,
    VolumeLeaderboardHook,
    PoolKey,
    PoolId,
    Currency,
    IHooks,
    IPoolManager
} from "./helpers/HookTestBase.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

contract ToggleReceiver {
    bool public reject = true;

    function allow() external {
        reject = false;
    }

    receive() external payable {
        require(!reject, "reject ETH");
    }
}

contract ReenterReceiver {
    VolumeLeaderboardHook internal hook;
    PoolKey internal key;
    bool public blocked;

    constructor(VolumeLeaderboardHook hook_, PoolKey memory key_) {
        hook = hook_;
        key = key_;
    }

    receive() external payable {
        (bool ok, bytes memory error) = address(hook).call(abi.encodeCall(hook.claim, (key, 0, 1)));
        blocked = !ok
            && keccak256(error)
                == keccak256(abi.encodeWithSelector(VolumeLeaderboardHook.ReentrantClaim.selector));
    }
}

contract EpochTest is HookTestBase {
    function test_epochBoundarySecondAndFrozenPot() public {
        uint256 end = hook.epochEnd(0);
        assertEq(end, hook.DEPLOY_TIME() + 7 days);
        vm.warp(end - 1);
        buy(ALICE, 1 ether);
        assertEq(hook.epochNow(), 0);
        vm.expectRevert(VolumeLeaderboardHook.EpochNotEnded.selector);
        hook.claim(key, 0, 1);
        vm.expectRevert(VolumeLeaderboardHook.EpochNotEnded.selector);
        hook.finalize(key, 0);
        vm.warp(end);
        buy(BOB, 2 ether);
        assertEq(hook.epochNow(), 1);
        assertEq(hook.volumeOf(id, 0, BOB), 0);
        assertEq(hook.volumeOf(id, 1, BOB), 2 ether);
        assertEq(pot(0), 0.003 ether);
        assertEq(pot(1), 0.006 ether);
        hook.finalize(key, 0);
        assertEq(pot(0), 0.003 ether);
        assertEq(pot(1), 0.006 ether + 0.0018 ether);
        hook.claim(key, 0, 1);
        assertEq(pot(0), 0.003 ether);
        assertEq(ALICE.balance, 0.0012 ether);
        assertLiabilities(1);
    }

    function test_tiesIncumbentClimbEvictionAndReentry() public {
        for (uint160 i = 1; i <= 6; ++i) {
            buy(address(i + 100), 1 ether);
        }
        (address[5] memory users, uint256[5] memory totals,,) = hook.leaderboard(id, 0);
        for (uint160 i; i < 5; ++i) {
            assertEq(users[i], address(i + 101));
            assertEq(totals[i], 1 ether);
        }
        buy(address(105), 1 ether); // Existing fifth climbs; no duplicate remains.
        (users, totals,,) = hook.leaderboard(id, 0);
        assertEq(users[0], address(105));
        assertEq(users[4], address(104));
        buy(address(106), 1 ether); // Sixth ties first, enters second, evicts 104.
        (users, totals,,) = hook.leaderboard(id, 0);
        assertEq(users[0], address(105));
        assertEq(users[1], address(106));
        buy(address(104), 2 ether); // Previously evicted identity keeps its accumulated volume.
        (users, totals,,) = hook.leaderboard(id, 0);
        assertEq(users[0], address(104));
        assertEq(totals[0], 3 ether);
        assertEq(users[1], address(105));
        assertEq(users[2], address(106));
        for (uint256 i; i < 5; ++i) {
            for (uint256 j = i + 1; j < 5; ++j) {
                assertTrue(users[i] != users[j]);
            }
        }
    }

    function settleParticipants(uint256 participants, bool finalizeFirst, uint256 amount) internal {
        // The unattributed fee makes zero-participant and indivisible-pot cases nontrivial.
        buy(address(0), 34_337);
        for (uint160 i; i < participants; ++i) {
            buy(address(i + 101), amount + i * 334);
        }
        uint256 originalPot = pot(0);
        vm.warp(hook.epochEnd(2)); // Carry goes to epoch current at call (3), not epoch 1.
        uint256 paid;
        if (finalizeFirst) hook.finalize(key, 0);
        (address[5] memory users,,,) = hook.leaderboard(id, 0);
        for (uint256 rank = 1; rank <= 5; ++rank) {
            if (users[rank - 1] == address(0)) {
                vm.expectRevert(VolumeLeaderboardHook.EmptyRank.selector);
                hook.claim(key, 0, rank);
            } else {
                uint256 beforeEth = users[rank - 1].balance;
                hook.claim(key, 0, rank);
                uint256 received = users[rank - 1].balance - beforeEth;
                assertEq(received, share(originalPot, rank - 1));
                paid += received;
                vm.expectRevert(VolumeLeaderboardHook.AlreadyClaimed.selector);
                hook.claim(key, 0, rank);
            }
            assertLiabilities(3);
        }
        if (!finalizeFirst) hook.finalize(key, 0);
        assertEq(paid + pot(3), originalPot, "every wei paid or carried");
        assertEq(pot(0), originalPot, "source pot frozen");
        assertEq(pot(1), 0);
        vm.expectRevert(VolumeLeaderboardHook.AlreadyFinalized.selector);
        hook.finalize(key, 0);
        assertLiabilities(3);
    }

    function test_zeroParticipants() public {
        settleParticipants(0, true, 1 ether);
    }

    function test_oneParticipantClaimFirst() public {
        settleParticipants(1, false, 1 ether + 667);
    }

    function test_oneParticipantFinalizeFirst() public {
        settleParticipants(1, true, 1 ether + 667);
    }

    function test_fiveParticipants() public {
        settleParticipants(5, false, 1 ether + 667);
    }

    function test_moreThanFiveParticipants() public {
        settleParticipants(9, true, 1 ether + 667);
    }

    function testFuzz_claimsPlusCarryExactlyPot(uint8 count, bool finalizeFirst, uint64 size) public {
        settleParticipants(count % 10, finalizeFirst, bound(size, 1, 10 ether));
    }

    function test_neverUsedEpochAndZeroValueClaim() public {
        buy(ALICE, 1);
        assertEq(pot(0), 0);
        vm.warp(hook.epochEnd(1));
        hook.finalize(key, 1);
        hook.claim(key, 0, 1);
        hook.finalize(key, 0);
        (,,, bool[5] memory claimed) = hook.leaderboard(id, 0);
        assertTrue(claimed[0]);
        assertLiabilities(2);
    }

    function test_rejectingRecipientOnlyBlocksOwnShareAndCanRetry() public {
        ToggleReceiver receiver = new ToggleReceiver();
        buy(address(receiver), 2 ether);
        buy(ALICE, 1 ether);
        vm.warp(hook.epochEnd(0));
        uint256 beforeClaims = manager.balanceOf(address(hook), 0);
        vm.expectRevert();
        hook.claim(key, 0, 1);
        (,,, bool[5] memory claimed) = hook.leaderboard(id, 0);
        assertFalse(claimed[0]);
        assertEq(manager.balanceOf(address(hook), 0), beforeClaims);
        hook.claim(key, 0, 2);
        hook.finalize(key, 0);
        assertLiabilities(1);
        receiver.allow();
        hook.claim(key, 0, 1);
        assertEq(address(receiver).balance, share(pot(0), 0));
        assertLiabilities(1);
    }

    function test_recipientCannotReenterClaim() public {
        ReenterReceiver receiver = new ReenterReceiver(hook, key);
        buy(address(receiver), 1 ether);
        vm.warp(hook.epochEnd(0));
        hook.claim(key, 0, 1);
        assertTrue(receiver.blocked());
        assertEq(address(receiver).balance, share(pot(0), 0));
        assertLiabilities(1);
    }

    function test_invalidRanksAndPool() public {
        buy(ALICE, 1 ether);
        vm.warp(hook.epochEnd(0));
        vm.expectRevert(VolumeLeaderboardHook.InvalidRank.selector);
        hook.claim(key, 0, 0);
        vm.expectRevert(VolumeLeaderboardHook.InvalidRank.selector);
        hook.claim(key, 0, 6);
        PoolKey memory invalid = key;
        invalid.hooks = IHooks(address(0));
        vm.expectRevert(VolumeLeaderboardHook.InvalidPool.selector);
        hook.claim(invalid, 0, 1);
        invalid = key;
        invalid.currency0 = Currency.wrap(address(token));
        vm.expectRevert(VolumeLeaderboardHook.InvalidPool.selector);
        hook.finalize(invalid, 0);
        vm.expectRevert(VolumeLeaderboardHook.EpochNotEnded.selector);
        hook.finalize(key, type(uint256).max);
    }

    function test_poolsHaveIndependentEpochAccounting() public {
        PoolKey memory other = key;
        other.fee = 500;
        other.tickSpacing = 10;
        manager.initialize(other, 1 << 96);
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        token.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(other, ModifyLiquidityParams(-887220, 0, 1000 ether, 0), "");
        buy(ALICE, 1 ether);
        PoolKey memory original = key;
        key = other;
        buy(BOB, 2 ether);
        key = original;
        assertEq(hook.volumeOf(id, 0, BOB), 0);
        assertEq(hook.volumeOf(other.toId(), 0, ALICE), 0);
        vm.warp(hook.epochEnd(0));
        hook.finalize(other, 0);
        hook.claim(other, 0, 1);
        assertEq(pot(1), 0);
        assertEq(pot(0), 0.003 ether);
        (,, uint256 otherCarry,) = hook.leaderboard(other.toId(), 1);
        assertEq(otherCarry, 0.0036 ether);
        assertEq(manager.balanceOf(address(hook), 0), pot(0) + otherCarry);
    }

    function test_events() public {
        vm.expectEmit(true, true, true, true, address(hook));
        emit VolumeLeaderboardHook.Credited(id, 0, ALICE, 1 ether, 1 ether);
        buy(ALICE, 1 ether);
        vm.warp(hook.epochEnd(0));
        vm.expectEmit(true, true, true, true, address(hook));
        emit VolumeLeaderboardHook.Claimed(id, 0, 1, ALICE, 0.0012 ether);
        hook.claim(key, 0, 1);
        vm.expectEmit(true, true, true, true, address(hook));
        emit VolumeLeaderboardHook.EpochFinalized(id, 0, 1, 0.0018 ether);
        hook.finalize(key, 0);
    }
}
