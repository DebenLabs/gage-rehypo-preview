# Integrate with gage

For a DEX whose Uniswap v4 hook lends a pool's idle liquidity through gage. Your hook deposits into a **gage rehypo source**, one ERC-4626 vault per pool token. The source keeps a float for swaps and lends the rest through a **gage partner vault** your Safe creates and manages. Your hook needs no gage-specific code.

- How the source works and what your hook must do: [docs/rehypo-source.md](docs/rehypo-source.md)
- The reference kit (hooks, the set-up script, the plug suite): [integrations/lender-amm/](integrations/lender-amm/)
- What you call: [interfaces/](interfaces/)

**Status:** partner vaults and the rehypo source factory (`0xab0425C2f5D5bab9867b42EFE3c228BAD2239419`) are live on mainnet. The integration guide for DEX partners: [docs/integrate/dex-partners.md](docs/integrate/dex-partners.md).

## The steps

| # | Who | What |
| --- | --- | --- |
| 1 | You | **Open an issue** with the Integrate with gage form, kind "Hook or rehypothecation source": your hook (repository, commit, audit), your pool and your Safe. |
| 2 | gage | **Reviews your hook on a mainnet fork** with the plug suite (`integrations/lender-amm/test/RehypoSourcePlug.t.sol`) and the hook checklist in [docs/rehypo-source.md](docs/rehypo-source.md). We answer in the issue. |
| 3 | Your Safe | **Creates its partner vaults**: `IntentFactory.create(mandate, ...)`, with your Safe as the curator, one vault per lent token. Any address can create one (`openCreation()` is true on every current factory). Your Safe manages each vault for good. |
| 4 | Your Safe | **Creates the sources**: on the rehypo source factory, `create(asset, vault, owner, beneficiary, floatBps, salt)` once per pool token. `vault` is your partner vault of that token, or zero for a float-only side. `predict` gives the addresses ahead of time. |
| 5 | Your Safe | **Deploys and starts the pool**: deploy your hook naming the two sources, initialize the pool, `bind(poolKey)` on each source, seed the pool, then `setKeeper(gageKeeper, true)` on each source with the keeper address we give in the issue. |
| 6 | gage | **Turns on the keeper** for your sources and your pool's price band. We confirm in the issue and close it. |

Steps 3 to 5 can be one Safe batch per pool. `integrations/lender-amm/script/RehypoSource.s.sol` makes the same calls in the same order on a test network: use it as your reference.

## Before you open the issue

- [ ] Your hook meets each item of the checklist in [docs/rehypo-source.md](docs/rehypo-source.md) ("A hook of the partner's own design").
- [ ] It passes the plug suite on your own fork, with your hook in place of `UnlockCheckedHook`: `forge build src/rehypo/GageRehypoSourceFactory.sol` at the repository root, whose build the suite reads, then `forge test --match-path test/RehypoSourcePlug.t.sol` from `integrations/lender-amm`.
- [ ] Your hook is audited, or will be before it holds liquidity on mainnet. gage reviews the integration, not your whole hook.
- [ ] You know who signs for your Safe, and which address receives sGAGE and recovered collateral (the source's `beneficiary`).

## The emergency lever

Your Safe calls `setFloatBps(10000)` on the lent source: nothing more goes to the vault, and gage's keeper pulls the float back from the vault's free cash. Your Safe also pauses the vault (`setPaused(true)`): no new loans, and exits still go through. Details in [docs/rehypo-source.md](docs/rehypo-source.md).

**Found a vulnerability?** Do not open an issue: see [SECURITY.md](SECURITY.md).
