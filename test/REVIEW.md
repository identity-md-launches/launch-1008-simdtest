SIMDTEST test contribution and review record

This contribution extends the accepted implementation without modifying contracts,
manifest, configuration, scripts, or dependencies. The protected hook/token checks
and supplied testing/security references were read as task inputs.

Added coverage:

| Test file | Coverage added |
| --- | --- |
| `TokenOnlyPool.t.sol` | Fresh real local PoolManager seeded only with SIMDTEST, zero initial IMD reserves, both currency orderings, exact-input/output first buys, claim accounting and public sweeps; 1,000 fuzz cases per ordering. |
| `LaunchFailurePaths.t.sol` | Second sweep transfer failure rolls back the earlier payment; failed claim rolls back its nested sweep; failed principal transfers preserve checkpoints; invalid prices/zero swaps, empty pools in all modes, sampled admin calls. Runs locally and on mainnet forks. |
| `VaultFailurePaths.t.sol` | Invalid dependencies, zero/over withdrawals, insufficient balance/allowance, replayed/unfunded notifications, donations, partial exits with historical rewards; 1,000 fuzz cases. |
| `VaultModelInvariant.t.sol` | Independent per-fee reward allocation model across stake, unstake, accrue, claim, sweep, donation and rejected-withdrawal sequences. 256 runs of depth 64, fail-on-revert, plus complete exits after each sequence. |
| `DeploymentBoundary.t.sol` | Independent reconstruction of all 14 permission bits, wrong-address-bit constructor rejection, invalid dependencies, static fee/key binding and creation-code size. |
| `Hook.t.sol` | Added 1,000-case mainnet swap fuzz test covering both trade directions, exact-input/output and blocks around the decay boundary. |

The existing end-to-end hook invariant remains active: 128 runs of depth 64.
The vault model does not read implementation accumulators to compute entitlements.
Its integer-floor oracle allows less than one wei per reward interval and one
additional wei for global accumulator precision, with exact aggregate solvency.
Direct donations are tracked separately from liabilities. Helper fee accrual and
sweeping are distinct, and an empty helper sweep returns without notification.

Four independent specialist agent reviews were completed:

| Specialist | Evidence and disposition |
| --- | --- |
| Swap arithmetic and v4 settlement | Reviewed all four trade modes, reverting quotes, partial fills, gross-up rounding and claim collection; requested and reviewed fresh token-only pool tests. No actionable defect found. |
| Vault accounting | Reviewed checkpoints, fractions, membership changes, notification authorization and conservation; reviewed the independent model and its bounds. No actionable defect found. |
| Access and external calls | Reviewed callback authorization, self-only quotes, unexpected unlock rejection and reentrancy guards; identified second-transfer rollback and failed-claim coverage gaps, now tested. No actionable defect found. |
| Deployment and token | Reviewed full deployer supply, direct CREATE2, immutable wiring, permission mask, manifest pool terms, runtime opcode checks and size bounds; independently checked new deployment tests. No actionable defect found. |

Final judge disposition for this bounded test contribution: PASS. The lead agent
reviewed the specialist conclusions, corrected a test fixture that reused an
already-reached price limit, and verified the completed suite. No reproducible
contract finding required an implementation change or `.imd-findings.json`.
This is a local agent review disposition, not an external audit certificate or
an approval issued by the IMD network.

Validation with Foundry 1.8.3 and Solidity 0.8.26:

- `forge build`: passed. Existing production-source lint warnings remain; no
  implementation or configuration changes were made to suppress them.
- Default offline suite: **64 passed, 0 failed, 2 fork setup skips**.
- Mainnet fork at block **26,145,919**: **14 passed, 0 failed, 0 skipped**, including
  1,000 swap fuzz cases against the actual mainnet PoolManager and IMD contracts.
- New vault invariant: **16,384 handler calls, zero unexpected reverts**.
- Existing launch invariant: **8,192 handler calls, zero unexpected reverts**.

Reproduction commands (generated artifacts stay in disposable scratch):

```sh
forge build --out test/scratch/out --cache-path test/scratch/cache
forge test --out test/scratch/out --cache-path test/scratch/cache
forge test --out test/scratch/out --cache-path test/scratch/cache \
  --fork-url https://ethereum-rpc.publicnode.com \
  --fork-block-number 26145919 --no-storage-caching \
  --match-contract 'MainnetForkTest|LaunchFailurePathsForkTest'
```

Default tests require no network, new dependencies, environment mutation or scratch
sources. Fork suites explicitly skip without a mainnet fork. The fork fixture
funds test trades with `deal`; it does not replace the mainnet IMD or PoolManager
code. Failure-injection cases temporarily mock specific ERC-20 responses to test
atomic rollback; normal fork swaps and sweeps use the actual deployed contracts.

The external launch factory, its distribution/Merkle process, actual deployment
transaction and opening-price economics are outside this test assignment. Factory
resolution of authentic constructor dependencies and atomic deployment/initialization
remain required. Finite admin-selector probes supplement source review and are
not an exhaustive proof of absent privileges.
