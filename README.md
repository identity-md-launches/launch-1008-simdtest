# SIMDTEST launch

This Foundry project implements the immutable SIMDTEST token, its Uniswap v4 IMD fee hook, and its staking vault. `launch.json` uses the `univ4_hook` manifest kind and names **SIMDTESTHook itself**. There is no proxy, owner, admin, upgrade path, fee setter, emergency withdrawal, or post-deployment configuration.

## Build and checks

```sh
forge build
forge test
forge fmt --check
```

The project pins Solidity **0.8.26**, Cancun, optimizer enabled with 200 runs, and `bytecode_hash = "none"`. Dependencies are ordinary source files under `lib/`; no package installation, submodule, environment variable, FFI, or filesystem permission is needed by the tests. The verification worker supplies the pinned compiler. Dependency commits and licenses are recorded in each dependency's `UPSTREAM.txt` and license files. Dynamic test linking is disabled so tests and the CREATE2 miner hash the same creation code.

Default tests deploy the actual vendored Uniswap PoolManager, with a conventional ERC-20 at the prescribed IMD address. The separate mainnet suite uses the **deployed mainnet PoolManager and actual IMD code** when a fork is supplied:

```sh
forge test --match-contract MainnetForkTest --fork-url <mainnet-archive-rpc-url> --fork-block-number <recent-block> -vv
```

Choose a recent block where both prescribed contracts exist. The suite funds its test account using Foundry's ERC-20 `deal` helper; that is local fork state only. Tests never read or mutate environment variables. Without a supplied fork, the mainnet suite explicitly reports a skip. Public RPC probes in this assignment returned HTTP 403, so live mainnet execution and verification of IMD's current transfer behavior remain outstanding. A skipped fork is not a successful fork rehearsal.

## Deployment parameters and factory responsibilities

| Item | Value |
| --- | --- |
| Network | Ethereum mainnet, chainId **1** |
| PoolManager constructor argument | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| IMD paired currency | `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` (18 decimals) |
| Hackathon fee recipient | `0x3dd5f73dd1a4e62630fad3909673f130ad429985` |
| Static pool LP fee | **12500**, or **1.25%** |
| Tick spacing | **60** |
| Manifest initialPrice | `79228162514264337593543950336`; provenance only |
| Hook permission mask | **0x20cc**, decimal **8396** |
| Hook constructor | `(IPoolManager poolManager, IERC20 token)` |
| Manifest arguments | `["$poolManager", "$token"]` |

The factory must:

1. Deploy `SIMDTEST` with no arguments. Its constructor mints **1,000,000,000 × 10^18 = 10^27** units to its deployer. Name and symbol are both `SIMDTEST`; decimals are 18. Transfers are ordinary ERC-20 transfers with no tax, including transfers to PoolManager.
2. Resolve `$poolManager` to the mainnet address above and `$token` to this freshly deployed token. Mine a CREATE2 salt using the **actual factory address**, hook creation code, and exact ABI-encoded constructor arguments. `script/MineHook.sol` provides a bounded pure `find(factory, manager, token, start, count)` helper. This helper is for simulation; the factory deploys the hook directly. Changing constructor arguments, factory, compiler, or code invalidates the mined address. The hook constructor checks its permission bits.
3. In the **same transaction**, deploy the hook and initialize the sorted token/IMD PoolKey, fee 12500, spacing 60. The hook validates the full immutable pool ID in `beforeInitialize`; the callback prevents initialization while the predicted hook address has no code. Initialization has no sender allowlist, so separate deployment and initialization transactions would allow a third party to set the first price. The factory chooses the actual opening price from launch economics, not the manifest's provenance value.
4. Seed the pool with the launch's 90% allocation and the factory-provided IMD, route the swarm's 10% through its external Merkle distributor, and handle `remainderTo`. None of these allocation operations belongs to the token, hook, or vault. No allocation recipient or funding wallet has been invented here.
5. Record `hook.vault()`. The hook creates `SIMDTESTVault` in its constructor with immutable token, IMD, and hook addresses, so no separately supplied vault address or later setter is needed.

`openingBlock` is the deployment block, as requested. Delaying pool opening does not reset the clock; the launch factory is responsible for atomic deployment/opening. There is no chain-ID rejection inside the contracts, allowing the prescribed deployment to be rehearsed locally; the deployment pipeline must enforce mainnet and the correct manager argument.

