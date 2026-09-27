// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

/// @notice Weekly, per-pool ETH volume leaderboard, funded by a 30 bps ETH-leg fee.
/// @dev Identity is unauthenticated hookData, suitable only for the specified Sepolia toy.
/// Fees are ERC-6909 claims, never ETH transfers inside swap callbacks.
contract VolumeLeaderboardHook is IUnlockCallback {
    using PoolIdLibrary for PoolKey;

    uint256 public constant FEE_BPS = 30;
    uint256 public constant EPOCH_LENGTH = 7 days;
    uint256 public immutable DEPLOY_TIME;
    IPoolManager public immutable poolManager;

    struct Epoch {
        address[5] users;
        uint256[5] volumes;
        uint256 pot;
        bool[5] claimed;
        bool finalized;
    }

    mapping(PoolId => mapping(uint256 => Epoch)) private epochs;
    mapping(PoolId => mapping(uint256 => mapping(address => uint256))) private volumes;
    bool private paying;

    error OnlyPoolManager();
    error InvalidPoolManager();
    error PartialFill();
    error AmountTooLarge();
    error EpochNotEnded();
    error InvalidRank();
    error EmptyRank();
    error AlreadyClaimed();
    error AlreadyFinalized();
    error InvalidPool();
    error ReentrantClaim();
    error NoPayout();

    event Credited(
        PoolId indexed poolId,
        uint256 indexed epoch,
        address indexed user,
        uint256 ethVolume,
        uint256 totalVolume
    );
    event Claimed(
        PoolId indexed poolId, uint256 indexed epoch, uint256 rank, address indexed recipient, uint256 amount
    );
    event EpochFinalized(
        PoolId indexed poolId, uint256 indexed epoch, uint256 indexed destinationEpoch, uint256 carry
    );

    constructor(IPoolManager manager) {
        if (address(manager) == address(0)) revert InvalidPoolManager();
        poolManager = manager;
        DEPLOY_TIME = block.timestamp;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    modifier noReentry() {
        if (paying) revert ReentrantClaim();
        paying = true;
        _;
        paying = false;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    function epochNow() public view returns (uint256) {
        return (block.timestamp - DEPLOY_TIME) / EPOCH_LENGTH;
    }

    function epochEnd(uint256 epoch) external view returns (uint256) {
        return DEPLOY_TIME + (epoch + 1) * EPOCH_LENGTH;
    }

    function leaderboard(PoolId poolId, uint256 epoch)
        external
        view
        returns (address[5] memory users, uint256[5] memory totals, uint256 pot, bool[5] memory claimed)
    {
        Epoch storage e = epochs[poolId][epoch];
        return (e.users, e.volumes, e.pot, e.claimed);
    }

    function volumeOf(PoolId poolId, uint256 epoch, address user) external view returns (uint256) {
        return volumes[poolId][epoch][user];
    }

    function isFinalized(PoolId poolId, uint256 epoch) external view returns (bool) {
        return epochs[poolId][epoch].finalized;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (!key.currency0.isAddressZero() || !_ethSpecified(params)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
        }
        uint256 fee = _magnitude(params.amountSpecified) * FEE_BPS / 10_000;
        if (fee != 0) poolManager.mint(address(this), 0, fee);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(fee)), 0), 0);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, int128) {
        if (!key.currency0.isAddressZero()) return (IHooks.afterSwap.selector, 0);

        bool ethSpecified = _ethSpecified(params);
        uint256 ethVolume = ethSpecified ? _magnitude(params.amountSpecified) : _abs(int256(delta.amount0()));
        uint256 fee = ethVolume * FEE_BPS / 10_000;
        // The core delta precedes hook charges. Adding a positive specified fee reduces
        // an exact-in buy's pool input, or increases an exact-out sell's gross pool output.
        int256 expected = params.amountSpecified + (ethSpecified ? int256(fee) : int256(0));
        int256 actual = ethSpecified ? int256(delta.amount0()) : int256(delta.amount1());
        if (actual != expected) revert PartialFill();

        if (!ethSpecified && fee != 0) poolManager.mint(address(this), 0, fee);
        PoolId id = key.toId();
        uint256 epoch = epochNow();
        epochs[id][epoch].pot += fee;
        address user = _identity(hookData);
        if (user != address(0) && ethVolume != 0) _credit(id, epoch, user, ethVolume);
        return (IHooks.afterSwap.selector, ethSpecified ? int128(0) : int128(uint128(fee)));
    }

    /// @notice Ranks are 1..5. Anyone can trigger payment, always to the recorded winner.
    function claim(PoolKey calldata key, uint256 epoch, uint256 rank) external noReentry {
        _validateEnded(key, epoch);
        if (rank == 0 || rank > 5) revert InvalidRank();
        Epoch storage e = epochs[key.toId()][epoch];
        uint256 i = rank - 1;
        address recipient = e.users[i];
        if (recipient == address(0)) revert EmptyRank();
        if (e.claimed[i]) revert AlreadyClaimed();
        uint256 amount = _share(e.pot, i);
        e.claimed[i] = true;
        // No entitlement remains before external interaction. A failed transfer atomically
        // restores this flag and the burned claims, leaving only this rank unpaid.
        if (amount != 0) poolManager.unlock(abi.encode(recipient, amount));
        emit Claimed(key.toId(), epoch, rank, recipient, amount);
    }

    /// @notice Carry empty-rank shares and every rounding wei into the current epoch.
    function finalize(PoolKey calldata key, uint256 epoch) external noReentry {
        _validateEnded(key, epoch);
        PoolId id = key.toId();
        Epoch storage e = epochs[id][epoch];
        if (e.finalized) revert AlreadyFinalized();
        e.finalized = true;
        uint256 reserved;
        for (uint256 i; i < 5; ++i) {
            if (e.users[i] != address(0)) reserved += _share(e.pot, i);
        }
        uint256 carry = e.pot - reserved;
        uint256 destination = epochNow();
        epochs[id][destination].pot += carry;
        emit EpochFinalized(id, epoch, destination, carry);
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        if (!paying) revert NoPayout();
        (address recipient, uint256 amount) = abi.decode(data, (address, uint256));
        poolManager.burn(address(this), 0, amount);
        poolManager.take(Currency.wrap(address(0)), recipient, amount);
        return "";
    }

    function _validateEnded(PoolKey calldata key, uint256 epoch) private view {
        if (!key.currency0.isAddressZero() || address(key.hooks) != address(this)) revert InvalidPool();
        if (epoch >= epochNow()) revert EpochNotEnded();
    }

    function _ethSpecified(SwapParams calldata params) private pure returns (bool) {
        return params.zeroForOne == (params.amountSpecified < 0);
    }

    function _magnitude(int256 amount) private pure returns (uint256) {
        // v4 balance deltas are int128; reject oversized requests before casting or multiplying.
        if (amount < -int256(type(int128).max) || amount > int256(type(int128).max)) {
            revert AmountTooLarge();
        }
        return _abs(amount);
    }

    function _abs(int256 amount) private pure returns (uint256) {
        return uint256(amount < 0 ? -amount : amount);
    }

    function _identity(bytes calldata data) private pure returns (address) {
        if (data.length != 32) return address(0);
        uint256 word = abi.decode(data, (uint256));
        // Noncanonical ABI addresses are invalid identities, not grounds to reject a swap.
        if (word > type(uint160).max) return address(0);
        return address(uint160(word));
    }

    function _share(uint256 pot, uint256 i) private pure returns (uint256) {
        uint256 percent = i == 0 ? 40 : i == 1 ? 25 : i == 2 ? 15 : 10;
        return (pot / 100) * percent + ((pot % 100) * percent) / 100;
    }

    function _credit(PoolId id, uint256 epoch, address user, uint256 amount) private {
        uint256 total = volumes[id][epoch][user] + amount;
        volumes[id][epoch][user] = total;
        Epoch storage e = epochs[id][epoch];
        uint256 i;
        for (; i < 5; ++i) {
            if (e.users[i] == user) break;
        }
        if (i == 5) {
            if (total <= e.volumes[4]) {
                emit Credited(id, epoch, user, amount, total);
                return;
            }
            i = 4;
        }
        // Strict comparison preserves incumbents on ties, including at the entry threshold.
        for (; i > 0 && total > e.volumes[i - 1]; --i) {
            e.users[i] = e.users[i - 1];
            e.volumes[i] = e.volumes[i - 1];
        }
        e.users[i] = user;
        e.volumes[i] = total;
        emit Credited(id, epoch, user, amount, total);
    }
}
