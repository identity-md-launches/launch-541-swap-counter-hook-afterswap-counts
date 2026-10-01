# Swap Counter

A Uniswap v4 observation hook and its fixed-supply launch token. All Solidity dependencies are
vendored as ordinary source files; no installation, submodules, RPC, or environment variables are
needed for the delivered tests.

## Build and check

Requires Foundry and Solidity **0.8.26**. The project targets **Cancun** because the real v4
PoolManager uses transient storage. The compiler is pinned by version in `foundry.toml`.

```sh
forge build
forge test
forge fmt --check
```

With the pinned compiler already installed, `forge build --offline --force` and
`forge test --offline` also work. FFI and filesystem cheatcode access are disabled. There are no
network tests in the default suite. Compiler optimization is enabled with 200 runs; CBOR metadata
and metadata hashes are disabled for reproducible bytecode and unambiguous runtime opcode checks.

## Behavior and assumptions

`src/SwapCounterHook.sol:SwapCounterHook` inherits the pinned Uniswap `BaseHook`.

| Interface | Meaning |
| --- | --- |
| `constructor(IPoolManager manager)` | Binds the trusted manager permanently; rejects addresses without code and hook addresses with incorrect permission bits. |
| `getHookPermissions()` | Only `beforeInitialize` and `afterSwap` are enabled. |
| `swapCount(address sender)` | View of the number of successful callbacks for this sender across every pool using this hook. |
| `totalSwaps()` | View of the number of successful callbacks across every sender and pool using this hook. |
| `SwapCounted(address indexed sender, bytes32 indexed poolId, uint256 senderCount, uint256 totalCount)` | Exactly one event per successful callback, containing the updated counts. |

Both enabled callbacks authenticate `msg.sender` through `BaseHook.onlyPoolManager`; disabled
callbacks also authenticate, then revert as unimplemented. `beforeInitialize` returns its selector
without changing state. `afterSwap` increments both counters and returns
`(IHooks.afterSwap.selector, int128(0))`. All four return-delta permissions are false. The hook
does not call other contracts, settle balances, transfer tokens, or update fees.

The unit of counting is **one successful PoolManager `afterSwap` callback**, not a transaction,
token amount, unique person, or completed route. Exact-input, exact-output, partial fills, and
zero-delta callbacks each count once if PoolManager invokes the callback. PoolManager rejects
an amount-specified-zero swap before calling the hook. Multiple swaps in one transaction count
separately. A revert anywhere in the enclosing transaction rolls back counts and emitted events.
Counters use checked `uint256` arithmetic; reaching the maximum would revert subsequent swaps
instead of wrapping. There is no reset function.

`sender` is the immediate caller of `PoolManager.swap`, typically a router. Users sharing that
router share its count. The hook deliberately ignores `hookData` and never derives identity from
`tx.origin`. Router allowlisting is unnecessary for these public statistics. PoolManager is trusted
to provide authentic callbacks; the constructor's code check does not prove it is the intended
Uniswap deployment. Counts are aggregate across pools; index the event's `poolId` for per-pool
statistics. These counts are not Sybil-resistant, volume-weighted, or suitable as proof of an
individual's trading activity.

`src/SwapCounterToken.sol:SwapCounterToken` is an OpenZeppelin ERC-20 named **Swap Counter**,
symbol **SWPC**, with **18 decimals**. Its argument-free constructor mints exactly
**1,000,000,000 tokens (10^27 minor units)** to `msg.sender`. It has standard transfers and
allowances, with no public mint, burn, ownership, pause, blocklist, fee, or upgrade functions.
The token is separate from the hook's accounting; the hook can observe any v4 pool using it.

## Configuration decisions

The general-purpose `BaseHook` is sufficient; no specialized fee or accounting base is needed.
There are no shares, utility settlement libraries, transient hook state, numeric inputs, or
administrator. The Wizard vocabulary has no access-free option, so this record uses `access: null`
to explicitly describe the implemented absence of access-management contracts. It is a design
record, not an input to a generator.

```json
{
  "hook": "BaseHook",
  "name": "SwapCounterHook",
  "pausable": false,
  "currencySettler": false,
  "safeCast": false,
  "transientStorage": false,
  "shares": { "options": false },
  "permissions": {
    "beforeInitialize": true,
    "afterInitialize": false,
    "beforeAddLiquidity": false,
    "afterAddLiquidity": false,
    "beforeRemoveLiquidity": false,
    "afterRemoveLiquidity": false,
    "beforeSwap": false,
    "afterSwap": true,
    "beforeDonate": false,
    "afterDonate": false,
    "beforeSwapReturnDelta": false,
    "afterSwapReturnDelta": false,
    "afterAddLiquidityReturnDelta": false,
    "afterRemoveLiquidityReturnDelta": false
  },
  "inputs": {},
  "access": null,
  "info": { "license": "MIT" }
}
```

## Deployment handoff

No chain, PoolManager address, launch factory, quote asset, price, or liquidity allocation was
supplied. These remain deployment parameters, not hardcoded guesses. No deployment or broadcast
is performed by this project.

1. Select a Cancun-compatible target chain and verify the canonical PoolManager's deployed code
   and version. The deployer is responsible for this trust decision.
2. Identify the exact contract that executes `CREATE2`. For a launch this is normally the launch
   factory; it is not necessarily the wallet submitting the transaction. Confirm whether that
   factory uses the supplied salt verbatim or transforms it.
