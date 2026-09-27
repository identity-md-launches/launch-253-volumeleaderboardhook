// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    HookTestBase,
    Vm,
    IPoolManager,
    IHooks,
    PoolKey,
    PoolId,
    Currency,
    SwapParams,
    BalanceDelta,
    TickMath,
    StateLibrary,
    PoolSwapTest,
    VolumeLeaderboardHook
} from "./helpers/HookTestBase.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract SwapTest is HookTestBase {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    function test_launchRehearsalFirstBuyIntoEthlessPool() public {
        assertEq(uint160(address(hook)) & 0x3fff, 0xcc);
        (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(id);
        assertEq(price, factory.INITIAL_SQRT_PRICE_X96());
        assertEq(address(manager).balance, 0);
        assertEq(factory.seedDelta().amount0(), 0);
        assertApproxEqAbs(uint256(-int256(factory.seedDelta().amount1())), factory.SEED_VOLM(), 1);
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        BalanceDelta delta = buy(ALICE, 1 ether);
        assertEq(delta.amount0(), -1 ether);
        assertGt(delta.amount1(), 0);
        assertEq(pot(0), 0.003 ether);
        assertEq(hook.volumeOf(id, 0, ALICE), 1 ether);
        assertEq(address(manager).balance, 1 ether);
        assertEq(IPoolManager(address(manager)).currencyDelta(address(hook), Currency.wrap(address(0))), 0);
        assertLiabilities(0);
    }

    function test_exactPermissionsAndBadAddressConstructor() public {
        Hooks.Permissions memory p = hook.getHookPermissions();
        Hooks.Permissions memory wanted;
        wanted.beforeSwap = true;
        wanted.afterSwap = true;
        wanted.beforeSwapReturnDelta = true;
        wanted.afterSwapReturnDelta = true;
        assertEq(abi.encode(p), abi.encode(wanted));
        vm.expectPartialRevert(Hooks.HookAddressNotValid.selector);
        new VolumeLeaderboardHook(manager);
        vm.expectRevert(VolumeLeaderboardHook.InvalidPoolManager.selector);
        new VolumeLeaderboardHook(IPoolManager(address(0)));
    }

    function test_directCallbacksRejected() public {
        SwapParams memory params = SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1);
        vm.expectRevert(VolumeLeaderboardHook.OnlyPoolManager.selector);
        hook.beforeSwap(address(router), key, params, abi.encode(ALICE));
        vm.expectRevert(VolumeLeaderboardHook.OnlyPoolManager.selector);
        hook.afterSwap(address(router), key, params, BalanceDelta.wrap(0), abi.encode(ALICE));
        vm.expectRevert(VolumeLeaderboardHook.OnlyPoolManager.selector);
        hook.unlockCallback(abi.encode(ALICE, 1 ether));
        vm.prank(address(manager));
        vm.expectRevert(VolumeLeaderboardHook.NoPayout.selector);
        hook.unlockCallback(abi.encode(ALICE, 1 ether));
    }

    function checkMode(uint256 mode, uint256 size) internal {
        bool buying = mode < 2;
        int256 specified = (mode == 0 || mode == 2) ? -int256(size) : int256(size);
        uint256 beforePot = pot(0);
        uint256 beforeVolume = hook.volumeOf(id, 0, ALICE);
        uint256 beforeEth = address(this).balance;
        uint256 beforeTokens = token.balanceOf(address(this));
        vm.recordLogs();
        BalanceDelta delta = swap(buying, specified, abi.encode(ALICE));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        int128 coreEth;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(manager)
                    && logs[i].topics[0]
                        == keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)")
            ) {
                (coreEth,,,,,) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                found = true;
            }
        }
        assertTrue(found, "real core swap event");
        bool ethSpecified = mode == 0 || mode == 3;
        uint256 base = ethSpecified ? size : uint256(coreEth < 0 ? -int256(coreEth) : int256(coreEth));
        uint256 fee = base * 30 / 10000;
        assertEq(pot(0) - beforePot, fee);
        assertEq(hook.volumeOf(id, 0, ALICE) - beforeVolume, base);
        assertEq(int256(delta.amount0()), int256(coreEth) - int256(fee));
        assertEq(ethSpecified ? int256(delta.amount0()) : int256(delta.amount1()), specified);
        assertEq(int256(address(this).balance) - int256(beforeEth), int256(delta.amount0()));
        assertEq(int256(token.balanceOf(address(this))) - int256(beforeTokens), int256(delta.amount1()));
        assertLiabilities(0);
    }

    function test_allFourModes() public {
        buy(address(0), 1000 ether);
        for (uint256 mode; mode < 4; ++mode) {
            checkMode(mode, 1 ether);
        }
    }

    function test_dustAllModes() public {
        buy(address(0), 1000 ether);
        for (uint256 mode; mode < 4; ++mode) {
            for (uint256 size = 1; size <= 334; size += 111) {
                checkMode(mode, size);
            }
        }
    }

    function testFuzz_allFourModes(uint96 rawSize) public {
        buy(address(0), 1000 ether);
        uint256 size = bound(rawSize, 1, 100 ether);
        for (uint256 mode; mode < 4; ++mode) {
            checkMode(mode, size);
        }
    }

    function testFuzz_partialFillsRevertAllModes(uint8 rawMode) public {
        buy(address(0), 1000 ether);
        uint256 mode = rawMode % 4;
        bool buying = mode < 2;
        int256 specified = mode == 0 || mode == 2 ? -int256(100 ether) : int256(100 ether);
        (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(id);
        uint256 beforeClaims = manager.balanceOf(address(hook), 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(VolumeLeaderboardHook.PartialFill.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        router.swap{value: 200 ether}(
            key,
            SwapParams(buying, specified, buying ? price - 1 : price + 1),
            PoolSwapTest.TestSettings(false, false),
            abi.encode(ALICE)
        );
        assertEq(manager.balanceOf(address(hook), 0), beforeClaims);
        assertEq(hook.volumeOf(id, 0, ALICE), 0);
        (uint160 afterPrice,,,) = IPoolManager(address(manager)).getSlot0(id);
        assertEq(afterPrice, price);
        assertLiabilities(0);
    }

    function test_invalidAndSpoofedIdentity() public {
        bytes[5] memory invalid = [
            bytes(""), hex"01", abi.encode(address(0)), abi.encode(ALICE, BOB), abi.encode(type(uint256).max)
        ];
        for (uint256 i; i < invalid.length; ++i) {
            swap(true, -1 ether, invalid[i]);
        }
        (address[5] memory users,,,) = hook.leaderboard(id, 0);
        assertEq(users[0], address(0));
        assertEq(hook.volumeOf(id, 0, address(router)), 0);
        assertEq(pot(0), 0.015 ether);
        buy(BOB, 1 ether); // Payer is this contract, the unauthenticated identity is BOB.
        assertEq(hook.volumeOf(id, 0, BOB), 1 ether);
    }

    function test_nonEthPoolHasNoFeesOrCredits() public {
        MockERC20 a = new MockERC20("A", "A", 1_000_000 ether);
        MockERC20 b = new MockERC20("B", "B", 1_000_000 ether);
        (a, b) = address(a) < address(b) ? (a, b) : (b, a);
        PoolKey memory other =
            PoolKey(Currency.wrap(address(a)), Currency.wrap(address(b)), 3000, 60, IHooks(address(hook)));
        manager.initialize(other, 1 << 96);
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        a.approve(address(lp), type(uint256).max);
        b.approve(address(lp), type(uint256).max);
        a.approve(address(router), type(uint256).max);
        b.approve(address(router), type(uint256).max);
        lp.modifyLiquidity(other, ModifyLiquidityParams(-600, 600, 1000 ether, 0), "");
        for (uint256 mode; mode < 4; ++mode) {
            router.swap(
                other,
                SwapParams(
                    mode < 2,
                    mode % 2 == 0 ? -int256(1 ether) : int256(1 ether),
                    mode < 2 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                ),
                PoolSwapTest.TestSettings(false, false),
                abi.encode(ALICE)
            );
        }
        (address[5] memory users,, uint256 amount,) = hook.leaderboard(other.toId(), 0);
        assertEq(users[0], address(0));
        assertEq(amount, 0);
        assertEq(hook.volumeOf(other.toId(), 0, ALICE), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        // Explicitly inspect callback return deltas as well as successful real-manager swaps.
        vm.prank(address(manager));
        (, BeforeSwapDelta beforeDelta,) =
            hook.beforeSwap(address(router), other, SwapParams(true, -1 ether, 1), "");
        assertEq(BeforeSwapDelta.unwrap(beforeDelta), 0);
        vm.prank(address(manager));
        (, int128 afterDelta) =
            hook.afterSwap(address(router), other, SwapParams(true, -1 ether, 1), BalanceDelta.wrap(0), "");
        assertEq(afterDelta, 0);
    }
}
