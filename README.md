# Volume (VOLM) and VolumeLeaderboardHook

A Sepolia-only weekly volume race. VOLM and its ETH pots are test assets with no value; nothing promises a return. This contribution delivers contracts, offline-buildable dependencies, tests, ABI exports, and deployment assumptions. Source publication, attestation, admission, factory deployment, an independently reviewed `launch.json`, and the static frontend belong to later workflow contributors and services.

## Build and check

```sh
forge build
forge test
forge fmt --check
```

Foundry uses Solidity **0.8.26**, Cancun, optimizer 200 runs, and `bytecode_hash = "none"`. The compiler must be installed in the verifier. All Solidity dependencies are vendored as ordinary files in `lib/`; no package fetch, submodule, FFI, filesystem cheatcode, RPC, or environment variable is needed by the tests. Dependency provenance is in [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md).

## Deployment handoff

| Parameter | Value |
| --- | --- |
| Network | Sepolia, chain ID 11155111; Cancun support required |
| Token artifact | `src/VOLM.sol:VOLM` |
| Token constructor | No arguments; mints all 1,000,000,000 × 10^18 units to `msg.sender` (the factory) |
| Token metadata | Volume / VOLM / 18 decimals |
| Hook artifact | `src/VolumeLeaderboardHook.sol:VolumeLeaderboardHook` |
| Hook constructor | Exactly one `IPoolManager` argument |
| Sepolia manager | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543`, as specified in the approved workflow |
| Required address mask | `uint160(hook) & 0x3fff == 0x00cc` |
| Pool key | currency0 = native ETH (`address(0)`), currency1 = deployed VOLM, fee = 3000, tickSpacing = 60, hooks = deployed hook |
| Rehearsal initial sqrtPriceX96 | `79228162514264337593543950336` (1:1 raw units; both currencies have 18 decimals) |
| Rehearsal seed | Up to 100,000,000 VOLM; zero ETH; ticks `[-887220, 0]` |

**Initial price and seed allocation are explicit assumptions.** The provided workflow supplies neither a numeric price nor an allocation, and no manifest or factory implementation was supplied. The manifest contributor must match these rehearsal parameters, or update the rehearsal to the accepted factory parameters before admission. The hook itself has no price, liquidity allocation, token address, or LP ownership parameter. The factory controls the supply allocation and LP custody; the rehearsal sends its unseeded token balance back to the test harness for subsequent swaps. This is a local reproduction of the specified factory operations, not a fork of an unavailable factory.

`test/helpers/FactoryRehearsal.sol` deploys the token to itself, verifies full supply receipt, mines and deploys the hook using CREATE2, initializes the real manager, calculates liquidity as `floor(seedVOLM * 2^96 / (sqrtUpper - sqrtLower))`, and settles only VOLM. At the upper price boundary the position contains no ETH. The first buy crosses into that position and succeeds while the manager initially has zero ETH.

Mine the CREATE2 salt against the **actual factory address**, final hook creation bytecode, and ABI-encoded manager constructor argument. Test salts are not deployment salts. Constructor validation rejects any permission mismatch. Check that the chosen address has no existing code. Deploy with the reviewed compiler settings and verify the reported permissions before initializing the pool. The epoch clock starts at hook construction, not first liquidity or first swap; services must account for any delay.

No privileged key is configured: neither contract has an owner, mint-after-construction, setter, pause, upgrade, or sweep. Only beforeSwap, afterSwap, beforeSwapReturnDelta and afterSwapReturnDelta are enabled. Initialization, seeding and liquidity removal are unrestricted by the hook.

## Swap accounting and identity

For native-ETH currency0 pools, the fee is `floor(ETH-leg base * 30 / 10000)`. The same base is credited as volume. Rounding to zero is allowed. A fully filled swap preserves the trader's specified amount exactly, including hook charges:

| Mode | ETH fee base | Hook return | Result |
| --- | --- | --- | --- |
| Buy exact input | Specified ETH input | Positive specified beforeSwap delta | Core input = specified input minus fee |
| Sell exact output | Specified ETH output | Positive specified beforeSwap delta | Core output = specified output plus fee |
| Buy exact output | Core ETH input, including LP fee | Positive unspecified afterSwap delta | Trader pays core ETH input plus fee |
| Sell exact input | Core ETH output | Positive unspecified afterSwap delta | Trader receives core ETH output minus fee |

The hook checks the core's specified delta against the adjusted request in afterSwap. Price-limit partial fills revert with `PartialFill`, including all fee mints and accounting effects. v4 wraps callback errors in `CustomRevert.WrappedError`. Specified ETH requests outside the representable int128 range reject before casting. Underlying v4 validation still applies to zero swap amounts, impossible prices, and insufficient balances.

Fees are minted as ERC-6909 native ETH claims (token ID 0) at the PoolManager. Swap callbacks never take ETH. A positive return delta cancels the debt created by minting those claims, and the swap router settles the trader's delta. This is why charging the first buy needs no prefunded ETH reserve.

An identity is the nonzero address in exactly 32 bytes of canonical ABI encoding. Empty, wrong-length, zero, or noncanonical address data credits nobody but still pays the fee. The router address is never used as a fallback. **hookData is unauthenticated:** anyone can credit any address, including contracts unable to receive ETH; the router does not prove wallet ownership. There is intentionally no router allowlist or signature scheme. A frontend should submit `abi.encode(connectedWallet)` but cannot make this trustworthy.

Any pool with currency0 other than native ETH receives zero hook deltas and no bookkeeping, including no partial-fill restriction. Each native-ETH pool is independent by `PoolId = keccak256(abi.encode(poolKey))`; other people can initialize additional pools using this hook.

## Epochs, rankings and settlement

Epoch `e = floor((timestamp - DEPLOY_TIME) / 7 days)`. At the exact boundary second a swap belongs to the new epoch. Volume is accumulated per pool, epoch and identity. The top five update in O(5), keeping a current member unique while it climbs. Entry and overtaking require strictly greater volume; tied incumbents stay ahead. Traders outside the board retain accumulated volume and may reenter later. Zero-volume swaps do not create a participant.

Ended pots and rankings are frozen. Anyone may trigger `claim(key, epoch, rank)` with ranks **1 through 5**, but ETH always goes to the recorded recipient. The shares are floor-rounded 40%, 25%, 15%, 10%, and 10% of the original pot. Each rank can be claimed once, including a zero-wei entitlement. Empty ranks cannot be claimed. Claim flags remove the entire entitlement before calling the manager's unlock. The hook then burns its claims and takes ETH directly to the winner. A recipient rejection rolls back only that transaction, restores the entitlement, and permits a later retry. Other winners and finalization remain usable. There is no expiry or redirection of a rejecting winner's funds.

Anyone may finalize an ended epoch exactly once. Finalization carries `originalPot - sum(nonempty rank shares)` into the epoch current **at the time of finalization**. Thus empty ranks and every rounding wei carry, including the whole pot with no participants. Existing winners' reserved shares never carry. Finalization and claims work in either order; neither changes the ended epoch's original pot. No automatic keeper or chronological finalization is required.

For every epoch:

```text
five rank entitlements (empty ranks = 0) + finalize carry = original pot
unfinalized liability = original pot - paid shares
finalized liability   = nonempty rank entitlements - paid shares
hook's manager ETH claims = sum of all epoch liabilities
```

The conservation invariant covers the protocol's swaps, carries and claims. As with any permissionless ERC-6909 ledger, a third party can transfer its own claims directly to the hook without invoking it. Such unsolicited donations are outside this ledger, create surplus, and are unrecoverable; no sweep or administrative reconciliation is provided. Forced ETH is also outside the pot ledger. Services should reconcile expected liabilities and flag unexpected surplus instead of treating donations as race funding.

## Operations and economics

Services must publish and attest the concrete source and ABI, create and independently review the canonical manifest, mine the final deployment address, admit and deploy the artifacts, initialize and seed through the factory, and only then connect the static frontend. Policy and signed-artifact linkage belong to those services. The independent reviewer must assess the accepted source and manifest, including concrete constructor, permission, authorization, price and seed conflicts. This implementation/test contribution neither performs that independent review nor sends deployment transactions.

Keepers or users may claim/finalize ended epochs. Index `Credited`, `Claimed`, and `EpochFinalized`, use `DEPLOY_TIME` to discover the epoch schedule, and read the views for final state. Claims must begin outside an already-unlocked PoolManager transaction; they acquire their own unlock. Monitor liabilities, failed recipients, carry destinations, actual pool parameters, and the published hook address. Use router-level token/ETH approval and slippage controls appropriate to the final integration; the core's PoolSwapTest is a test router, not a production trading UI security layer.

Wash volume pays the 0.3% LP fee plus the 0.3% hook fee on every leg (approximately 0.6%, with the exact bases above), plus gas and price impact. A trader recapturing its own fees gains no free value; gaming only pays when rewards funded by other traders exceed the trader's costs, subject to liquidity ownership and ranking. Spoofed identities, bots, ties and wash trading are expected limitations of this Sepolia toy, not Sybil resistance.

## Verification coverage

The suite deploys a real v4-core PoolManager and a genuinely mined hook; it never relocates manager/hook code. It covers the factory-shaped ETH-less launch, all four modes and dust, fuzzed sizes and partial fills, non-ETH pools, callback access, epoch-boundary seconds, ties and climbs, eviction/reentry, zero/one/five-plus participants, exact claims-plus-carry conservation, payout ordering, rejection/retry and reentry, duplicate settlement, distinct pools, event payloads, and token behavior. The stateful invariant interleaves swaps in every mode, time advances, claims and finalizations, checks a separate core-event fee ledger, and checks ranking and every outstanding liability. It uses 128 runs × 64 calls with `fail_on_revert = true`.

Local test success is not an independent security review or a live Sepolia fork/deployment rehearsal. Those workflow stages remain separate responsibilities. See [docs/ABI.md](docs/ABI.md) for the integration surface.
