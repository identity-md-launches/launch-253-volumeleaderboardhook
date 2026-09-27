// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {
    HookTestBase,
    VolumeLeaderboardHook,
    PoolKey,
    PoolId,
    SwapParams,
    PoolSwapTest,
    TickMath,
    VOLM
} from "./helpers/HookTestBase.sol";

contract AccountingHandler is Test {
    VolumeLeaderboardHook public hook;
    PoolSwapTest public router;
    PoolKey internal key;
    PoolId public id;
    uint256 public fees;
    uint256 public payouts;
    mapping(uint256 => uint256) public expectedPot;
    mapping(uint256 => mapping(address => uint256)) public expectedVolume;

    constructor(VolumeLeaderboardHook hook_, PoolSwapTest router_, PoolKey memory key_, VOLM token) {
        hook = hook_;
        router = router_;
        key = key_;
        id = key.toId();
        token.approve(address(router), type(uint256).max);
        (,, fees,) = hook.leaderboard(id, 0);
        expectedPot[0] = fees; // The fixture's unattributed ETH-reserve buy.
    }

    function trade(uint8 modeRaw, uint64 sizeRaw, uint8 identityRaw) external {
        uint256 mode = modeRaw % 4;
        bool buying = mode < 2;
        uint256 amount = bound(sizeRaw, 1, 2 ether);
        address identity = identityRaw % 9 == 8 ? address(0) : address(uint160(0x1000 + identityRaw % 9));
        int256 specified = mode % 2 == 0 ? -int256(amount) : int256(amount);
        vm.recordLogs();
        router.swap{value: buying ? 4 ether : 0}(
            key,
            SwapParams(buying, specified, buying ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            abi.encode(identity)
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        uint256 base;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(hook.poolManager())
                    && logs[i].topics[0]
                        == keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)")
            ) {
                (int128 coreEth,,,,,) =
                    abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                base = mode == 0 || mode == 3
                    ? amount
                    : uint256(coreEth < 0 ? -int256(coreEth) : int256(coreEth));
                found = true;
            }
        }
        assertTrue(found);
        uint256 fee = base * 30 / 10000;
        fees += fee;
        uint256 epoch = hook.epochNow();
        expectedPot[epoch] += fee;
        if (identity != address(0)) expectedVolume[epoch][identity] += base;
    }

    function advance(uint32 secondsRaw) external {
        vm.warp(block.timestamp + bound(secondsRaw, 0, 7 days + 1));
    }

    function settleRank(uint16 epochRaw, uint8 rankRaw) external {
        uint256 current = hook.epochNow();
        if (current == 0) return;
        uint256 epoch = epochRaw % current;
        uint256 rank = rankRaw % 5;
        (address[5] memory users,, uint256 pot, bool[5] memory claimed) = hook.leaderboard(id, epoch);
        if (users[rank] == address(0) || claimed[rank]) return;
        uint256 beforeEth = users[rank].balance;
        hook.claim(key, epoch, rank + 1);
        uint256 amount = users[rank].balance - beforeEth;
        assertEq(amount, allocation(pot, rank));
        payouts += amount;
    }

    function finalizeEpoch(uint16 epochRaw) external {
        uint256 current = hook.epochNow();
        if (current == 0) return;
        uint256 epoch = epochRaw % current;
        if (hook.isFinalized(id, epoch)) return;
        (address[5] memory users,, uint256 pot,) = hook.leaderboard(id, epoch);
        uint256 awards;
        for (uint256 i; i < 5; ++i) {
            if (users[i] != address(0)) awards += allocation(pot, i);
        }
        hook.finalize(key, epoch);
        expectedPot[current] += pot - awards;
    }

    function allocation(uint256 pot, uint256 index) public pure returns (uint256) {
        uint256[5] memory rates = [uint256(40), 25, 15, 10, 10];
        return pot * rates[index] / 100;
    }

    receive() external payable {}
}

contract AccountingInvariantTest is HookTestBase {
    AccountingHandler handler;

    function setUp() public override {
        super.setUp();
        buy(address(0), 5000 ether);
        handler = new AccountingHandler(hook, router, key, token);
        token.transfer(address(handler), 1_000_000 ether);
        vm.deal(address(handler), 1_000_000 ether);
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.trade.selector;
        selectors[1] = handler.advance.selector;
        selectors[2] = handler.settleRank.selector;
        selectors[3] = handler.finalizeEpoch.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_ethClaimsEqualUnpaidPotsPlusUnpaidShares() public view {
        uint256 current = hook.epochNow();
        assertLiabilities(current);
        assertEq(
            manager.balanceOf(address(hook), 0), handler.fees() - handler.payouts(), "independent flow ledger"
        );
        for (uint256 epoch; epoch <= current; ++epoch) {
            (address[5] memory users, uint256[5] memory totals, uint256 amount,) = hook.leaderboard(id, epoch);
            assertEq(amount, handler.expectedPot(epoch), "fees plus carry, ended pot frozen");
            for (uint256 i; i < 5; ++i) {
                assertEq(totals[i], handler.expectedVolume(epoch, users[i]), "board volume");
                if (i > 0) assertGe(totals[i - 1], totals[i]);
                if (users[i] != address(0)) {
                    for (uint256 j = i + 1; j < 5; ++j) {
                        assertTrue(users[i] != users[j], "duplicate winner");
                    }
                }
            }
            for (uint160 userIndex; userIndex < 8; ++userIndex) {
                address user = address(0x1000 + userIndex);
                uint256 expected = handler.expectedVolume(epoch, user);
                assertEq(hook.volumeOf(id, epoch, user), expected, "all credited volume");
                bool onBoard;
                for (uint256 i; i < 5; ++i) {
                    if (users[i] == user) onBoard = true;
                }
                if (!onBoard) assertLe(expected, totals[4], "omitted larger trader");
            }
        }
    }
}
