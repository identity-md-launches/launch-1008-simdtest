// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SIMDTESTVault, ISIMDTESTFeeSource} from "./SIMDTESTVault.sol";

/// @notice Immutable IMD fee hook. All swaps retain the pool's static LP fee.
contract SIMDTESTHook is IUnlockCallback, ReentrancyGuard {
    using TransientStateLibrary for IPoolManager;

    address public constant PAIRED_CURRENCY = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address public constant HACKATHON_VAULT = 0x3dD5F73dD1A4E62630fAd3909673F130aD429985;
    uint256 public constant BPS = 10_000;
    uint256 public constant STAKING_FEE_BPS = 100;
    uint256 public constant INITIAL_ANTI_SNIPE_BPS = 3_000;
    uint256 public constant ANTI_SNIPE_BLOCKS = 10;
    uint24 public constant LP_FEE = 12_500;
    int24 public constant TICK_SPACING = 60;

    IPoolManager public immutable poolManager;
    IERC20 public immutable token;
    SIMDTESTVault public immutable vault;
    uint256 public immutable openingBlock;
    PoolId public immutable poolId;
    bool public immutable pairIsCurrency0;
    uint256 public antiSnipeFees;
    uint256 public stakingFees;
    uint256 public totalStakingFees;
    bool private sweepActive;

    error OnlyPoolManager();
    error OnlySelf();
    error InvalidPool();
    error InvalidAddress();
    error UnrepresentableFee();
    error UnexpectedUnlock();
    error QuoteResult(uint256 amount);

    event FeesAccrued(uint256 antiSnipe, uint256 staking);
    event Swept(uint256 antiSnipe, uint256 staking);

    constructor(IPoolManager manager_, IERC20 token_) {
        if (address(manager_) == address(0) || address(token_).code.length == 0 || address(token_) == PAIRED_CURRENCY) {
            revert InvalidAddress();
        }
        poolManager = manager_;
        token = token_;
        openingBlock = block.number;
        bool pair0 = PAIRED_CURRENCY < address(token_);
        pairIsCurrency0 = pair0;
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(pair0 ? PAIRED_CURRENCY : address(token_)),
            currency1: Currency.wrap(pair0 ? address(token_) : PAIRED_CURRENCY),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(this))
        });
        poolId = key.toId();
        vault = new SIMDTESTVault(token_, IERC20(PAIRED_CURRENCY), ISIMDTESTFeeSource(address(this)));
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    function antiSnipeBps() public view returns (uint256) {
        uint256 elapsed = block.number - openingBlock;
        return
            elapsed >= ANTI_SNIPE_BLOCKS
                ? 0
                : INITIAL_ANTI_SNIPE_BPS * (ANTI_SNIPE_BLOCKS - elapsed) / ANTI_SNIPE_BLOCKS;
    }

    function beforeInitialize(address, PoolKey calldata key, uint160) external view onlyPoolManager returns (bytes4) {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert InvalidPool();
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (!_pairSpecified(params)) return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);

        uint256 rate = antiSnipeBps();
        uint256 gross;
        SwapParams memory quoteParams = params;
        if (params.amountSpecified < 0) {
            gross = _abs(params.amountSpecified);
            (uint256 anti, uint256 staking) = _fees(gross, rate);
            uint256 net = gross - anti - staking;
            quoteParams.amountSpecified = -int256(net);
            uint256 filled = _quote(key, quoteParams);
            // Only the executed amount is taxable when the price limit/liquidity causes a partial fill.
            if (filled < net) gross = _grossUp(filled, rate);
        } else {
            gross = _grossUp(uint256(params.amountSpecified), rate);
            if (gross > uint256(type(int256).max)) revert UnrepresentableFee();
            quoteParams.amountSpecified = int256(gross);
            gross = _quote(key, quoteParams);
        }
        (uint256 antiFee, uint256 stakingFee) = _fees(gross, rate);
        int128 fee = _accrue(antiFee, stakingFee);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee, 0), 0);
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        if (_pairSpecified(params)) return (IHooks.afterSwap.selector, 0);
        int128 pairDelta = pairIsCurrency0 ? delta.amount0() : delta.amount1();
        uint256 rate = antiSnipeBps();
        uint256 gross = _abs(int256(pairDelta));
        if (pairDelta < 0) gross = _grossUp(gross, rate);
        (uint256 anti, uint256 staking) = _fees(gross, rate);
        return (IHooks.afterSwap.selector, _accrue(anti, staking));
    }

    /// @dev A self-only reverting simulation determines the actually executable paired amount.
    /// Uniswap skips this hook on its own swap. Every simulated storage write/event is rolled back.
    /// This is necessary because afterSwap can only adjust the *unspecified* currency.
    function quotePair(PoolKey calldata key, SwapParams calldata params) external {
        if (msg.sender != address(this)) revert OnlySelf();
        BalanceDelta delta = poolManager.swap(key, params, "");
        revert QuoteResult(_abs(int256(pairIsCurrency0 ? delta.amount0() : delta.amount1())));
    }

    /// @notice Redeem both IMD claim balances to their fixed destinations. No caller receives fees.
    function sweep() external nonReentrant {
        if (antiSnipeFees + stakingFees == 0) return;
        sweepActive = true;
        if (poolManager.isUnlocked()) _redeem();
        else poolManager.unlock("");
        sweepActive = false;
    }

    function unlockCallback(bytes calldata) external onlyPoolManager returns (bytes memory) {
        if (!sweepActive) revert UnexpectedUnlock();
        _redeem();
        return "";
    }

    function _redeem() private {
        uint256 anti = antiSnipeFees;
        uint256 staking = stakingFees;
        antiSnipeFees = 0;
        stakingFees = 0;
        Currency pair = Currency.wrap(PAIRED_CURRENCY);
        poolManager.burn(address(this), pair.toId(), anti + staking);
        if (anti != 0) poolManager.take(pair, HACKATHON_VAULT, anti);
        if (staking != 0) {
            poolManager.take(pair, address(vault), staking);
            vault.notifyReward(staking);
        }
        emit Swept(anti, staking);
    }

    function _pairSpecified(SwapParams calldata params) private view returns (bool) {
        return (params.amountSpecified < 0) == (params.zeroForOne == pairIsCurrency0);
    }

    function _quote(PoolKey calldata key, SwapParams memory params) private returns (uint256 amount) {
        (bool success, bytes memory result) = address(this).call(abi.encodeCall(this.quotePair, (key, params)));
        if (!success && result.length == 36 && bytes4(result) == QuoteResult.selector) {
            assembly ("memory-safe") { amount := mload(add(result, 36)) }
        } else {
            // Preserve the real PoolManager's rejection of invalid prices or unrepresentable pool deltas.
            assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
        }
    }

    function _fees(uint256 gross, uint256 antiBps) private pure returns (uint256 anti, uint256 staking) {
        anti = Math.mulDiv(gross, antiBps, BPS);
        staking = gross / (BPS / STAKING_FEE_BPS);
    }

    function _grossUp(uint256 net, uint256 antiBps) private pure returns (uint256 gross) {
        gross = Math.mulDiv(net, BPS, BPS - antiBps - STAKING_FEE_BPS, Math.Rounding.Ceil);
        uint256 ceiling = gross;
        // Independent fee floors make net(gross) locally non-monotonic. Search the entire
        // rounding window and choose the smallest exact inverse; never overcharge a partial fill.
        // The two floor errors sum to <2 and 1-rate >=0.69, so ceil-3 suffices.
        for (uint256 i; i <= 3 && i <= ceiling; ++i) {
            uint256 candidate = ceiling - i;
            (uint256 anti, uint256 staking) = _fees(candidate, antiBps);
            if (candidate - anti - staking == net) gross = candidate;
        }
    }

    function _accrue(uint256 anti, uint256 staking) private returns (int128) {
        uint256 fee = anti + staking;
        if (fee != 0) {
            antiSnipeFees += anti;
            stakingFees += staking;
            totalStakingFees += staking;
            poolManager.mint(address(this), Currency.wrap(PAIRED_CURRENCY).toId(), fee);
            emit FeesAccrued(anti, staking);
        }
        // Pool deltas and actually funded IMD amounts fit int128, independent of the int256 request.
        return int128(int256(fee));
    }

    function _abs(int256 value) private pure returns (uint256) {
        unchecked {
            return value < 0 ? uint256(-(value + 1)) + 1 : uint256(value);
        }
    }
}
