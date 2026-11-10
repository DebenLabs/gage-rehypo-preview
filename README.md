# gage rehypo: a preview for partners

**A preview of work in progress.** Cut on 10 November 2026 for partners to read and to test on a fork. The contracts
and hooks here are newer than anything deployed. They are **not deployed, not reviewed, and may change.**

A rehypo pool is a Uniswap v4 pool whose idle liquidity is lent on gage. The pool's hook deposits each token into a
**gage rehypo source**. The source keeps a float for swaps and lends the rest through a gage partner vault, at a fixed
cost and with no liquidation: at the end of a loan's term the borrower repays, or the lender keeps the collateral.

This tree holds what a rehypo pool needs end to end: the source and its price feeds, the hooks, their tests, the
guides, and a note on everything that runs off-chain.

## Layout

| Path | What | Licence |
| --- | --- | --- |
| `src/rehypo/GageRehypoSource.sol`, `GageRehypoSourceFactory.sol` | The source and its factory: the float, the vault, declared ranges, priced and pegged sources, the failsafe, the draw for a source with no vault. | BUSL-1.1 ([LICENSE](LICENSE)) |
| `src/rehypo/RehypoPriceRouter.sol`, `RehypoParPriceSource.sol`, `src/oneday/NuntiusPriceSource.sol` | Each token's price feed: a signed price, or one USDG for a dollar stable nobody signs a price for. | BUSL-1.1 |
| `integrations/lender-amm/` | The hooks (`UnlockCheckedHook`, its failsafe, anchored and fee forms), the set-up script and the tests. Its [README](integrations/lender-amm/README.md) says what each file is. | MIT ([LICENSE-MIT](LICENSE-MIT)) |
| `interfaces/` | What your hook, your Safe and your tools call: the source, its factory, a partner vault, the vault factory and its registry. | MIT |
| `abi/` | The ABIs of the contracts in `src/`. | |
| `deployments/manifest/4663.json` | The addresses on Robinhood Chain mainnet a rehypo pool touches: Uniswap v4, USDG, gage's vault factories and their registry. | |
| [docs/rehypo-source.md](docs/rehypo-source.md) | The guide: how the source works, what a hook must do, the parameters and their bounds, the limits and risks. | |
| [docs/offchain.md](docs/offchain.md) | Everything that runs off-chain: gage's keeper, prices, lending, the hook check, and your side. | |
| `docs/integrate/` | Partner guides: [DEX partners](docs/integrate/dex-partners.md), [partner vaults](docs/integrate/partner-vaults.md), [fills](docs/integrate/fills.md), [the exit desk](docs/integrate/exit-desk.md), [generations](docs/integrate/generations.md). | |
| [PARTNERS.md](PARTNERS.md) | The steps with gage, from a hook to a served pool. | |

## Run it

Foundry `nightly-5e88010a83d1b87b8f4d13058e42a2949d3e9dc0`, Node 22 and git.

Get the pinned libraries (about 900 MB). In a clone of the repository they are submodules:

```bash
git submodule update --init --recursive
```

From an archive of the tree, with no git history, this script checks the same commits out:

```bash
node script/libs.js
```

Build the contracts at the root (the kit's tests deploy the source factory from this build):

```bash
forge build
```

The kit's tests, from `integrations/lender-amm`:

```bash
forge test --no-match-path 'test/fork/*'
```

The end-to-end run on a fork of mainnet at the head, also from `integrations/lender-amm`:

```bash
LENDER_AMM_MAINNET_FORK_RPC=https://rpc.mainnet.chain.robinhood.com forge test --match-path test/fork/RehypoFeeHookLive.fork.t.sol --isolate -vv
```

## What the fork run does

- It builds this tree's source factory, two pegged sources and `AnchoredFailsafeFeeHook` on the fork, and opens a new
  frxUSD/USDG pool on the live PoolManager. Nothing is sent to the chain.
- Swaps pay what a fee contract quotes. By default that is a stand-in at 0.05% each way. Set `REHYPO_FEE_MODULE` (your
  fee contract, answering `currentFee(poolId, zeroForOne)`) and `REHYPO_FEE_POOL_ID` (your pool for the pair) to read
  your own, live.
- The USDG side lends through a live gage vault and its reserve. A large sale draws on both sources inside the swap.
- The vault's two running loans then repay and default, and the LP exits.
- It cannot fund a new loan: that needs a plan signed by gage ([docs/offchain.md](docs/offchain.md)). Once the vault's
  two loans have ended on mainnet, the loan steps skip themselves and the pool and swap steps still run.
- `--isolate` matters: the vault's reserve accrues once per transaction, and without the flag the whole test is one.
- The public node keeps only a few minutes of past state, so a run that outlasts it fails on a missing block: run it
  again.

## Trying a hook of your own

Deploy it where the fork test deploys the kit's (`deployCodeTo` in `setUp`), with the two sources as its yield sources.
What a hook on a declared range must do, in short (the guide's checklist has the rest):

1. Use the range the sources declare, held on their anchor between keeper moves.
2. Size its liquidity from what both sources offer (`maxWithdraw`).
3. Refuse LP deposits and withdrawals while the PoolManager is unlocked.
4. Give LPs an ERC-20 share.
5. Optional: ask the sources for more when a swap needs it (`drawOnVault`), as `AnchoredFailsafeUnlockCheckedHook` does.

`test/RehypoSourcePlug.t.sol` is the suite gage runs a partner's hook through.

## What is not here

- **The vault side.** The partner vault, its factory, the exit desk and the lending core are live on mainnet, and the
  fork tests run against the deployed ones. Their sources are in gage's public contracts repository,
  `https://github.com/DebenLabs/gage-contracts`; this tree carries their interfaces and addresses. Where a guide names
  one of those files, the name is left as plain text.
- **Anything off-chain.** gage's keeper and services are not in this tree; [docs/offchain.md](docs/offchain.md)
  describes them.
