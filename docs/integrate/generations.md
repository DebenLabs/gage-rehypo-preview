# Lend-asset and stablecoin generations

A generation is one complete lending market for one lend asset: the token borrowers receive and partner vaults lend. USDG has its generation, and each other lend asset has its own: GLD, NVDA, HIMS and frxUSD, a stablecoin. Each generation is a set of immutable contracts around one core. A new version of the code is a new generation; an earlier one stays live for its own loans until they end. From this release, gage builds new stablecoin generations on chain with the **GenerationDeployer**, from creation code the deployer holds and anyone can read. Its record of Intent factories is also how anyone checks that a factory, and so a partner vault, is gage's: a rehypo source relies on it ([DEX partners](dex-partners.md)). Use this page to find a generation's contracts, to check a factory or a vault, and to follow new generations as they appear.

## Contracts

| Contract | Address | Source | ABI | Who controls it |
| --- | --- | --- | --- | --- |
| GenerationDeployer | `0xcea38204C97e9745f831978357d562E5CcC6834F` (from block `generationDeployer.startBlock`) | GenerationDeployer.sol | GenerationDeployer.json | gage's Safe (`owner()`, `Ownable2Step`): the only caller of `deploy` and `setListed`. It cannot change a blueprint or add a factory. |
| `IIntentFactoryRegistry` | implemented by the GenerationDeployer | [IIntentFactoryRegistry.sol](../../src/interfaces/IIntentFactoryRegistry.sol) | | No one: one view, `isFactory`. |
| USDG generation's factory | `0xB086944b140758b33694220d4Fe93C9A8D8618a1` | IntentFactory.sol | IntentFactory.json | gage's Safe (creators, quote signer, fillers, fill router, exit desk) |
| GLD generation's factory | `0x2a09498f11A70c4F2AB0a4e1B3323699bF7cC143` | same | same | same |
| NVDA generation's factory | `0xd1Fc8951289372C7260Ac0F7BC830bAbA49F109c` | same | same | same |
| HIMS generation's factory | `0x76030f3fd8631a2839D79fEfBf5EFf124229734a` | same | same | same |

Every part of a lend-asset generation sits under `intentV1Assets.<SYMBOL>` in the [manifest](../../deployments/manifest/4663.json); the USDG generation's sit under `intentV1`. Earlier generations are under `intentV1Previous` and `intentV1AssetsPrevious`.

| Part (`GenerationDeployer.Part`) | Contract | Manifest key of a lend-asset generation | Owner once built |
| --- | --- | --- | --- |
| `FEE_PROCESSOR` | IntentAssetV4FeeProcessor (GLD, NVDA and HIMS run the earlier IntentAssetFeeProcessor) | `feeProcessor` | gage's Safe, from construction |
| `CLOSED_RESERVE` | IntentClosedReserve | `reserve` | none |
| `TOKEN_REGISTRY` | GageV2TokenRegistry: terms, fee, collateral admissions, pause of new deals | `engine.registry` | gage's Safe |
| `CORE` | GageV2Vault: loans, escrow, the state machine; creates its rewards ledger | `core` | none |
| (created by the core) | GageV2Rewards: the core's sGAGE ledger (Rewards) | `engine.rewards` | none |
| `CASHOUT_ROUTER` | V4CashoutRouter (GLD, NVDA and HIMS run GageV2CashoutRouter) | `engine.cashoutRouter` | gage's Safe |
| `GRADE_REGISTRY` | GradeRegistry | `gradeRegistry` | gage's Safe, from construction |
| `FACTORY` | IntentFactory: creates partner vaults | `factory` | gage's Safe |
| `QUOTE_VERIFIER` | IntentQuoteVerifier | `quoteVerifier` | none |
| `FILL_ROUTER` | IntentFillRouter | `fillRouter` | none |
| `ROLLOVER_ROUTER` | RolloverRouter | `rolloverRouter` (GLD, NVDA, HIMS) | gage's Safe, from construction |
| `VAULT` | IntentVault: the partner vault's code, which the factory creates from | (each vault: the factory's `vaults(i)`) | the vault's curator |

