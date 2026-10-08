Vault specialist review — 2026-10-08

Result: no blocking defect identified in the reviewed vault. This is an independent adversarial agent review within this assignment, not an external audit certification. Review covered `src/SIMDTESTVault.sol`, the `ISIMDTESTFeeSource` interface, and the hook's accrual, redemption, and notification paths.

The vault checkpoints each account before stake changes and reads the hook's cumulative staking fees, including fees not yet swept. A late entrant therefore does not receive rewards earned while earlier holders were staked. Fully exiting preserves the exiting account's earned rewards. Claims first fund outstanding rewards through the hook sweep, then settle the caller's accounting and transfer only their rewards. Stake ownership is non-transferable, and there is no account argument or administrative path that permits another party to withdraw principal.

The reward-per-token accumulator retains a global remainder and each account retains a fractional remainder. This preserves fractional entitlement across repeated checkpoints and claims. The global remainder represents unallocated scaled reward units; carrying it when stake supply changes does not create rewards. At the launch token's maximum supply of 1e27 base units and SCALE of 1e36, this unallocated residue is less than 1e-9 reward-token base units per checkpoint. Claims and user-facing earned amounts remain whole token base units.

The first stake after a period with zero total stake receives all queued rewards. This is explicit policy in the implementation, not an undisclosed allocation mechanism. Anyone can race to become that first staker, and a one-unit stake qualifies. There is no time lock or minimum-duration reward eligibility; a holder staking immediately before fee-generating swaps participates pro rata during those swaps. These economic consequences should remain visible in deployment documentation.

Notification is restricted to the immutable hook. It rejects notifications that exceed cumulative accrued fees or the vault's funded, unclaimed balance. Notification can run during a claim's hook sweep, but it only updates global accounting. Stake, unstake, and claim share a reentrancy guard, and claim clears the caller's whole-unit rewards before transferring them. Principal withdrawals do not attempt reward transfers and do not require a sweep.

The delivered regression suite is `test/VaultAdversarial.t.sol`. The review ran `forge test --match-contract VaultAdversarialTest -vv` with Solidity 0.8.26: six tests passed, with no failures or skips, in approximately six seconds. Coverage includes:

- A sequence fuzz test with 512 cases and 150 actions per case, interleaving fee accrual, sweeping, staking, partial and full unstaking, and claims across four accounts. Every step asserts that total claims plus current earned rewards do not exceed cumulative fees; principal balances conserve exactly; aggregate stakes equal held principal; and `pending()` equals cumulative fees minus claims. All participants can fully exit and claim at the end.
- An unswept-reward timing example with holders joining and leaving before the eventual sweep, checking exact expected payouts.
- Queued rewards before initial staking and between staking epochs.
- Repeated one-unit reward claims with stakes in a 1:2 ratio, checking that fractional rewards survive and pay exactly 1 and 2 units after three distributions.
- Rejection of another account's principal withdrawal.
- Rejection of unauthorized notification and notification without funding.

The independent tests use an isolated fee-source harness and conventional ERC-20 tokens. They validate vault accounting without depending on hook implementation details; real PoolManager integration and fork execution are reviewed and tested separately. The fixed SIMDTEST staking token has conventional ERC-20 semantics. Reward transfers depend on IMD continuing to behave as an ERC-20 without transfer deductions or rebasing. Runtime behavior of the mainnet IMD token is outside this isolated vault test's evidence. Global pending rewards include queued and fractional unclaimed obligations, and are not a promise that every pending base unit is immediately claimable by a particular account.

Specialist signoff: pass for the reviewed vault scope, subject to the stated queue policy and integration assumptions. No production-code changes were requested by this review.
