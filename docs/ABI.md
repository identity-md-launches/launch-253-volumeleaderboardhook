# Contract ABI and integration

Machine-readable compiler ABI arrays: [`VOLM.json`](abi/VOLM.json), [`VolumeLeaderboardHook.json`](abi/VolumeLeaderboardHook.json). Generate them from the pinned compiler with:

```sh
forge inspect src/VOLM.sol:VOLM abi --json > docs/abi/VOLM.json
forge inspect src/VolumeLeaderboardHook.sol:VolumeLeaderboardHook abi --json > docs/abi/VolumeLeaderboardHook.json
```

## Types

`PoolKey` is `(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks)`. PoolId is its ABI-encoded keccak256 hash (`bytes32`), not packed encoding. Native ETH is the zero address. All volume, pot, fee and payout values are wei. ERC20 VOLM has 18 decimals. Epochs start at zero. Claim ranks start at **one**; array indices start at zero.

## Token

No-argument constructor; ERC20 `name`, `symbol`, `decimals`, `totalSupply`, `balanceOf`, `allowance`, `approve`, `transfer`, `transferFrom`; standard Transfer and Approval events and ERC-6093 custom errors. There is no external mint, burn, owner, permit, or admin interface.

## Hook views

| Function | Returns / meaning |
| --- | --- |
| `poolManager()` | Immutable constructor manager |
| `DEPLOY_TIME()` | Constructor timestamp |
| `FEE_BPS()` / `EPOCH_LENGTH()` | 30 / 604800 seconds |
| `getHookPermissions()` | Exactly the four swap flags, as the v4 Permissions tuple |
| `epochNow()` | Current zero-based epoch |
| `epochEnd(uint256 epoch)` | First timestamp outside that epoch |
| `leaderboard(bytes32 poolId,uint256 epoch)` | `(address[5] users,uint256[5] totals,uint256 pot,bool[5] claimed)` |
| `volumeOf(bytes32 poolId,uint256 epoch,address user)` | Accumulated volume, including users outside top five |
| `isFinalized(bytes32 poolId,uint256 epoch)` | Whether the carry has already moved |

`leaderboard.pot` always reports the original pot for an ended epoch, even after settlement. Empty ranks have a zero address and volume. Claimable ETH for an ended nonempty rank equals `floor(pot * rankPercent / 100)` unless its claim flag is true. A zero-value nonempty rank can still be marked claimed. Use `isFinalized` to control the finalize button independently of claim flags.

## Public transactions

`claim(PoolKey key,uint256 epoch,uint256 rank)` and `finalize(PoolKey key,uint256 epoch)` return no value. The caller pays gas and receives no special privilege or bounty. A claim always pays the recorded rank address. An epoch must be strictly less than `epochNow()`. A key used for settlement must have native ETH currency0 and this hook address. An unused ended epoch can be finalized with zero carry.

## Events

```solidity
Credited(bytes32 indexed poolId, uint256 indexed epoch, address indexed user,
         uint256 ethVolume, uint256 totalVolume);
Claimed(bytes32 indexed poolId, uint256 indexed epoch, uint256 rank,
        address indexed recipient, uint256 amount);
EpochFinalized(bytes32 indexed poolId, uint256 indexed epoch,
               uint256 indexed destinationEpoch, uint256 carry);
```

Credited fires for a valid nonzero identity with positive ETH-leg volume, whether or not it enters the top five, including zero-fee dust. Swaps without identity still fund the pot; events alone are not a complete pot oracle. Query the view after swaps and finalization. EpochFinalized reports the actual current destination epoch; it need not be `epoch + 1`.

## Callbacks and errors

`beforeSwap` and `afterSwap` use the vendored v4 IHooks signatures. `unlockCallback(bytes)` is exclusively for the hook's own payout unlock. All callbacks require the immutable PoolManager as caller. Unimplemented hook callbacks revert and have disabled address flags.

Custom hook errors are `OnlyPoolManager`, `InvalidPoolManager`, `PartialFill`, `AmountTooLarge`, `EpochNotEnded`, `InvalidRank`, `EmptyRank`, `AlreadyClaimed`, `AlreadyFinalized`, `InvalidPool`, `ReentrantClaim`, and `NoPayout`. Constructor permission validation can emit v4's `HookAddressNotValid(address)`. The PoolManager wraps failed swap callbacks; integrations must decode the nested reason to identify PartialFill. Recipient transfer failures and core settlement failures bubble and atomically revert; no rank is consumed on failure.