## Fees and swap accounting

At block `openingBlock + n`, the anti-snipe rate is `3000 - 300*n` basis points for `n = 0..9` and zero for `n >= 10`. The deployment block is 30%, the next block 27%, block +9 is 3%, and block +10 is 0%. A separate **100 basis point (1%)** staking fee applies forever. These fees are in addition to the static 1.25% LP fee; the hook never sets a dynamic-fee flag, calls `updateDynamicLPFee`, or returns an LP-fee override.

Both hook fees use **gross IMD**: the total IMD paid by a buyer, or the IMD output before hook deductions for a seller. Each component rounds down independently to the nearest IMD base unit. Tiny amounts can therefore round to zero. Exact-input budgets include the hook fee; exact-output requests specify the user's net output. `sqrtPriceLimitX96` remains the trader's limit, and only executed amounts are taxed when liquidity or that limit causes partial execution.

| Swap | IMD is | Fee delta |
| --- | --- | --- |
| Buy, exact input | Specified input | `beforeSwap` specified delta |
| Sell, exact output | Specified output | `beforeSwap` specified delta |
| Buy, exact output | Unspecified input | `afterSwap` unspecified delta |
| Sell, exact input | Unspecified output | `afterSwap` unspecified delta |

The specified-IMD cases use one **self-only reverting quote** against PoolManager before returning the fee delta. The manager skips callbacks when a hook initiates its own swap; the quote reverts with the amount, rolling back all simulated pool changes, balance deltas, and events. The outer swap then executes normally. This determines an actual partial fill before `beforeSwap` must commit its specified delta; `afterSwap` cannot repair a specified-currency fee. It costs an extra pool swap simulation for those two modes. No user data can choose a quote target or bypass authorization.

Gross-up examines four candidates to invert the two independently rounded fees. Choosing the smallest exact inverse prevents a fee jump at a rounding boundary from overcharging partial fills. Very large int256 requests are quoted without prematurely narrowing the request to int128; the test suite includes `2^200` and `int256.min` exact-input requests with finite fills. A positive specified IMD output whose gross-up exceeds `int256.max` reverts with `UnrepresentableFee` (wrapped by PoolManager). Uniswap's own price-validity, liquidity, settlement, and signed-int128 **executed balance** limits still apply.

The enabled permissions are exactly `beforeInitialize`, `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta`, and `afterSwapReturnDelta`; all other permissions are false. Every callback checks the immutable PoolManager. The hook does not intercept token transfers or liquidity changes. Adding or removing liquidity is therefore never charged a hook fee, including a one-sided SIMDTEST position placed just above the price that later buyers fill: that is a limit order carried by the pool, not a swap, and the buyers who fill it pay the hook fee on their own IMD. Charging it would need liquidity callbacks and a factory allowlist for the seeding position, neither of which this launch defines. Its swap callbacks mint **ERC-6909 IMD claims** instead of transferring tokens out of PoolManager, so fee collection does not require a pre-funded manager balance before router settlement. Successful unlocks must settle all deltas to zero.

## Sweep and staking

Anyone can call `hook.sweep()` at any block. It burns accrued IMD claims and transfers anti-snipe fees to the fixed hackathon vault and staking fees to `hook.vault()`, then calls `notifyReward(stakingAmount)`. Calling with nothing accrued is a no-op. It opens a PoolManager unlock when needed, or redeems within an existing unlock. The authenticated unlock callback can run only during an active sweep. Callers never choose recipients or receive a bounty.

If an IMD transfer fails, the entire sweep rolls back, preserving both claims and fee counters for a later retry. Swaps continue to collect claims without attempting those transfers. Sweeping inside someone else's unlock requires IMD liquidity already settled in the manager; an ordinary separate transaction sweeps after trades have settled.

The hook notifies the vault with the IMD the vault actually received from the sweep, not the amount requested. With the plain ERC-20 IMD is assumed to be, the two are equal. If IMD ever delivered less than requested (a transfer fee or downward rebase), the sweep would still complete and the hackathon payout would still land; the shortfall would fall on stakers, whose rewards are credited on accrued fees, so the last claims against an underfunded vault revert until new fees arrive. Principal is never affected. `test_ShortDeliveryByIMDStillSweepsBothStreams` exercises this.

