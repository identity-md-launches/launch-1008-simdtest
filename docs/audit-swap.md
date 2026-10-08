# Specialist review 1: swap accounting

Scope: `SIMDTESTHook`, the vendored Uniswap v4 `PoolManager`, `Hooks`, `Pool`, and their delta and settlement paths. Reviewed the actual implementation rather than relying on the task's reference defaults. This is an adversarial contributor review, not a third-party audit certification.

## Finding repaired

**SWAP-01 — Low severity: independently rounded fees could overcharge a partial fill by two wei.** At deployment block +9, a 99-wei exact-input IMD buy has two wei of anti-snipe fees, no staking fee, and 97 wei available to the pool. A price limit allowing only 96 wei of pool input caused the original gross-up routine to choose gross 100 rather than 98. The hook consequently collected three wei of anti-snipe fees and one wei of staking fees, although total trader spending was 99 wei. A real-PoolManager regression reproduced the defect before the repair: `anti fee inconsistent with actual gross: 3 != 2`.

The repaired inverse scans the ceiling estimate and its three preceding integers, choosing the smallest exact inverse. This bound follows from the sum of the two floor errors being below two and the retained fraction being at least 0.69: the ceiling and any exact inverse differ by less than four, hence at most three integer units. The repaired concrete regression spends 98 wei, collects two wei, and gives the pool 96 wei. It now passes.

## Reviewed properties

- The four combinations of buy/sell and exact input/output map the fee exclusively to IMD. The specified side uses `beforeSwap` and the unspecified side uses `afterSwap`. Positive hook deltas charge the trader and offset the hook's claim mint debt.
- Buy fees use gross IMD paid; sell fees use gross IMD output. Separate integer floors calculate anti-snipe and staking fees. Exact-output buys gross up the actual pool input before calculating fees, preserving that definition.
- The self-only quote deliberately reverts all simulated pool state, transient deltas, protocol fees and logs. The real manager skips callbacks only when its caller is the hook itself. The outer swap then executes against unchanged pool state. Only the private caller accepts the fixed-length `QuoteResult` response.
- Partial fills charge the executed paired-currency amount. Zero execution produces no fee. Exact-input IMD spending stays within the requested budget; exact-output IMD receipts never exceed the requested output.
- Claim minting collects fees without requiring the PoolManager to already hold the incoming IMD before router settlement. Accrual leaves no unbalanced hook delta. Sweep burns the matching claims and takes IMD; it never changes the LP fee.
- The hook returns zero LP-fee override and initializes only its immutable static-fee pool. Quote execution does not provide an externally accessible fee bypass.
- The `int256` minimum absolute value is computed without signed overflow. Exact-output IMD requests whose gross-up exceeds `int256.max` reject with `UnrepresentableFee`. The real PoolManager retains its native price, liquidity and signed `int128` balance-delta domain; amounts beyond that domain are not executable v4 swaps.

## Evidence

`forge test --match-contract SwapRoundingTest -vv` passes the concrete regression and three fuzz properties, 1,000 runs each. These execute the real local PoolManager, cover all four swap modes, partial price-limit fills, tiny amounts, every decay block and the post-decay rate. They assert the fee formula against actual trader deltas, settled manager accounting, and equality of accrued fees to claim balances. An additional exhaustive arithmetic check covered requests 1–999, every rate, and fill caps up to 20 units below the requested pool amount for both specified-side modes.

No unresolved actionable swap-accounting defect was identified within the launch and Uniswap's executable amount domain. Mainnet state/token behavior and deployment checks are recorded by the project integration review separately.
