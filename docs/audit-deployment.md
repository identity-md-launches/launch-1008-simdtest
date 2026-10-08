# Specialist review 4: deployment, token and reproducibility

Scope: launch manifest, immutable constructor wiring, CREATE2 permission mining,
token supply and transfer behavior, compiler inputs, deployment lifecycle, and
honesty of integration-test boundaries. This is an independent agent review of
the delivered code, not an external audit firm's certification.

## Findings and disposition

No unresolved contract defect was identified in this scope.

- The earlier rejected discriminator is corrected: `launch.json.kind` is
  `univ4_hook`. The named contract is `SIMDTESTHook` itself; its two constructor
  arguments match `$poolManager` and `$token`. Task-field assertions passed for
  the IMD pair, static fee 12500, spacing 60, provenance price, and token metadata.
  A complete manifest-schema validator was not provided, so this review does not
  claim formal admission-schema validation.
- The constructor receives PoolManager and a deployed token, binds the complete
  pool key, creates its vault directly, and permanently fixes the vault's token,
  reward currency and hook relationships. No wrapper, owner, setter, proxy,
  external library link, or after-deployment configuration is required.
- `beforeInitialize` is enabled and authenticated. The access review's executable
  lifecycle test rejects initialization at the predicted address before the hook
  exists, then deploys it with CREATE2 and accepts the actual launch key. Factory
  deployment and initialization must remain atomic; the anti-snipe clock begins
  at construction rather than later initialization.
- Permission flags are 0x20cc. The salt helper includes the actual factory,
  manager, token, and complete hook init code. No deployment address or salt can
  be finalized until the factory's concrete addresses are available. The factory
  must mine against the exact delivered build; constructor-argument changes alter
  the predicted hook address.
- Inspected hook creation code is 12,583 bytes, or 12,647 bytes with its two
  constructor arguments, below EIP-3860's 49,152-byte limit. Hook, vault and token
  runtime lengths are respectively 6,976, 3,984 and 1,723 bytes, below EIP-170's
  24,576-byte limit. Regression assertions recheck these limits on future builds.
- An intermediate build had different embedded hook init code in the salt helper
  and test fixtures. After disabling Foundry dynamic test linking and rebuilding,
  artifact inspection confirmed identical complete hook creation bytes embedded
  in `MineHook`, `AccessAdversarialTest`, `HookTest`, `MainnetForkTest`, and
  `SwapRoundingTest`. This was a local build consistency issue, not a mainnet
  contract exploit.
- Token code mints exactly 1e27 units once to its deployer. OpenZeppelin ERC20
  supplies standard 18-decimal transfers and allowances; the launch token adds no
  mint, tax, swarm transfer or privileged path. The factory retains responsibility
  for the external distribution and liquidity allocation.
- Compiler settings pin Solidity 0.8.26, Cancun, optimization and no metadata
  bytecode hash. All compiler source paths inspected for token, hook, vault and
  PoolManager exist locally. Dependency commits and licenses are vendored as
  ordinary files, and the build needs no package download, FFI or file permission.
  The compiler itself is supplied by the execution profile, as requested.

## Regression coverage

`test/TokenDeployment.t.sol` adds full-supply and metadata assertions, transfer
conservation fuzzing, allowance rejection/decrement, and attempts to mint or gain
administrative power from both the deployer and an unrelated account.

`test/AccessAdversarial.t.sol` checks direct CREATE2 deployment and the EIP-3860
creation size, EIP-170 runtime size, matching permission bits, initialization
lifecycle, and instruction-aware rejection of DELEGATECALL, CALLCODE and
SELFDESTRUCT in token, hook and vault runtime code.

The local swap fixture executes the vendored real Uniswap v4 PoolManager. Only
the IMD ERC20 is replaced with a standard mock for offline tests. The mainnet fork
fixture uses the specified deployed manager and IMD contracts, provisions test
balances with Foundry's `deal`, and skips explicitly when no mainnet fork is
active. It does not read environment variables or silently report an unexecuted
fork as passing. The test router is a settlement harness, not a production router.

## Signoff boundary

Static deployment and token review passes within the scope above. Final judge
signoff and exact test/build results are recorded in `docs/review.md`. Mainnet
execution remains unverified in this environment because accessible RPC requests
failed; the launch operator must run the included fork scenarios before release.
Production IMD transfer semantics, current deployed PoolManager bytecode and the
factory's full liquidity/distributor flow are therefore not certified by this
offline review. No deployment or broadcast was performed.