3. Build the hook with the pinned settings. Its complete init code is
   `abi.encodePacked(type(SwapCounterHook).creationCode, abi.encode(IPoolManager(manager)))`.
   Mine the address for **flags `8256` / `0x2040`**, consisting of `beforeInitialize` (bit 13) and
   `afterSwap` (bit 6). The mask is `0x3fff`; `(uint160(hook) & 0x3fff) == 0x2040` must hold.
4. `script/MineHook.s.sol:MineHook.run(address deployer, IPoolManager manager)` returns the
   predicted address, salt, and complete init code. It takes function arguments, does not read
   environment variables, and does not broadcast. Supply the real CREATE2 executor and manager
   when simulating it on the chosen chain:

   ```text
   forge script script/MineHook.s.sol:MineHook --sig "run(address,address)" <create2-executor> <pool-manager> --rpc-url <rpc-url>
   ```

   Replace the placeholders. `HookMiner` searches up to 160,444 salts and skips addresses with
   existing code. It can fail to find a candidate; do not relax the flags if it does. It is an
   off-chain preparation step, not work to include in a deployment transaction. A different
   manager, executor, compiler setting, or bytecode changes the prediction. Mine again after any
   such change. Coordinate salts and the factory's replay rules separately.
5. The authorized factory must create `SwapCounterToken` itself, with no constructor arguments,
   so the factory receives the entire supply. Hook creation takes only the manager argument;
   there is no owner or initializer transaction for the hook.
6. Have the factory deploy the hook and initialize the intended pool atomically. Choose and review
   the sorted currencies, fee tier, positive tick spacing, initial `sqrtPriceX96`, liquidity range,
   funding, and token distribution. The local tests use two standard ERC-20s, fee 3000, tick
   spacing 60, initial price `2^96`, and liquidity ticks -600 to 600; these are test fixtures,
   not a price or allocation recommendation for launch.
7. Verify the resulting address bits, `poolManager()`, permissions, token supply and recipient,
   and pool state before handing the deployment to consumers. Record the actual chain and
   addresses in the launch system's manifest and verify source using these exact compiler settings.

The initialization callback makes initialization at a predicted address without code fail because
PoolManager cannot obtain its required selector. It does **not** reserve an initialized hook for
one factory or pool. Once the hook exists, initialization is permissionless. Atomic deployment
and initialization are the launch factory's responsibility.

## Validation and operations

The delivered suite has 29 tests: callback permissions/selectors, exact events, repeated senders
and pools, ignored hook data, unauthorized calls, wrong address bits, invalid managers, overflow
rollback, token transfers/allowances and failures, and direct mining-script execution. Runtime
scans check deployment sizes and the absence of DELEGATECALL, CALLCODE, and SELFDESTRUCT while
skipping PUSH data.

Real PoolManager tests initialize, add liquidity, swap both ways, and remove liquidity. Differential
fuzz tests compare hooked and unhooked pools' token deltas, prices, ticks, LP fees, protocol fees,
and fee growth. Failure tests cover zero-sized swaps, initialization before hook deployment, and
unsettled transactions after the counter has executed. Callback fuzz tests use arbitrary senders,
amounts, deltas, directions, and hook data. Fuzzing runs 256 cases per fuzz test; the invariant suite
runs 128 sequences of depth 32 and checks the total equals the sum of per-sender counts and the
model's successful callback count. Its manager calls are simulated; the integration suite uses
the actual vendored PoolManager and token settlement.

There are no privileged operators, keeper jobs, reset paths, fee collectors, or upgrades. Indexers
should process `SwapCounted` with reorg handling and reconcile views at a consistent confirmed
block. Routers remain responsible for slippage protection and settlement. Do not send assets to
the hook; it has no withdrawal/rescue path. Review new-user gas overhead: the first swap writes two
new persistent storage slots, and every new sender adds a storage slot.

See [SECURITY.md](SECURITY.md) for the local review and outstanding production checks. Local tests
are not an independent security audit or a target-chain fork rehearsal.

## Vendored dependencies

`dependencies.lock.json` records upstream commits and a SHA-256 for every vendored file. Only the
source subsets required here and their licenses are included, unchanged. No dependency manager
needs to fetch anything when building or testing.

| Dependency | Pinned source |
| --- | --- |
| Uniswap v4-core | [59d3ecf53afa9264a16bba0e38f4c5d2231f80bc](https://github.com/Uniswap/v4-core/tree/59d3ecf53afa9264a16bba0e38f4c5d2231f80bc) |
| Uniswap v4-periphery (`BaseHook`, `HookMiner`, immutable manager interface/base) | [3779387e5d296f39df543d23524b050f89a62917](https://github.com/Uniswap/v4-periphery/tree/3779387e5d296f39df543d23524b050f89a62917) |
| OpenZeppelin Contracts 5.2.0 (ERC-20 subset) | [acd4ff74de833399287ed6b31b4debf6b2b35527](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/acd4ff74de833399287ed6b31b4debf6b2b35527) |
| forge-std 1.9.7 | [77041d2ce690e692d6e03cc812b57d1ddaa4d505](https://github.com/foundry-rs/forge-std/tree/77041d2ce690e692d6e03cc812b57d1ddaa4d505) |
| Solmate (`Owned`, used by the test PoolManager) | [4b47a19038b798b4a33d9749d25e570443520647](https://github.com/transmissions11/solmate/tree/4b47a19038b798b4a33d9749d25e570443520647) |

The core commit matches the periphery commit's upstream core dependency. Third-party licenses
are preserved under `lib/`; individual v4-core files use MIT or BUSL-1.1 as marked. The project's
own code is MIT licensed. The test-only routers and mocks are not launch contracts.
