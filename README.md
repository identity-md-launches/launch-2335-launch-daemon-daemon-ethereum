# DAEMON (DAEMON) — Uniswap v4 hook launch on Ethereum

A zero-fee launch of the DAEMON token against native ETH through the IMD launch factory. The
repository contains the two contracts the launch deploys, their tests, and this document.

| Contract | Solidity name | File | Role |
| --- | --- | --- | --- |
| DAEMON token | `DaemonToken` | `src/DaemonToken.sol` | Fixed-supply ERC-20, 1,000,000,000 DAEMON, 18 decimals |
| Launch hook | `DaemonHook` | `src/DaemonHook.sol` | Gates pool initialization to the factory; takes no fee |

Logo: https://imdfamily.com/daemon-seated-pepe.webp

## Headline facts to report

- **Initial market cap**: the launch policy opens the pool at **10 ETH for the whole 1,000,000,000
  supply** (1e8 DAEMON per ETH). The deployer derives the opening `sqrtPriceX96` from that cap and the
  token's address at launch; it is not set in this repository.
- **Standard LP fee**: the pool opens at the platform tier **12500 (1.25%)**, tick spacing 60. The
  hook accepts no other fee and no dynamic-fee flag. The LP fee is Uniswap's, split by the factory
  80% to the launch's payer and 20% to the network. The hook adds **zero** on top.
- **Recipient authorization requirement**: after launch the **current requester** must call
  `setRequester(launchNumber, 0x81e5b64e1bc3d9ae681812d516953f05b1b964b2)` on the launch factory so
  the entire creator fee share goes to that approved community/NFT purchase wallet. See
  "After launch" below. Nobody else can do this for them, and nothing in these contracts can.

## What the launch deploys and with which arguments

Both constructors avoid external calls and need no address to have code, so they run on an empty
chain. Values marked `$...` are filled by the launch manifest; everything else is fixed in code.

### `DaemonToken()`

No constructor arguments. Mints `1_000_000_000 ether` (10^27 minor units) to `msg.sender`, the launch
factory, exactly once. Name `DAEMON`, symbol `DAEMON`, 18 decimals. Plain OpenZeppelin v5 ERC-20:
no owner, mint, burn-from, pause, blocklist, tax, limits or upgrade path.

### `DaemonHook(IPoolManager poolManager_, address factory_, address token_, address owner_)`

| Argument | Manifest value | Meaning |
| --- | --- | --- |
| `poolManager_` | `$poolManager` | The chain's Uniswap v4 PoolManager. Only it may call a callback. |
| `factory_` | `$factory` | The IMD launch factory. Only it may initialize the pool. |
| `token_` | `$token` | The `DaemonToken` deployed just before the hook. |
| `owner_` | `$owner` (= `0xfa866c42f6208456c32873a438ae8f11aa73a959`) | Recorded as `owner()`. Has no privileged function. |

The hook's address must carry exactly the bits `BEFORE_INITIALIZE | BEFORE_SWAP | AFTER_SWAP`
(`0x20C0` in the low 14 bits); the constructor validates this and reverts otherwise. The deployer
mines the CREATE2 salt, as the tests do with `test/utils/HookMiner.sol`.

### Launch economics (manifest values, not contract code)

| Item | Value |
| --- | --- |
| Chain | Ethereum, chain id 1 |
| Pair | native ETH (`pool.pairedCurrency` = zero address) |
| `pool.fee` / `pool.tickSpacing` | 12500 / 60 |
| Supply | 1,000,000,000 DAEMON, minted once to the factory |
| Swarm allocation | 10%, sent by the factory to the launch's MerkleDistributor |
| `economics.poolBps` | 8300 (83% of supply seeds the pool) |
| `economics.remainderTo` | `0x5ed4ecc313a55d72842c5b3abbaa0c67f0fb0334` (the remaining 7%, to the existing immutable 9:3:2 allocation router; not redeployed or substituted) |
| Opening price | derived by the deployer from the 10 ETH opening cap |

No contract in this repository is allocated, reserved or sent any token at launch.

## Hook behaviour

