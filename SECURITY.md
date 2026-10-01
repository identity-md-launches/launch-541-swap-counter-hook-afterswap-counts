# Local security review

Scope: `SwapCounterHook`, `SwapCounterToken`, `HookFlags`, and the read-only mining script.
The supplied Ethereum and v4 security references were used as review checklists; this document
records the applicable conclusions, not an independent audit certification.

| Area | Result |
| --- | --- |
| Caller authentication | Every external lifecycle callback inherits `onlyPoolManager`, including `afterSwap`. Direct unauthorized calls are tested for all ten callbacks. |
| Sender attribution | The provided sender is counted. `hookData` is ignored. No `tx.origin`, signatures, router trust extensions, or off-chain identity claims. |
| Address permissions | Constructor validates all 14 flags. Only `beforeInitialize` and `afterSwap` are enabled. Real CREATE2 deployment and wrong-address failures are tested. |
| Initialization | Correct selector and manager authentication; real initialization passes, initialization before hook code exists fails. No pool restriction is implied. |
| Delta accounting | No custom deltas; afterSwap returns zero. No `settle`, `take`, `mint`, fee override, or fee update calls from the hook. Real-pool differential tests cover amounts and fees. |
| Reentrancy | The hook and token perform no external calls. Callbacks have constant work, with no external target to reenter. |
| Arithmetic | Checked `uint256` counter increments; either overflow reverts the whole callback. No amount arithmetic, casts, oracle prices, division, or randomness in hook logic. |
| Token economics | OpenZeppelin ERC-20 without extensions. Supply fixed at 10^27, 18 decimals, all initially assigned to the deploying address. No post-deployment mint or burn entry point. |
| Asset compatibility | Hook neither holds nor moves assets and does not inspect decimals. Test routing assumes standard ERC-20s. Pool/route support for native currency or unusual tokens remains an integration responsibility. |
| Admin and upgrade risk | No owner, pause, upgrade, proxy, reset, rescue, or arbitrary execution entry points. Runtime opcode scans pass for hook and token. |
| Failed transactions | Real PoolManager settlement failure after afterSwap rolls back both counters and pool price; subsequent valid swaps still work. |
| Dependencies | Required sources and original licenses vendored, pinned commits and per-file hashes recorded. No submodules, FFI, filesystem cheatcode access, or runtime network requirements. |

The delivered local validation comprises compilation, unit and integration tests, 256-run fuzz
tests, 128 invariant sequences of depth 32, runtime opcode checks, and a lifecycle gas report.
The bytecode scan is only a structural check; it is not proof of all possible safety properties.

Before release, the deployment operator must obtain a separate adversarial review and rehearse
the deployment and pool lifecycle on a fork of the selected chain at the actual manager address.
Source/explorer verification, chain-specific gas profiling, monitoring/reorg handling, and a
review of the factory's atomic initialization and distribution are also outstanding. No target
chain or factory was supplied, so none of those checks is claimed here. Slither, Mythril, formal
verification, external audit, and a bug-bounty program were not run or arranged in this task.
