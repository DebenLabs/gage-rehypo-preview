# DEX partners: lend a pool's idle liquidity through gage

For a DEX whose Uniswap v4 hook lends the idle liquidity of its pools. The pool's tokens are lent at a fixed cost through **gage partner vaults** your Safe creates and manages, with no liquidation: nothing can touch a loan's collateral before the end of its term; at the end the borrower repays, or the lender keeps the collateral. There are two ways in:

- **A hook built on OpenZeppelin's `ReHypothecationHook` with ERC-4626 sources** plugs into a **gage rehypo source**, one per pool token, with no gage-specific code in the hook. The source keeps a float for swaps and lends the rest through your partner vault of that token. This page covers how it plugs in and how to create the sources on mainnet; the source's full behaviour and the hook checklist are in [rehypo-source.md](../rehypo-source.md).

Either way, the steps with gage (the issue, the review, gage's keeper) are in [PARTNERS.md](../../PARTNERS.md). Creating the vaults themselves is on [Create your pool vaults](https://docs.gage.cash/developers/pool-vaults).

## Contracts

| Contract | Address | Source | ABI | Who controls it |
| --- | --- | --- | --- | --- |
| `GageRehypoSourceFactory` | `0xab0425C2f5D5bab9867b42EFE3c228BAD2239419` | [GageRehypoSourceFactory.sol](../../src/rehypo/GageRehypoSourceFactory.sol) | [GageRehypoSourceFactory.json](../../abi/GageRehypoSourceFactory.json) | No owner, no settings: anyone creates a source, salted with the creator. |
| `GageRehypoSource` | one per pool token, created by the factory | [GageRehypoSource.sol](../../src/rehypo/GageRehypoSource.sol) | | Its owner, your Safe (`Ownable2Step`): binds the hook, names keepers, sets the float target, the beneficiary and a later vault. gage's keeper, once your Safe names it, rebalances. |
| GenerationDeployer, the factory record | `0xcea38204C97e9745f831978357d562E5CcC6834F` | GenerationDeployer.sol | GenerationDeployer.json | gage's Safe; the record itself only grows when gage builds a generation ([Generations](generations.md)). |
| USDG factory | `0xB086944b140758b33694220d4Fe93C9A8D8618a1` | IntentFactory.sol | IntentFactory.json | gage's Safe owns it. Any address can create a vault (`openCreation()`), and your Safe curates the vaults it creates. |
| GLD, NVDA and HIMS factories | `0x2a09498f11A70c4F2AB0a4e1B3323699bF7cC143`, `0xd1Fc8951289372C7260Ac0F7BC830bAbA49F109c`, `0x76030f3fd8631a2839D79fEfBf5EFf124229734a` | same | same | same |
| Exit desk | `0x0c7e23f245377551A7fac3b3D05238Ac2E9Eefc2` | IntentExitDesk.sol | | Named by each factory; it lists an LP's exit when a source cannot pay it now. |
| Uniswap v4 PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` | | | Uniswap. Every source holds its float here. |

What a source needs of a vault, and of the record, are two MIT interfaces: [IRehypoVault.sol](../../src/interfaces/rehypo/IRehypoVault.sol) and [IIntentFactoryRegistry.sol](../../src/interfaces/IIntentFactoryRegistry.sol).

## How it works

**The plug.** Your hook treats each source as its currency's ERC-4626 source: it deposits with `approve(source, amount)` then `deposit(amount, hook)`, withdraws with `withdraw(amount, hook, hook)`, values its position with `convertToAssets(balanceOf(hook))` and sizes swaps with `maxWithdraw(hook)`. Two things are required beyond OpenZeppelin's defaults: swaps sized by `maxWithdraw`, and LP entries and exits that revert while the PoolManager is unlocked. The exact overrides are the table "The plug: what the hook does" in [rehypo-source.md](../rehypo-source.md), and a hook of your own design must meet its checklist.

**The source.** One ERC-4626 per pool token. It keeps a float, held as its ERC-6909 claims inside the PoolManager, and lends the backing beyond its float target through the partner vault it names. Inside a swap it never calls the vault; outside, gage's keeper moves the float toward its target with `rebalance`. The source has one depositor, the pool's hook, bound once with `bind(poolKey)`; its shares never transfer. A side with no vault is **float-only**: it holds its whole backing as float, and can attach a vault later with three days' notice to your LPs (`ATTACH_DELAY`). An LP whose share is more than a source can pay now can exit through the chain's exit desk (`exitNow(id)`).

**What the source checks of its vault**, at creation and again at `proposeVault`:

1. `vault.asset()` is the source's token, else `InvalidConfiguration`.
2. `factory = vault.PROTOCOL_SOURCE()`, the Intent factory that created it.
3. `REGISTRY.isFactory(factory)`, and `factory.isVault(vault)`, else `NotAGageVault`.

`REGISTRY` is the GenerationDeployer: the factory's `REGISTRY()`, which every source it creates inherits for good. It records the release's USDG, GLD, NVDA and HIMS factories and every generation the deployer builds, the frxUSD generation's included. So a source accepts any partner vault of those factories, and no other contract that claims to be one. A vault of an earlier generation predates the ERC-4626 surface the source calls (its `asset()` reverts), so it cannot be used either.

**What the source then calls on the vault** (`IRehypoVault`): `deposit` and `withdraw` (ERC-4626), `convertToAssets`, `balanceOf`, `maxDeposit`, `maxWithdraw`, `previewWithdraw`, `earliestMaturity` (entries and exits wait while a finished loan awaits its `settle`), `claimPockets`, `claimRewards`, and `approve` of its shares to the exit desk for an LP's exit. On the vault's factory it reads `isVault` and `exitDesk()`.

**sGAGE and recovered collateral.** The vault shares a source holds earn the vault's sGAGE (Rewards). Anyone can call `claimRewards()` on the source to bring it in, and `forward(token)` to send it, or any collateral recovered from a written-off loan, to the source's `beneficiary`, the address you choose. How your LPs receive them is yours to decide. Pocket proceeds paid in the source's own token join the float over a day (`RELEASE`).

## Call sequences

Your Safe makes these calls, in this order, as one batch per pool. [PARTNERS.md](../../PARTNERS.md) says which steps wait on gage.

1. **Your partner vaults.** On the factory of each token you lend, `IntentFactory.create(...)` with your Safe as curator: [Partner vaults](partner-vaults.md). A token gage does not lend gets no vault: its side is float-only.
2. **Predict each source's address**, on the factory:
   `predict(address creator, IERC20 asset, IRehypoVault vault, address owner, address beneficiary, uint16 floatBps, bytes32 salt) external view returns (address)`.
   `creator` is the account that will call `create`: your Safe. The CREATE2 key is `keccak256(abi.encode(creator, salt))`, so no one else can take your address first.
3. **Deploy your hook**, naming the two predicted sources.
4. **Create each source**, once per pool token:
   `create(IERC20 asset, IRehypoVault vault, address owner, address beneficiary, uint16 floatBps, bytes32 salt) external returns (GageRehypoSource source)`.
   - `asset`: the pool token. `vault`: your partner vault of that token, or zero for a float-only side.
   - `owner`: your Safe. `beneficiary`: where sGAGE and recovered collateral go; neither zero nor the source.
   - `floatBps`: the float target, 100 to 10,000 basis points of the backing (1% to 100%). A float-only side keeps 10,000.
   - The source is named `gage rehypo source <SYMBOL>`, symbol `grs<SYMBOL>`. Its smallest sweep into the vault is one whole unit of the token (`MIN_SWEEP`).
   - The same creator, salt and arguments a second time revert: that address is taken.
5. **Initialize the pool**, then `bind(PoolKey calldata key)` on each source, once, with the exact key your hook serves. It refuses a pool that does not exist, has no hook contract or does not hold the source's token.
6. **Seed the pool** after `bind`, in a call of its own: a source refuses every deposit until it is bound, so a hook that deposits while its pool initializes cannot initialize it.
7. **Name gage's keeper**: `setKeeper(address keeper, bool allowed)` on each source, with the address gage gives you in the issue.

For a lent side, a borrower who does not repay by the end of the term leaves the vault its collateral instead of the token lent. It reaches the source as a pocket and goes to your `beneficiary`, and the LPs' share price falls with the vault's. You may end up holding the collateral instead of the asset you lent.

**Later.**

- **Start lending a float-only side**: `proposeVault(IRehypoVault vault_)`, then `attachVault()` three days later (`cancelVault()` drops it). The vault passes the same checks as at creation.
- **The float target**: `setFloatBps(uint16 floatBps_)`. A higher target applies at once; a lower one waits `FLOAT_DELAY` (3 hours), then anyone calls `applyFloatBps()`. The emergency lever is `setFloatBps(10000)` and the vault's `setPaused(true)`: [rehypo-source.md](../rehypo-source.md).
- **The beneficiary**: `setBeneficiary(address beneficiary_)`.

## Events to index

On the factory:

- `SourceCreated(address indexed source, address indexed asset, address indexed vault, address owner, address beneficiary, uint16 floatBps, address creator)`: a new source; `vault` is zero for a float-only side. `isSource(source)` confirms the factory made it.

On each source:

| Event | Meaning |
| --- | --- |
| `Bound(address indexed depositor, PoolId indexed poolId)` | The hook bound, once. |
| `KeeperSet(address indexed keeper, bool allowed)` | A keeper allowed or stopped. |
| `FloatTargetSet(uint16 floatBps)`, `FloatTargetQueued(uint16 floatBps, uint40 readyAt)` | A float target applied, or a lower one waiting. |
| `BeneficiarySet(address indexed beneficiary)` | Where sGAGE and recovered collateral go. |
| `VaultProposed(address indexed vault, uint40 readyAt)`, `VaultProposalCancelled(address indexed vault)`, `VaultAttached(address indexed vault)` | A float-only side moving to lending. |
| `Rebalanced(uint256 swept, uint256 refilled, uint256 swapFloat)` | A keeper move: what went into the vault, what came back, the swap float left. |
| `PocketsClaimed(uint256[] pocketIds, uint256 proceeds)` | Pockets claimed; `proceeds` join the float over `RELEASE`. |
| `RewardsClaimed(uint256 amount)`, `Forwarded(address indexed token, address indexed to, uint256 amount)` | sGAGE brought in; a token sent to the beneficiary. |
| `ExitRequested(address indexed lp, uint256 assets, uint256 shares)` | An LP asked to exit now; the source's whole commitment at the exit desk. |

The source is also an ERC-4626 and ERC-20 (`Deposit`, `Withdraw`, `Transfer`) and uses OpenZeppelin `Ownable2Step` events.

## Errors you will meet

| Error | When |
| --- | --- |
| `NotAGageVault()` | The vault's factory is not in the GenerationDeployer's record, or did not create it. |
| `InvalidConfiguration()` | At creation: the vault lends another token, a zero or self beneficiary, or a token, PoolManager or record without code. At `bind`: no such pool, no hook contract, or a pool without the source's token. `setKeeper(address(0), …)`. |
| `InvalidFloatBps(uint16 floatBps)` | A float target outside 100 to 10,000. |
| `AlreadyBound()` | A second `bind`. |
| `VaultAlreadyAttached()`, `NoPendingVault()`, `AttachTooEarly(uint40 readyAt)` | `proposeVault` or `attachVault` out of turn. |
| `NoPendingFloat()`, `FloatTooEarly(uint40 readyAt)` | `applyFloatBps` with nothing waiting, or before its time. |
| `NotDepositor()` | A deposit or withdrawal from anyone but the bound hook. |
| `InsideUnlock()`, `NotASwap()`, `VaultSettling()` | A vault call inside a PoolManager unlock; a withdrawal inside an unlock that settles no debt of the hook's; a move while the vault settles a finished loan. |
| `ProtectedToken()` | `forward` of the source's own token or the vault's shares. |
| `OwnableUnauthorizedAccount(address account)` | An owner call from anyone but your Safe. |
| (no data) | `create` with a creator, salt and arguments already used, or a vault without `asset()`. |

## Examples

- `examples/foundry/test/RehypoSource.t.sol`: at the factory on mainnet, predicts and creates a float-only and a lent USDG source as the test's own account, reads back every setting, and shows each refusal: a lookalike vault, a vault naming a recorded factory that did not create it, an earlier generation's vault, another token's vault and a float target out of bounds. The factory is not in the manifest yet, so it takes its address from the environment and skips without it: `REHYPO_FACTORY=<factory> forge test --match-path test/RehypoSource.t.sol -vv` from `examples/foundry`.
- `examples/viem/src/generations-read.ts`: the source's vault check for any vault you pass.

```solidity
address predicted = factory.predict(partner, usdg, vault, partner, partner, 2_000, salt);
address source = factory.create(usdg, vault, partner, partner, 2_000, salt);
assertEq(source, predicted);
assertEq(IGageRehypoSource(source).REGISTRY(), addressOf("generationDeployer.address"));
assertEq(IGageRehypoSource(source).depositor(), address(0)); // no hook until the owner binds one
```

## What not to rely on

- **`isSource` as gage's endorsement.** The factory is open: anyone can create a source naming any owner. gage's keeper rebalances only the sources set up with gage through [PARTNERS.md](../../PARTNERS.md).
- **Swaps without gage's keeper.** A source never calls its vault inside a swap. Without `rebalance`, a lent side's float is not refilled after LP exits and swaps can narrow or stop: [rehypo-source.md](../rehypo-source.md), "Limits and risks".
- **A vault from any other factory.** The record cannot grow except through the GenerationDeployer's `deploy`. A generation from another deployer would not be accepted by sources created here.
- **Every LP leaving at once.** An exit beyond the float and the vault's free cash waits for loans to repay, or goes through the exit desk at book.
- **An audited hook.** OpenZeppelin marks `ReHypothecationHook` experimental. gage reviews the integration; you audit what you deploy.
