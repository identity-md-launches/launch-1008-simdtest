SIMDTEST test contribution and review record

This contribution extends the accepted implementation without modifying contracts,
manifest, configuration, scripts, or dependencies. The protected hook/token checks
and supplied testing/security references were read as task inputs.

Revision (2026-10-08, second round)
-----------------------------------

Between rounds the implementation changed: a stake is now pending for the block it is
made in and earns from the next block, and the hook records per-block staking-fee
boundaries (`lastAccrualBlock`, `stakingFeesAtEndOf`) so the vault can settle a stake's
own block exactly without checkpoints. The first-round suite was written against
same-block eligibility and no longer compiled (`VaultRewardSource` lacked the two new
interface functions). Changes in this round, kept to what the new semantics require:

| File | Change |
| --- | --- |
| `helpers/VaultRewardSource.sol` | Implements the new interface, mirroring `SIMDTESTHook._accrue` byte for byte: a block's end total is written only when a later block accrues; zero accruals leave no record. |
| `VaultModelInvariant.t.sol` | The independent oracle now models blocks: a `roll` action, eager maturation at the next block, same-block cancellation that never earns, and fees queued while nothing is eligible going to the first stakes that mature pro rata. New assertions tie the vault's `pendingOf`/`pendingStake`/`activeStake` to the model and bound reward leakage. 256 runs of depth 64, fail-on-revert; a scratch copy at 1,024 runs of depth 128 (131,072 calls, zero reverts) also passed. |
| `VaultFailurePaths.t.sol` | Stakes mature before accrual where earnings are asserted. New: same-block over-withdrawal counts pending and eligible together; a cancelled pending stake earns nothing and leaves the queue to the next matured stake; a bucket emptied and refilled in one block keeps the boundary exact; 1,000-case fuzz that a same-block stake never takes that block's fees, whichever order stake and accrual happen in, with and without an intermediate sweep, across 1-50 untouched blocks. |
| `FeeBoundaries.t.sol` (new) | Against the real local PoolManager: 500 random swap/block walks check every `stakingFeesAtEndOf` entry against an independent end-of-block ledger (closed blocks exact, the open last block and fee-less blocks unwritten); 300 random walks with a second staker joining at a random step check that an untouched vault settles each block to exactly the stake eligible in it, with equality, then claims match. |
| `LaunchFailurePaths.t.sol`, `TokenOnlyPool.t.sol` | Mature stakes before the swap whose fee is asserted; the token-only first buy now also checks that the fee of the stake's own block is queued and lands when the stake matures. |

Review of the revised code (adversarial, no defect found): the boundary fallback
(`max(stakingFeesAtEndOf[B], pendingFees)`) was checked for the three cases of a stake
block with no accrual, an accrual before the stake and an accrual after it, and for the
live-total path when the stake block is still the last accrual block; `boundary >=
accountedFees` holds on every path, so the preview cannot underflow; a bucket is written
once per block and cannot be re-created after a flush; per-user pending from a bucket
flushed by somebody else settles through `activationRewardPerToken`. The remaining
economic consequences (first matured stake takes the no-staker queue, a sandwich that
holds across a block boundary earns pro rata, fee clock starts at deployment) are
documented policy, not defects.

First round (unchanged)
-----------------------

| Test file | Coverage added |
| --- | --- |
| `TokenOnlyPool.t.sol` | Fresh real local PoolManager seeded only with SIMDTEST, zero initial IMD reserves, both currency orderings, exact-input/output first buys, claim accounting and public sweeps; 1,000 fuzz cases per ordering. |
| `LaunchFailurePaths.t.sol` | Second sweep transfer failure rolls back the earlier payment; failed claim rolls back its nested sweep; failed principal transfers preserve checkpoints; invalid prices/zero swaps, empty pools in all modes, sampled admin calls. Runs locally and on mainnet forks. |
| `VaultFailurePaths.t.sol` | Invalid dependencies, zero/over withdrawals, insufficient balance/allowance, replayed/unfunded notifications, donations, partial exits with historical rewards; 1,000 fuzz cases. |
| `VaultModelInvariant.t.sol` | Independent per-fee reward allocation model across stake, unstake, accrue, claim, sweep, donation and rejected-withdrawal sequences, plus complete exits after each sequence. |
| `DeploymentBoundary.t.sol` | Independent reconstruction of all 14 permission bits, wrong-address-bit constructor rejection, invalid dependencies, static fee/key binding and creation-code size. |
| `Hook.t.sol` | Added 1,000-case mainnet swap fuzz test covering both trade directions, exact-input/output and blocks around the decay boundary. |

The vault model does not read implementation accumulators to compute entitlements.
Its integer-floor oracle allows less than one wei per reward interval and one
additional wei for global accumulator precision, with exact aggregate solvency.
Direct donations are tracked separately from liabilities.

Validation with Foundry 1.8.3 and Solidity 0.8.26 (this round):

- `forge build`: passed.
- Default offline suite: **79 passed, 0 failed, 2 fork setup skips** (19 suites).
- Mainnet fork at block **26,146,250** (PublicNode): **14 passed, 0 failed, 0 skipped**,
  including 1,000 swap fuzz cases against the deployed mainnet PoolManager and IMD.
- Launch invariant: 8,192 handler calls, zero reverts. Vault model invariant: 16,384 calls
  (delivered) and 131,072 calls (scratch stress), zero reverts.

Reproduction commands (generated artifacts stay in disposable scratch):

```sh
forge build --out test/scratch/out --cache-path test/scratch/cache
forge test --out test/scratch/out --cache-path test/scratch/cache
forge test --out test/scratch/out --cache-path test/scratch/cache \
  --fork-url https://ethereum-rpc.publicnode.com \
  --fork-block-number 26146250 \
  --match-contract 'MainnetForkTest|LaunchFailurePathsForkTest'
```

Default tests require no network, new dependencies, environment mutation or scratch
sources. Fork suites explicitly skip without a mainnet fork. The fork fixture funds
test trades with `deal`; it does not replace the mainnet IMD or PoolManager code.
Failure-injection cases temporarily mock specific ERC-20 responses to test atomic
rollback; normal fork swaps and sweeps use the actual deployed contracts.

Untested edges, stated as such: liquidity changes are not intercepted by the hook
(documented boundary, not a swap); the hook's fee clock starting at construction is
not something a test can protect, it is the factory's atomic deploy-and-initialize
duty. The external launch factory, its distribution/Merkle process, actual deployment
transaction and opening-price economics are outside this test assignment. Finite
admin-selector probes supplement source review and are not an exhaustive proof of
absent privileges. No `.imd-findings.json` was written: no reproducible defect was found.
