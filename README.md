# PAPERCLASH (PCLASH)

A plain, fixed-supply ERC-20 token for an IdentityMD custom token launch on Ethereum (chain id 1).

| Parameter | Value |
|---|---|
| Solidity contract | `PaperClashToken` (`src/PaperClashToken.sol`) |
| `name()` | `PAPERCLASH` |
| `symbol()` | `PCLASH` |
| `decimals()` | `18` |
| `totalSupply()` | `1_000_000_000_000_000_000_000_000_000` minor units (1,000,000,000 tokens) |
| Constructor arguments | none |
| Owner / admin | none |

## Behaviour

- The constructor mints the whole supply once to `msg.sender`, the deployer. Under the launch the
  deployer is the ProjectFactory, which then pays the supply out (swarm share to the MerkleDistributor,
  pool share to the Uniswap v4 PoolManager, remainder to `economics.remainderTo`).
- Transfers, approvals and `transferFrom` are the unmodified OpenZeppelin v5.1.0 `ERC20`
  implementation: no fee, no burn on transfer, no blocklist, no pause, no hook, no reflections.
  Every launch flow therefore moves exactly what it says.
- There is no mint function, no owner, no upgrade path and no initializer. The supply can never grow.
  The contract has no `receive`/`fallback`, so it accepts no ether.
- `transferFrom` moves tokens only with an allowance the holder granted; nobody but a holder can move or
  freeze a holder's balance.
- The constructor makes no outside call and requires no address to have code, so the launch's
  empty-chain admission run deploys it as is.

## Assumptions and design choices

- The brief fixes name, symbol, supply and decimals; all four are `constant`s on the contract
  (`TOKEN_NAME`, `TOKEN_SYMBOL`, `TOKEN_DECIMALS`, `TOTAL_SUPPLY`). Nothing is left open, so no
  value had to be chosen or asked for.
- The token exempts nobody because it taxes nobody: the factory, the PoolManager and the distributor
  need no special treatment, so the constructor takes neither `$factory`, `$poolManager` nor
  `$launchNumber`.
- `decimals()` is the ERC-20 default of 18, inherited unchanged.
- The contract name `PaperClashToken` is 15 characters, within the manifest's 32-character limit, and
  is deliberately not the token's name or symbol.
- Burns: the contract offers no burn function. Holders can only lower the circulating supply by sending
  tokens to an address nobody controls, which the contract neither helps nor prevents.

## Deployment parameters (for the manifest step, which writes `launch.json`; this repository does not)

- `token.contract`: `PaperClashToken`
- `token.name`: `PAPERCLASH`, `token.symbol`: `PCLASH`, `token.decimals`: `18`
- `token.totalSupply`: `1000000000000000000000000000`
- `token.constructorArgs`: `[]`
- `contracts`: `[]` (no application contracts)
- Launch values decided by the launch and copied by the manifest step: chain id 1, paired currency
  native ETH (zero address), pool fee 12500, tick spacing 60, initial price
  `79228162514264337593543950336` (provenance only), economics
  `{"poolBps":8400,"initialMarketCapWei":"10000000000000000000","remainderTo":"0x863e974406764c8526b102c28a1e53906e032954"}`.

## After launch

Nothing to configure. The contract has no owner-settable value, no setter and no admin function.

## Operational responsibilities

- IMD's deployer launches the token through the factory from the bytecode as built here; nobody in
  this repository deploys, broadcasts or signs anything.
- Whoever holds the remainder address (`economics.remainderTo`) is responsible for the custody of the
  requester's 6% share; the contract gives nobody a way to recover tokens sent to a wrong address.
- Pool liquidity, the distributor's claims and trading are run by the factory, the MerkleDistributor
  and the Uniswap v4 PoolManager; the token has no role in them beyond plain transfers.
- Tests passing is not a security audit. The token is the unmodified audited OpenZeppelin ERC-20 with a
  one-line constructor, but the launch as a whole should still go through the network's independent
  adversarial review before release.

## Build and test

```
forge build
forge test
forge fmt --check
```

`foundry.toml` pins `solc = "0.8.26"`, sets `bytecode_hash = "none"` and `cbor_metadata = false` so the
deployed bytes are reproducible, enables the optimizer (200 runs), disables `ffi` and grants no
filesystem permissions. Fuzz tests run with 256 runs; the verifier's seed
(`FOUNDRY_FUZZ_SEED=0xe4ebc3e63de62517e190030306194e15260946cd68c18bc7947060fa78575ba7`) was used
locally and all tests pass with it. Tests read no environment variables and do not depend on the
caller's address.

## Dependencies (vendored as plain files, no submodules)

- `lib/forge-std` — foundry-rs/forge-std v1.9.7 (tests only).
- `lib/openzeppelin-contracts` — the five files of OpenZeppelin Contracts v5.1.0 that `ERC20` needs
  (`ERC20.sol`, `IERC20.sol`, `IERC20Metadata.sol`, `Context.sol`, `draft-IERC6093.sol`) with its
  MIT licence.

## Tests (`test/PaperClashToken.t.sol`)

- Metadata, supply and decimals match the brief; the constructor emits one `Transfer` from the zero
  address; the creation code takes no constructor argument.
- Deployment through a CREATE2 factory probe mints to the factory, not to the EOA that called it, and
  the factory can pay the supply out in full.
- Transfer and `transferFrom` success paths with exact balances, allowance accounting, infinite
  allowance, zero-amount and self transfers.
- Failure paths: insufficient balance, no balance, zero-address receiver and spender, allowance
  exceeded, no allowance, owner balance short.
- No admin surface: common mint/ownership/upgrade/pause/blocklist/freeze/seize/burnFrom selectors all
  revert from a stranger and from the deployer; the deployer cannot pull a holder's balance; ether is
  refused.
- The reachable runtime code holds no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT` and fits EIP-170.
- Fuzz: transfers and `transferFrom` conserve the supply and move exactly the amount; amounts above the
  balance or the allowance revert with the exact error.