**The frxUSD generation** is the first the GenerationDeployer built. Its contracts are not in this release's manifest yet. Read them on chain from the deployer's `GenerationDeployed` event, or from `factories(i)` for `i` at or above `RELEASE_FACTORY_COUNT()` (see [Call sequences](#call-sequences)). Its lend asset has 18 decimals.

## How it works

**A generation.** The core is immutable and has no owner. Its rewards ledger lets only the generation factory's vaults lend (`GageV2Rewards.funderGate()`, bound once to the factory), so every loan of the core is funded by a partner vault of that factory, through the factory's own fill router. A factory names its first fill router and its first exit desk for good (`boundFillRouter()`, `boundExitDesk()`): its owner can only close them (zero) and reopen them with the same contract. Every generation lends at a fixed cost with no liquidation: nothing can touch a loan's collateral before the end of its term; at the end the borrower repays, or the lender keeps the collateral.

**The GenerationDeployer's blueprints.** It holds one blueprint for each of the 11 parts (`PARTS`): the part's exact creation code, read back from one or two SSTORE2 data contracts (each a leading STOP byte, then up to 24,575 bytes of code). The constructor names them and emits `BlueprintFixed` for each, with the code's size and keccak256. Nothing can change them. `creationCode(part)` returns the code; `blueprint(part)` returns its chunks, size and hash. `VAULT` is not built by `deploy`: its two chunks are the factory's `codeA` and `codeB`, so every factory the deployer builds creates vaults from that code (`IntentFactory.VAULT_INIT_HASH()`).

**`deploy`.** The owner calls `deploy(salt, g)` with a `Generation`: a name (1 to 64 bytes, display only), the lend asset (6 to 18 decimals, never USDG or sGAGE), one to eight terms of 1 to 30 days, the fee and trade fee, up to 20 collateral admissions, up to 20 cash-out routes and 4 aggregator executors, the fee processor's path to USDG, and the fee keeper, grade publisher and filler (gage's keeper). It creates every part with CREATE2 under `salt`, so `predict(salt, g)` gives each address first, then wires them in this order:

1. The registry's fee and trade fee, each collateral admission, and the rollover router as its router.
2. The core's rewards ledger bound to the factory (`bindFunderGate`).
3. The cash-out router's v4 and V3 routes and its executors.
4. The factory's collateral categories, its fillers (gage's filler wallet and the rollover router), its fill router named then closed, and the chain's exit desk (`0x0c7e23f245377551A7fac3b3D05238Ac2E9Eefc2`).
5. The registry, the cash-out router and the factory handed to the owner (`transferOwnership`; the owner accepts each with `acceptOwnership`).

It records the factory (`FactoryRecorded`) and emits `GenerationDeployed`. The salt is the generation's id: one generation a salt. A generation leaves `deploy` with funding closed: its factory has no quote signer, no creator and its fill router closed, so no vault exists and nothing can fund a loan. The owner opens it in a later batch: the quote signer, the admitted creators, the fill router reopened, then `setListed(id, true)`. `listed` is display only: it changes no contract and no funding.

Every generation the deployer builds is a stablecoin market of the same shape: an unbridged core with no grace period, a closed reserve, the v4 cash-out router borrowing from the PoolManager, and a fee processor that sells the asset's fees to USDG along a v4 path and forwards the USDG to `DealFeeRouter` (`0xEaE95cD11e1105BF1E82033c918ff17f931B0245`), or to a rewards bridge once gage's Safe points it at one (`forwardTo()`, Rewards).

**The record (`IIntentFactoryRegistry`).** `isFactory(factory)` is true for two kinds of factory, and nothing else can ever be added:

- the release's own generations, given once to the constructor: USDG, GLD, NVDA and HIMS (`RELEASE_FACTORY_COUNT()` of them, at most 8). The constructor refused any that creates its vaults from other code than the `VAULT` blueprint;
- each factory `deploy` built.

`factoryCount()` and `factories(index)` list them in the order recorded: the release's first, then each built one. `factoryOf(id)` gives a built generation's factory. Earlier generations (`intentV1Previous`, `intentV1AssetsPrevious`) are not recorded.

## Call sequences

All reads; no approval, no gas.

1. **Check that a factory is gage's.** `isFactory(address factory) external view returns (bool recorded)` on the GenerationDeployer.
2. **Check that a vault is a gage partner vault**, as a rehypo source does:
   1. `PROTOCOL_SOURCE() external view returns (address)` on the vault: the factory that created it.
   2. `isFactory(source)` on the GenerationDeployer.
   3. `isVault(address vault) external view returns (bool)` on that factory.
   4. `asset()` on the vault, for the token it lends. A vault of an earlier generation has no `asset()`, and the call reverts.
3. **Find every generation.**
   - Without logs: `RELEASE_FACTORY_COUNT() external view returns (uint256)`, `factoryCount() external view returns (uint256)`, then `factories(uint256 index) external view returns (address)` for each index. For each factory, `CORE()`; on the core, `USDG()` is the lend asset (its own name for whatever the core lends), `REGISTRY()` the token registry and `REWARDS()` the ledger.
   - With logs: `GenerationDeployed` from block `generationDeployer.startBlock` gives every contract of each built generation in one event. The public RPC answers at most 10,000,000 blocks a query.
   - `listed(bytes32 id) external view returns (bool)` says whether gage shows it. A generation is open to lending when its factory's `quoteSigner()` is non-zero and `fillRouter()` is its `boundFillRouter()`.
4. **Check the code.** For each part, `keccak256(creationCode(part))` equals the `codeHash` that `blueprint(Part part) external view returns (address[2] memory chunks, uint256 size, bytes32 codeHash)` returns. Compare that hash with a build of the source in this repository. A recorded factory's `VAULT_INIT_HASH()` equals the `VAULT` blueprint's hash.
5. **Read a generation's terms and admissions** on its token registry: `allowedTerms()` (seconds), `feeBps()`, `getERC20Config(token)`. Amounts are raw units of each token: check its `decimals()`.

