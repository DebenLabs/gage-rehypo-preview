# gage lender kit: the rehypo hooks

Uniswap v4 hooks whose idle LP liquidity is lent through gage's rehypo sources, built on OpenZeppelin's
`ReHypothecationHook` (uniswap-hooks v1.3.0-rc.0, a release candidate with no published audit) with ERC-4626 sources.
**Unaudited reference code**, for a partner to copy, change and audit.

## Layout

| Path | What |
| --- | --- |
| `src/ERC4626ReHypothecationHook.sol`, `src/UnlockCheckedHook.sol` | OpenZeppelin's hook with ERC-4626 sources, and the full-range reference: it refuses LP deposits and withdrawals while the PoolManager is unlocked. |
| `src/FailsafeUnlockCheckedHook.sol` | The reference with the failsafe's ask: before a swap that could take more than half of what the bought coin's source backs, it asks that source for the shortfall, where the swap's fee pays for it. |
| `src/AnchoredUnlockCheckedHook.sol` | The anchored hooks, for sources that declare a range: a tight range held on the sources' anchor between keeper moves. Their failsafe form asks both sources for the same share of what they back when a swap would move the pool's price more than 0.05%. |
| `src/AnchoredFeeHook.sol` | The anchored hooks on a dynamic-fee pool: the hook names each swap's fee, held between a floor and a cap fixed at deployment. `AnchoredFeeHook` and `AnchoredFailsafeFeeHook` read the fee from a venue's fee contract (`IRehypoFeeSource.currentFee`), so a pool keeps the fee schedule of the venue's existing pool for the pair. A partner with a fee rule of its own extends `AnchoredDynamicFeeHook` or `AnchoredFailsafeDynamicFeeHook` and writes `_fee`. |
| `script/RehypoSource.s.sol` | A pool's set-up, call by call: the two sources, the hook, the pool, the binding, the keeper, the seed. |
| `test/RehypoSourcePlug*.t.sol`, `RehypoSourcePricedPlug.t.sol` | The plug suites: what a hook must do for a source, proved on the reference hooks. gage runs a partner's hook through them. |
| `test/AnchoredUnlockCheckedHook.t.sol`, `AnchoredFeeHook.t.sol`, `AnchoredFailsafeAsk.t.sol`, `FailsafeUnlockCheckedHook.t.sol` | Each hook's own cases. |
| `test/RehypoSourceRepeat.t.sol`, `RehypoSourceBandEdge.t.sol` | The repeat rounds: a trader pushing the price to the band's edge and trading back, every keeper pass for a day, takes the LPs' value under a fixed bound, on every hook, width and fee. |
| `test/RehypoSourceScript.t.sol` | The set-up script, tested. |
| `test/fork/` | The source and the hooks on mainnet's own state. |

## Build and test

The plug and script suites deploy gage's rehypo source factory, its price router and its feeds from their build at the
repository root, so build there first:

```bash
forge build
```

Then from `integrations/lender-amm`:

```bash
forge test --no-match-path 'test/fork/*'
```

## Fork tests

`RehypoSource.fork.t.sol` runs the source with `UnlockCheckedHook` on mainnet's live PoolManager, with real USDG and
frxUSD. `LENDER_AMM_MAINNET_FORK_BLOCK` pins a block; the RPC must still serve that block's state, and the public node
keeps only a few minutes, so leave it unset there.

```bash
LENDER_AMM_MAINNET_FORK_RPC=https://rpc.mainnet.chain.robinhood.com forge test --match-path test/fork/RehypoSource.fork.t.sol
```

`RehypoSourceRangePlug.fork.t.sol` pins its own block, so it needs an RPC that still serves that block's state (an
archive node). On the public node it stops at once on a missing block.

`RehypoFeeHookLive.fork.t.sol` is the end-to-end run: a frxUSD/USDG pool on `AnchoredFailsafeFeeHook`, lending its USDG
through a live gage vault while that vault's loans repay or default. Swaps pay what a fee contract quotes: a stand-in
at 0.05% each way, or your own when `REHYPO_FEE_MODULE` (your fee contract) and `REHYPO_FEE_POOL_ID` (your pool for the
pair) are set. Run it with `--isolate`: the vault's reserve accrues once per transaction, and without the flag the
whole test is one transaction.

```bash
LENDER_AMM_MAINNET_FORK_RPC=https://rpc.mainnet.chain.robinhood.com forge test --match-path test/fork/RehypoFeeHookLive.fork.t.sol --isolate -vv
```