Configuration record (the Wizard's canonical shape, implemented by hand on v4-core's `IHooks`):

```json
{
  "hook": "BaseHook",
  "name": "DaemonHook",
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
    "beforeSwap": true,
    "afterSwap": true,
    "beforeDonate": false,
    "afterDonate": false,
    "beforeSwapReturnDelta": false,
    "afterSwapReturnDelta": false,
    "afterAddLiquidityReturnDelta": false,
    "afterRemoveLiquidityReturnDelta": false
  },
  "inputs": {},
  "access": "ownable",
  "info": { "license": "MIT" }
}
```

- **`beforeInitialize`** (required for every IMD launch, so nobody can open the predicted pool before
  the factory deploys the hook). Accepts exactly one pool, once, when all of these hold: the caller
  is the PoolManager, the `sender` is the factory, `currency0` is native ETH, `currency1` is the
  DAEMON token, `fee == 12500`, `tickSpacing == 60`. It records the pool id and emits
  `PoolInitialized`. Any other pool, any other sender, or a second initialization reverts.
- **`beforeSwap` / `afterSwap`**: verify the caller is the PoolManager and the key is the initialized
  pool, then return the selector, a zero `BeforeSwapDelta`, a zero LP fee override and a zero
  `afterSwap` delta. They are `view`; they move nothing. `afterSwap` is enabled only so the zero
  delta is explicit on both sides of a swap, as the brief asks; it carries no logic.
- **Return-delta permissions are all off.** Even if a future bug returned a non-zero delta, the
  PoolManager would ignore it, because the address carries no return-delta bit.
- **No liquidity callbacks.** The factory holds the seeded position and collects fees with a zero
  liquidity change; the hook is never consulted, so no owner switch can block the collect.
- **No fee path exists.** No fee recipient, treasury, claim, setter, pause, game, signer, oracle,
  NFT gate or season. The hook has no `receive`, holds no ETH, tokens or ERC-6909 claims, and the
  tests assert this after every swap. There is nothing to settle in ETH because nothing is charged.
- **Owner**: OpenZeppelin `Ownable`, set from the `$owner` constructor argument (never
  `msg.sender`, which is the factory, nor `tx.origin`). The only owner functions are
  `transferOwnership` and `renounceOwnership`. The owner cannot enable a fee later: no such function
  exists and the permissions are immutable in the address.

### Callbacks added beyond the brief, and why

The brief names no callbacks. `beforeInitialize` is required by the launch so the pool cannot be
front-run before the hook exists. `beforeSwap` and `afterSwap` are added so the hook can restrict
swaps to the initialized pool and return the explicit zero deltas and zero fee override the brief
asks for. No return-delta flag is added, because the hook takes no fee.

### What the brief asked that the token does not do

Nothing: the brief asks for the standard fixed supply, 18 decimals and plain transfers, which is
exactly the launch token. All launch economics (swarm 10%, pool 83%, remainder 7%) are the
factory's, not the token's.

## After launch (operational responsibilities)

