# Vendored dependency provenance

Sources were downloaded as archives from the official repositories and preserved as ordinary files, without submodules or upstream build configuration. Only the needed OpenZeppelin/Solmate source closure and v4 test helpers are included; v4 production sources and forge-std sources are retained. License texts are included beside each dependency. `dependency-hashes.json` records SHA-256 for every vendored file.

| Directory | Official upstream / pinned commit | Purpose |
| --- | --- | --- |
| `lib/v4-core` | [Uniswap/v4-core](https://github.com/Uniswap/v4-core/tree/46c6834698c48bc4a463a86d8420f4eb1d7f3b75), `46c6834698c48bc4a463a86d8420f4eb1d7f3b75` | Manager, hook types, math, and local settlement routers |
| `lib/forge-std` | [foundry-rs/forge-std v1.9.7](https://github.com/foundry-rs/forge-std/tree/77041d2ce690e692d6e03cc812b57d1ddaa4d505), `77041d2ce690e692d6e03cc812b57d1ddaa4d505` | Tests and stateful invariant harness |
| `lib/openzeppelin-contracts` | [OpenZeppelin/openzeppelin-contracts v5.2.0](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/acd4ff74de833399287ed6b31b4debf6b2b35527), `acd4ff74de833399287ed6b31b4debf6b2b35527` | ERC20 and interfaces |
| `lib/solmate` | [transmissions11/solmate](https://github.com/transmissions11/solmate/tree/89365b880c4f3c786bdd453d4b8e8fe410344a69), `89365b880c4f3c786bdd453d4b8e8fe410344a69` | Owned dependency of the locally deployed manager |

No dependency installation is required at verification time. Do not run `forge install` or rely on globally installed Solidity libraries. The remappings target only these repository files. New test-only scaffolding under `test/scratch/` is disposable and contributes no delivered dependency.
