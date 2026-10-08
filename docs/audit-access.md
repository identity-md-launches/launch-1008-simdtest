# Specialist audit 3: access, initialization, and immutability

Reviewed `SIMDTESTHook`, `SIMDTESTVault`, `SIMDTEST`, their inherited OpenZeppelin code, and the relevant vendored Uniswap v4 `PoolManager`, `Hooks`, and ERC-6909 paths. This is an independent contributor-agent review within this assignment, not a commissioned third-party audit.

No actionable access-control or code-immutability finding was identified in the reviewed implementation.

## Verified controls

- Every enabled hook callback (`beforeInitialize`, `beforeSwap`, `afterSwap`) checks the immutable PoolManager address. Unauthorized callers cannot accrue fees or invoke initialization logic directly.
- `beforeInitialize` binds the complete `PoolKey` to the immutable pool ID, covering the launch token, IMD, static fee 12500, tick spacing 60, and this hook. A different pool cannot initialize with this hook. PoolManager rejects uninitialized pools before reaching swap callbacks, so the initialization restriction also binds subsequent callback use.
- The required initialization permission prevents initialization at the counterfactual hook address before code exists. Correctly initialized launch pools work.
- `quotePair` requires the hook itself as caller. Its only authorized call path deliberately reverts the simulated swap and cannot expose a public fee-free route. Uniswap skips callbacks for this self-initiated simulated swap.
- `unlockCallback` requires both PoolManager caller identity and an active sweep. `sweep` is permissionless, guarded against reentry, and has no caller-selected destination. Fee counters are cleared before external redemption calls; a failure reverts the complete operation.
- Vault `notifyReward` accepts only its immutable hook. Stake withdrawals and reward claims use the caller's own accounting and pay only that caller. The vault is deployed directly by the hook and its token, reward token, and fee-source relationships are immutable.
- The token ABI exposes standard ERC-20 operations and has no mint, pause, tax, or administrative function. The hook and vault expose no owner, role grant, setter, proxy, or upgrade function.
- PUSH-aware opcode scans of all three deployed runtimes found no SELFDESTRUCT, DELEGATECALL, or CALLCODE. Hook address permission bits match `getHookPermissions` and the intended mask.

## Reproductions and checks

`test/AccessAdversarial.t.sol` includes four independent tests covering unauthorized callbacks, quote and notify access, inactive unlock rejection, initialization key mutations, pre-deployment initialization rejection, immutable vault relationships, permission address bits, code-size limits, and forbidden opcodes. They passed using Solidity 0.8.26 and the project's real vendored PoolManager.

Command: `forge test --match-contract AccessAdversarialTest -vv`.

Measured initial reviewed sizes: hook creation code 12,516 bytes, plus 64 bytes constructor arguments; hook runtime 6,909 bytes; vault runtime 3,984 bytes; token runtime 1,723 bytes. The tests enforce applicable creation/runtime limits against each current build, so these measurements are informational.

## Deployment assumption and limits

The launch factory must deploy and initialize the pool atomically. Once hook code exists, `beforeInitialize` allows any caller to initialize the correct pool at a valid price; this is safe with atomic factory deployment but would permit initialization front-running if deployment and initialization were split across transactions. No factory address, administrative setter, or guessed address has been introduced.

The PoolManager constructor argument must resolve to the specified mainnet deployment. Trust in that fixed manager and in the specified IMD token's production behavior remains part of deployment validation. This specialist review does not claim a live mainnet execution, formal verification, or complete fee-math/reward-accounting coverage; the other specialist reviews and integration suites address those areas.