Approve the vault to spend SIMDTEST, then call:

- `stake(amount)` to deposit your own tokens; zero amounts fail. The stake is **pending** for the rest of the block it is made in and becomes reward-eligible from the next block.
- `unstake(amount)` to withdraw your own principal at any time, including in the same block as the stake (which simply cancels the pending part) and after all rewards have been claimed. Excess withdrawals fail. This never sweeps or transfers IMD, so a reward-transfer failure cannot lock principal.
- `claim()` to sweep outstanding fees and receive your own earned IMD. Unstaking preserves prior earned rewards. Repeating a completed claim pays zero.
- `totalStaked()`, `balanceOf(account)`, `earned(account)`, and `pending()` for the UI. `totalStaked()` and `balanceOf` count pending and eligible principal together; `activeStake()`, `pendingStake()`, `activeOf` and `pendingOf` split them. `earned` includes accrued but unswept IMD. `pending()` is the global total of accrued, unclaimed rewards, including unallocated queue and rounding residue; it is not one user's claimable amount.

The reward-per-token accumulator reads the hook's monotonic `totalStakingFees()` before stake changes. Rewards therefore belong to holders who were staked when swaps accrued them, even if someone sweeps much later. Joining immediately before a sweep cannot capture historical rewards.

**Eligibility starts the block after staking.** A stake made in block *B* earns only fees accrued in blocks after *B*. The hook records the cumulative staking fee at the end of every block in which a fee accrued (`lastAccrualBlock`, `stakingFeesAtEndOf`), so the vault can settle block *B*'s fees to the stake that already existed, then let the new stake share everything afterwards, exactly, even if nobody touches the vault for many blocks in between. Consequences:

- A stake that exists only inside one PoolManager unlock, or only for the block of a swap, earns nothing from that swap. Flash-staking pool-held SIMDTEST around one's own swap, or staking just ahead of someone else's buy and leaving in the same block, cannot recapture the 1% staking fee. `test/JitStaking.t.sol` reproduces both against the real PoolManager.
- There is still no lock period and no minimum stake duration. Principal can always be withdrawn in the same transaction. A sandwich that stakes at least one block ahead of a target swap and holds real capital across that block boundary remains possible; it is pro rata and carries price risk for the block.
- Stakes made in the same block mature together and share subsequent fees pro rata.

**No-staker policy:** rewards accrued while no stake is eligible are queued and allocated to the first stakes that mature, pro rata among stakes made in the same block. Even a one-unit stake qualifies and anyone may race to be first, but the stake must survive to the next block, so pool-held tokens borrowed inside an unlock cannot take the queue. This explicit policy avoids permanently stranded rewards; it does not give any former staker entitlement to later no-staker periods.

The accumulator uses 1e36 precision and retains global and per-account fractions. `earned()` and claims round down to whole IMD base units. Tiny residue can remain pending until future accrual; it cannot be withdrawn by an administrator. Direct unsolicited token transfers create no stake or reward credit and have no rescue path.

SIMDTEST is a standard ERC-20. The integration assumes the fixed IMD token continues to transfer the requested amount without tax or rebasing. Verify that assumption using the delivered fork suite before release. If IMD transfer behavior changes, sweeps/claims may fail, while SIMDTEST principal remains withdrawable.

## Review evidence

The requested four independent specialist agent reviews cover swaps, staking accounting, access controls, and deployment/token behavior. Their reports and a separate judge review are in `docs/`. These are assignment-local adversarial reviews, not a claim of an outside audit firm's certification. A rounding defect found in review was repaired and retained as a regression test. An independent post-acceptance review then found that zero-duration (flash or JIT) stakes could recapture the staking fee; the block-delayed eligibility described above is the repair, with regression tests in `test/JitStaking.t.sol` and `test/VaultAdversarial.t.sol`. See [docs/review.md](docs/review.md) for final checks, the revision record and remaining release responsibilities.

Upstream accounting references: [Uniswap flash accounting](https://developers.uniswap.org/docs/protocols/v4/concepts/flash-accounting) and the pinned [v4 Hooks implementation](https://github.com/Uniswap/v4-core/blob/46c6834698c48bc4a463a86d8420f4eb1d7f3b75/src/libraries/Hooks.sol). The delivered code and tests define the launch behavior; upstream examples do not change these parameters.
