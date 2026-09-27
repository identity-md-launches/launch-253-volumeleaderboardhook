// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {FactoryRehearsal} from "./FactoryRehearsal.sol";
import {VOLM} from "../../src/VOLM.sol";
import {VolumeLeaderboardHook} from "../../src/VolumeLeaderboardHook.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

abstract contract HookTestBase is Test {
    using StateLibrary for IPoolManager;
    PoolManager internal manager;
    FactoryRehearsal internal factory;
    VOLM internal token;
    VolumeLeaderboardHook internal hook;
    PoolSwapTest internal router;
    PoolKey internal key;
    PoolId internal id;
    address internal constant ALICE = address(0xa11ce);
    address internal constant BOB = address(0xb0b);

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        vm.deal(address(this), 1_000_000 ether);
        manager = new PoolManager(address(this));
        factory = new FactoryRehearsal(manager);
        (token, hook, key) = factory.launch(address(this));
        id = key.toId();
        router = new PoolSwapTest(manager);
        token.approve(address(router), type(uint256).max);
    }

    function swap(bool buying, int256 specified, bytes memory identity) internal returns (BalanceDelta) {
        return router.swap{value: buying ? 100_000 ether : 0}(
            key,
            SwapParams(buying, specified, buying ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            identity
        );
    }

    function buy(address user, uint256 amount) internal returns (BalanceDelta) {
        return swap(true, -int256(amount), abi.encode(user));
    }

    function pot(uint256 epoch) internal view returns (uint256 result) {
        (,, result,) = hook.leaderboard(id, epoch);
    }

    function share(uint256 amount, uint256 index) internal pure returns (uint256) {
        uint256[5] memory rates = [uint256(40), 25, 15, 10, 10];
        return amount * rates[index] / 100;
    }

    function assertLiabilities(uint256 lastEpoch) internal view {
        uint256 liability;
        for (uint256 epoch; epoch <= lastEpoch; ++epoch) {
            (address[5] memory users,, uint256 amount, bool[5] memory claimed) = hook.leaderboard(id, epoch);
            uint256 awarded;
            uint256 paid;
            for (uint256 i; i < 5; ++i) {
                if (users[i] != address(0)) awarded += share(amount, i);
                if (claimed[i]) paid += share(amount, i);
            }
            liability += hook.isFinalized(id, epoch) ? awarded - paid : amount - paid;
        }
        assertEq(manager.balanceOf(address(hook), 0), liability, "ETH claims != liabilities");
        assertEq(address(hook).balance, 0, "hook must not hold payout ETH");
    }

    receive() external payable {}
}
