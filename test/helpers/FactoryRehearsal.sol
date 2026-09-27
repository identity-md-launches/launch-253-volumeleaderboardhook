// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VOLM} from "../../src/VOLM.sol";
import {VolumeLeaderboardHook} from "../../src/VolumeLeaderboardHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

/// @dev Local rehearsal of factory deployment, initialization and VOLM-only seeding.
/// These explicit defaults must be matched by the separately generated launch manifest.
contract FactoryRehearsal is IUnlockCallback {
    uint160 public constant INITIAL_SQRT_PRICE_X96 = 79228162514264337593543950336;
    uint256 public constant SEED_VOLM = 100_000_000 ether;
    int24 public constant TICK_LOWER = -887220;
    int24 public constant TICK_UPPER = 0;
    IPoolManager public immutable manager;
    BalanceDelta public seedDelta;
    uint128 public seedLiquidity;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function launch(address remainderTo)
        external
        returns (VOLM token, VolumeLeaderboardHook hook, PoolKey memory key)
    {
        token = new VOLM();
        require(token.balanceOf(address(this)) == 1_000_000_000 ether, "factory supply");
        bytes32 initHash =
            keccak256(abi.encodePacked(type(VolumeLeaderboardHook).creationCode, abi.encode(manager)));
        for (uint256 i; i < 200_000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initHash))))
            );
            if (uint160(predicted) & 0x3fff != 0x00cc) continue;
            hook = new VolumeLeaderboardHook{salt: salt}(manager);
            require(address(hook) == predicted, "create2 mismatch");
            break;
        }
        require(address(hook) != address(0), "salt exhausted");
        key = PoolKey(
            Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(address(hook))
        );
        manager.initialize(key, INITIAL_SQRT_PRICE_X96);
        seedLiquidity = uint128(
            FullMath.mulDiv(
                SEED_VOLM, 1 << 96, INITIAL_SQRT_PRICE_X96 - TickMath.getSqrtPriceAtTick(TICK_LOWER)
            )
        );
        manager.unlock(abi.encode(key));
        token.transfer(remainderTo, token.balanceOf(address(this)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        PoolKey memory key = abi.decode(data, (PoolKey));
        (BalanceDelta delta,) = manager.modifyLiquidity(
            key, ModifyLiquidityParams(TICK_LOWER, TICK_UPPER, int256(uint256(seedLiquidity)), 0), ""
        );
        require(delta.amount0() == 0 && delta.amount1() < 0, "VOLM only");
        seedDelta = delta;
        manager.sync(key.currency1);
        VOLM(Currency.unwrap(key.currency1)).transfer(address(manager), uint256(-int256(delta.amount1())));
        manager.settle();
        return "";
    }
}