`predict(bytes32 salt, Generation calldata g) external view returns (Deployment memory d)` and `deploy(bytes32 salt, Generation calldata g) external onlyOwner returns (Deployment memory d)` take the whole `Generation` struct, defined in the source. Only gage's Safe calls `deploy` and `setListed(bytes32 id, bool listed_)`.

## Events to index

On the GenerationDeployer, from `generationDeployer.startBlock`:

| Event | Meaning |
| --- | --- |
| `BlueprintFixed(Part indexed part, address[2] chunks, uint256 size, bytes32 codeHash)` | Constructor only, once a part: the blueprint for good. |
| `FactoryRecorded(address indexed factory, address indexed core, address indexed asset)` | `isFactory(factory)` is true from now on: a release factory at construction, or one `deploy` built (just before its `GenerationDeployed`). |
| `GenerationDeployed(bytes32 indexed id, address indexed asset, address factory, address core, address registry, address rewards, address reserve, address feeProcessor, address quoteVerifier, address fillRouter, address gradeRegistry, address cashoutRouter, address rolloverRouter, string name)` | A generation built, funding closed. Each contract is a top-level field, for an event indexer's factory pattern. Its block is the generation's start block. |
| `GenerationListed(bytes32 indexed id, bool listed)` | The owner listed or unlisted it in the app. Display only. |
| `OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner)`, `OwnershipTransferred(address indexed previousOwner, address indexed newOwner)` | OpenZeppelin `Ownable2Step`, on the deployer and on each part it hands over. |

On a new generation's factory, its opening: `QuoteSignerSet(address indexed signer)`, `CreatorSet(address indexed creator, bool allowed)`, `OpenCreationSet(bool open)`, `FillRouterSet(address indexed router)`; then each vault: `VaultCreated(address indexed vault, address indexed curator, address creator, uint256 index)`. The registry's own events give its terms and admissions.

## Errors you will meet

Readers meet none, except a panic on `factories(index)` at or past `factoryCount()`. The owner's calls, which a simulation of a `Generation` meets too:

| Error | When |
| --- | --- |
| `OwnableUnauthorizedAccount(address account)` | `deploy` or `setListed` from anyone but the owner. |
| `SaltUsed(bytes32 id)` | A generation was already built under this salt. |
| `InvalidName()` | Empty, or longer than `MAX_NAME_BYTES` (64). |
| `InvalidAsset(address asset)` | The lend asset is not a contract, or is USDG or sGAGE. |
| `InvalidAdmission(address token)` | A collateral token is zero or the lend asset. |
| `InvalidRole()` | Zero filler or grade publisher. |
| `TooManyAdmissions(uint256 count, uint256 max)`, `TooManyRoutes(uint256 count, uint256 max)`, `TooManyExecutors(uint256 count, uint256 max)` | Over 20 admissions, 20 routes together, or 4 executors. |
| `DeploymentFailed(Part part)` | CREATE2 made no contract; a part's own constructor revert is passed on as it is. |
| `UnknownGeneration(bytes32 id)` | `setListed` for an id `deploy` never used. |

## Examples

- `examples/foundry/test/Generations.t.sol`: checks the deployer's shared contracts against the manifest, every blueprint against its hash, that each lend-asset factory in the manifest is recorded and each earlier one is not, lists the generations `deploy` built, and runs the rehypo source's vault check. `forge test --match-path test/Generations.t.sol -vv` from `examples/foundry`.
- `examples/viem/src/generations-read.ts`: the same reads with viem, every `GenerationDeployed` event with `listed(id)`, and the vault check for any vault you pass. `npx tsx src/generations-read.ts [vault]` from `examples/viem`.

```solidity
for (uint256 i = deployer.RELEASE_FACTORY_COUNT(); i < deployer.factoryCount(); ++i) {
    address factory = deployer.factories(i);
    address core = IIntentFactory(factory).CORE();
    address asset = ICore(core).USDG(); // the lend asset
    assertTrue(deployer.isFactory(factory));
    assertEq(ICore(core).BRIDGE(), address(0), "unbridged");
}
```

## What not to rely on

- **The manifest as the list of generations.** A generation the deployer built can exist before the manifest names it, as frxUSD's does. Read the deployer.
- **`listed` as a switch.** It is what gage's app shows. Whether a generation lends is its factory's quote signer and fill router.
- **A built generation being open.** It leaves `deploy` with funding closed and stays so until the owner opens it.
- **Earlier generations in the record.** They are not recorded, and their vaults predate the ERC-4626 surface a rehypo source reads.
- **This deployer as the only one ever.** A rehypo source and its factory read this deployer's record for good (`REGISTRY()`). A generation from any other deployer would not be accepted by them.
- **Names and order.** A generation's name is display text, and `factories(i)` is only the order of recording.
- **Owners.** gage's Safe owns the deployer and the parts listed above, and `Ownable2Step` lets it hand them on.
