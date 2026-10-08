# Implementation and adversarial review record

Date: 2026-10-08. Compiler: Solidity 0.8.26. Foundry: 1.8.3.

The local deliverable implements the token, fee hook, staking vault, CREATE2 mining helper, vendored dependencies, test suites, deployment manifest, and operator documentation. No deployment, broadcast, funded wallet operation, owner configuration, or swarm allocation was performed.

## Final checks

| Check | Result |
| --- | --- |
| `forge build` | Passed with the pinned compiler |
| `forge test` | **44 passed, 0 failed, 1 skipped**, across ten suites |
| `forge fmt --check` | Passed |
| Stateful launch invariant | 128 runs × 64 actions = **8,192 calls, zero reverts** |
| Isolated vault sequence fuzz | 512 runs × 150 interleaved actions |
| Swap fuzz | Four properties at 1,000 runs each, including partial-fill rounding |
| Token transfer fuzz | 256 runs |
| Targeted gas profile | Passed: 48 routed swaps across all modes and decay blocks |
| Mainnet-fork suite | **Skipped offline; live execution unverified** |
| Manifest fields | Exact task values checked, including `kind: univ4_hook` |
| Formal manifest schema validator | Not supplied; not claimed |
| Forbidden runtime opcodes | PUSH-aware checks pass for hook, vault, and token |

Swap scenarios run through the real local PoolManager for both possible IMD/token currency orderings, both trade directions, exact input and output, every initial decay block, and post-decay trading. Checks cover the static LP fee, actual wallet balance changes, return-delta settlement, empty pools, price-limited partial execution, very large int256 requests, and the explicitly rejected gross-output overflow. There is no transfer tax or liquidity fee in the launch token.

The targeted `--gas-report` run measured the test settlement router's complete swap calls at 141,157–292,965 gas (165,340 average across 48 calls). These measurements include PoolManager and ERC-20 settlement and depend on liquidity/tick traversal; they are not callback-only bounds or mainnet gas estimates.

Integration scenarios exercise fee sweep recipients and counters, repeated sweeps, sweeps inside an existing manager unlock, immediate earned balances before sweeping, multiple staker transitions, claims after exiting, and zero-staker queues. A failing IMD transfer leaves claims/counters intact and does not prevent SIMDTEST principal withdrawal.

The invariant checks manager delta settlement, claim/counter equality, total token supply, stake custody, user principal conservation, earned-reward solvency, and conservation across accrued claims, funded rewards and payouts. The independent vault sequence test repeats stake, unstake, accrue, sweep and claim operations across four actors.

## Specialist reviews and repair

1. [Swap accounting](audit-swap.md): found a two-wei partial-fill rounding overcharge, repaired and retained as a concrete regression. The repaired gross-up selects the smallest exact inverse within its four-candidate rounding window. Three dedicated rounding fuzz tests pass.
2. [Vault economics and conservation](audit-vault.md): no blocking defect found. Reviewed unswept reward timing, accumulator fractions, no-staker queues, authorization and principal custody.
3. [Access and initialization](audit-access.md): no actionable finding. Verified callback authentication, complete pool-key binding, counterfactual initialization rejection, direct deployment, immutable vault relationships and opcode restrictions.
4. [Deployment and token](audit-deployment.md): no unresolved contract defect found. Confirmed full supply to deployer, manifest kind/fields, constructor resolution, permission mining, code size and ordinary-file dependency availability.

The final independent judge's disposition is in [judge.md](judge.md). These are separate agent reviews performed within this assignment, not an audit-firm certification or an on-chain launch approval.

An intermediate concurrent build exposed inconsistent embedded hook creation bytes between a miner helper and a test fixture. Disabling dynamic test linking and rebuilding resolved it; the final CREATE2 suites all pass. A multi-staker integration assertion was also corrected to allow one base unit of retained accumulator rounding residue, consistent with the documented whole-unit payout semantics and conservation checks.

## Code size and static review

| Contract | Creation bytes | Runtime bytes |
| --- | ---: | ---: |
| SIMDTESTHook | 12,583 (+64 constructor bytes = **12,647**) | 6,976 |
| SIMDTESTVault | 4,377 (+96 constructor bytes) | 3,984 |
| SIMDTEST | 2,593 | 1,723 |

The hook is below EIP-3860's 49,152-byte init-code limit, and all launch runtimes are below EIP-170's 24,576-byte limit. No external library linking is required.

Foundry's build linter reports reentrancy/event-order heuristics at the guarded sweep/claim paths, integer casts, a default-zero loop variable, and the deliberately unused byte-array return from `PoolManager.unlock`. Manual review confirmed:

- User stake/unstake/claim and sweep use OpenZeppelin guards. Sweep clears fee counters before external calls. Its only callback requires both the immutable manager and active sweep. Notification is hook-only and cannot move principal. Claim clears rewards before IMD transfer.
- Fee casts operate on fees calculated from executed PoolManager int128 deltas. Even gross-up at the maximum 31% rate produces fees below int128's maximum; request-sized values are not directly cast into a fee delta. `int256.min` absolute-value conversion is explicitly handled and tested.
- The bounded rounding-loop variable begins at Solidity's defined zero value. The unlock callback returns empty bytes; the caller only needs successful execution, so ignoring that return is intentional.

No Slither, Mythril, formal verification, or external firm's audit was run. Those tools were not installed. Foundry's compiler/linter, unit tests, fuzz properties, invariant tests, size checks, and runtime scans are the automated evidence provided here.

## Outstanding release responsibilities

Five public RPC endpoints returned HTTP 403 during read-only probes: PublicNode, LlamaRPC, dRPC, BlockPI, and Cloudflare. The delivered fork suite must still run against a recent mainnet block and working archive RPC. It must establish actual IMD transfer/settlement behavior and the deployed PoolManager integration; local ERC-20 mocks cannot establish those facts.

The launch operator must also run the platform's manifest admission validator and full factory rehearsal, resolve the prescribed manager and freshly deployed token, mine the exact CREATE2 address, atomically deploy/initialize, fund liquidity, distribute the swarm allocation externally, and record the deployed vault. The factory's production liquidity/distributor implementation was not provided in this assignment and is not replaced by the test router.

The README records the immutable economic policies that matter to participants: deployment-block fee clock, gross-IMD fee basis, separately rounded components, immediate reward eligibility, queued no-staker rewards awarded to the next first staker, and irrecoverable unsolicited donations. No unprovided private address, key, or contract ID has been invented.