1. **Direct the creator fee share** — the actual current requester (the wallet the factory records
   as the launch's requester) must call, on the launch factory:
   ```
   setRequester(launchNumber, 0x81e5b64e1bc3d9ae681812d516953f05b1b964b2)
   ```
   `launchNumber` is the number the factory assigns at launch. This sends the ENTIRE creator fee
   share to the approved community/NFT purchase wallet, never to GameRewards or to the allocation
   router. This authorization is separate from the token owner and cannot be executed by anyone but
   the current requester. The contracts here cannot do it, and they do not need to know the wallet.
2. **Fee collection** is the factory's. It collects the pool's LP fees as ETH and/or DAEMON with a
   zero liquidity change and pays them out as collected. There is no automatic conversion to imdUSD,
   no automatic NFT purchase and no distribution logic anywhere in this repository.
3. **Nothing to configure on the hook.** There are no owner-settable values. `transferOwnership`
   exists only to move the powerless `owner()` record.
4. **Deferred**: the signed artwork NFT and auction are out of scope for this launch and nothing
   here anticipates them.

## Assumptions

- The launch factory opens the pool at `pool.fee = 12500` and `tickSpacing = 60` with native ETH as
  the pair, as the launch policy states. The hook hard-codes these; a different tier would need a
  new hook.
- Native ETH is `address(0)`, which always sorts as `currency0`; DAEMON is therefore `currency1`.
- The factory is the `sender` of `PoolManager.initialize` for the launch pool and is the hook's
  constructor `msg.sender`. The hook takes it as `$factory` and never trusts `msg.sender` or
  `tx.origin`.
- The owner `0xfa866c42f6208456c32873a438ae8f11aa73a959` is the launch's `$owner`.
- The remainder recipient `0x5ed4ecc313a55d72842c5b3abbaa0c67f0fb0334` and the requester wallet
  `0x81e5b64e1bc3d9ae681812d516953f05b1b964b2` are used only by the manifest and the factory; no
  contract here stores them.

## Development

Foundry project at the repository root. `foundry.toml` pins `solc = "0.8.26"`, `evm_version =
"cancun"`, `bytecode_hash = "none"`, optimizer on (200 runs), no `ffi`, no filesystem permissions.

```
forge build
forge test --fuzz-seed 0xd2dc036e3cfb93889f639b5572360456d927f56c50824812ea94afe0773a2638
forge fmt --check
```

Dependencies are vendored as ordinary files under `lib/` (no submodules), trimmed to what the
project imports:

| Library | Source | Version | License |
| --- | --- | --- | --- |
| forge-std | github.com/foundry-rs/forge-std | v1.11.0 | MIT / Apache-2.0 |
| v4-core | github.com/Uniswap/v4-core | main, cloned 2026-10-20 (`src/`, `test/utils/CurrencySettler.sol`) | BUSL-1.1 / MIT / GPL-2.0 per file (`lib/v4-core/licenses`) |
| openzeppelin-contracts | github.com/OpenZeppelin/openzeppelin-contracts | v5.4.0 (`contracts/`, without `mocks/`) | MIT |
| solmate | github.com/transmissions11/solmate | commit 89365b8 (`src/auth/` only, needed by v4-core's `ProtocolFees`) | AGPL-3.0 |

### Tests

`test/DaemonToken.t.sol` — supply, decimals, exact transfers, allowance, reverts, no admin entry
point (stranger and deployer), fuzzed conservation of supply.

`test/DaemonHook.t.sol` — on a locally deployed PoolManager, token and factory stand-in:

- permissions match the address bits; a mismatched address cannot deploy; zero-address arguments revert;
- the factory opens the DAEMON/ETH pool at 12500/60 and the hook records it; anyone else (including
  the owner) is refused; another pair, another token, another fee, the dynamic-fee flag, fee 0 and
  another spacing are refused; only one pool ever;
- every declared callback refuses callers other than the PoolManager; swap callbacks refuse any key
  but the launch pool; undeclared callbacks revert;
- buys and sells, exact input and exact output, return deltas identical to a hookless twin pool at
  the same LP fee and liquidity, including a fuzzed run with the verifier's seed; the hook ends every
  swap with no ETH, no DAEMON and no ERC-6909 claim; a buy works on a manager holding no ETH;
- the 1.25% LP fee accrues to the factory's position and its zero-liquidity collect passes through;
  liquidity can be added and removed by the factory and by anyone;
- the owner has no fee, pause or claim entry point and ownership transfer changes nothing.

## Security notes

Applied from the `uniswap-v4-security` checklist: every callback checks `msg.sender ==
poolManager`; no `*ReturnDelta` permission; no external calls from the hook, so no reentrancy
surface; no loops; no hardcoded chain addresses; no funds held; permissions immutable in the
address; owner has no power. Risk score by that guide's rubric is low (permissions: beforeInitialize
LOW, beforeSwap HIGH by category but a pure gate, afterSwap MEDIUM; no external calls; one boolean
and one id of state; no upgrade; no non-standard tokens).

Tests passing are not an audit. The launch's independent review and the fork rehearsal against
mainnet state are the admission gate's; Slither was not available on this machine and did not run.
