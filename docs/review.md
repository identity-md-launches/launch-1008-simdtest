# Implementation and adversarial review record

Date: 2026-10-08. Compiler: Solidity 0.8.26. Foundry: 1.8.3.

The local deliverable implements the token, fee hook, staking vault, CREATE2 mining helper, vendored dependencies, test suites, deployment manifest, and operator documentation. No deployment, broadcast, funded wallet operation, owner configuration, or swarm allocation was performed.

## Revision after independent review (2026-10-08)

An independent reviewer on another machine reopened the accepted work with one high finding and three advisory ones. Each was reproduced locally before any change; the answers are recorded in `.imd-responses.json`.

1. **Zero-duration staking recaptured the 1% staking fee (high, fixed).** The reviewer's proof flash-borrowed 500,000 pool-held SIMDTEST inside its own unlock, staked, bought 100,000 IMD, unstaked and repaid, then claimed 980.39 of the 1,000 IMD fee it had just paid. On the starting tree the proof failed exactly as reported. Repair: `SIMDTESTVault` now holds each stake as *pending* for the block it is made in and makes it eligible from the next block. `SIMDTESTHook._accrue` records `lastAccrualBlock` and `stakingFeesAtEndOf[block]` (the cumulative staking fee at the end of every block that accrued one), which lets the vault settle a stake block's fees to the stake that existed before it and share everything afterwards exactly, without any checkpoint between. Same-block stakes mature together; a pending stake can be cancelled by `unstake` in the same block, so principal remains withdrawable at any time. The vault's `totalStaked()` and `balanceOf` report pending plus eligible principal; `activeStake`, `pendingStake`, `activeOf`, `pendingOf` split them. The proof now passes (refund 0). New regressions: `test/JitStaking.t.sol` (in-unlock flash stake with borrowed pool tokens, same-block sandwich, exact block boundaries with and without intermediate checkpoints, pending cancellation) and `test/VaultAdversarial.t.sol` (`test_StakeEarnsOnlyFromTheNextBlock`, `test_LazyFlushDoesNotRobPassiveStakers`; the sequence fuzz now also rolls blocks). Existing tests that staked and swapped in one block now advance a block first.
2. **One-sided liquidity exits pay no hook fee (low, disputed).** Reproduced in the sense that liquidity changes are not intercepted, as the README already stated. Liquidity provision is not a swap; the brief's fees are swap fees. Charging or refusing non-factory liquidity would need two more permission bits, a `$factory` allowlist the brief does not provide, and a different mined address. The boundary is now spelled out in the README.
3. **Zero-staker queue goes to the first staker (info, disputed as policy).** Unchanged policy, still disclosed. The repair for item 1 means the queue goes to the first stakes that *mature*, so it can no longer be taken with tokens borrowed inside an unlock.
4. **Atomic redemption strands the hackathon payout on a short IMD delivery (info, fixed).** `_redeem` now notifies the vault with the IMD balance the vault actually received (capped at the requested amount) instead of the requested amount. With a plain token nothing changes; with a shaving token the sweep completes and the hackathon stream is paid, and the shortfall lands on the stakers' last claims. `test_ShortDeliveryByIMDStillSweepsBothStreams` covers it.

## Final checks

| Check | Result |
| --- | --- |
| `forge build` | Passed with the pinned compiler |
| `forge test` | **53 passed, 0 failed, 1 skipped**, across eleven suites (plus the reviewer's proof under `test/scratch/`, passing) |
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
| SIMDTESTHook | 14,587 (+64 constructor bytes = **14,651**) | 7,448 |
| SIMDTESTVault | 5,897 (+96 constructor bytes) | 5,483 |
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

The README records the immutable economic policies that matter to participants: deployment-block fee clock, gross-IMD fee basis, separately rounded components, reward eligibility starting the block after staking (no lock, pending stakes cancellable), queued no-staker rewards awarded to the first stakes that mature, and irrecoverable unsolicited donations. No unprovided private address, key, or contract ID has been invented.
