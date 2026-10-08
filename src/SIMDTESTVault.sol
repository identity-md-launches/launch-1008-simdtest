// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface ISIMDTESTFeeSource {
    function totalStakingFees() external view returns (uint256);
    function lastAccrualBlock() external view returns (uint256);
    function stakingFeesAtEndOf(uint256 blockNumber) external view returns (uint256);
    function sweep() external;
}

/// @notice Non-transferable stakes. Only each staker can withdraw their principal or rewards.
/// @dev Rewards accrue from the hook's cumulative IMD claims, independently of sweep timing.
/// A stake made in block B earns only fees accrued in blocks after B: it waits in a pending
/// bucket until the first checkpoint in a later block, so a stake that exists for one block or
/// one PoolManager unlock (flash or JIT staking around a swap) earns nothing from that swap.
contract SIMDTESTVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Accrual {
        uint256 value;
        uint256 queue;
        uint256 remainder;
        uint256 active;
        uint256 activation;
        bool flushed;
    }

    uint256 public constant SCALE = 1e36;
    IERC20 public immutable stakingToken;
    IERC20 public immutable rewardToken;
    ISIMDTESTFeeSource public immutable hook;
    /// @notice Stake eligible for rewards.
    uint256 public activeStake;
    /// @notice Stake made in `pendingBlock`; eligible from the next block on.
    uint256 public pendingStake;
    uint256 public pendingBlock;
    uint256 public pendingFees;
    uint256 public rewardPerTokenStored;
    uint256 public accountedFees;
    uint256 public queuedRewards;
    uint256 public scaledRemainder;
    uint256 public totalNotified;
    uint256 public totalClaimed;
    mapping(address => uint256) public activeOf;
    mapping(address => uint256) public pendingOf;
    mapping(address => uint256) public pendingBlockOf;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;
    mapping(address => uint256) public userRemainder;
    /// @notice rewardPerToken at which the stakes made in a block began earning.
    mapping(uint256 => uint256) public activationRewardPerToken;

    error OnlyHook();
    error InvalidAddress();
    error ZeroAmount();
    error InsufficientStake();
    error UnfundedReward();

    event Staked(address indexed staker, uint256 amount);
    event Unstaked(address indexed staker, uint256 amount);
    event RewardPaid(address indexed staker, uint256 amount);
    event RewardNotified(uint256 amount);

    constructor(IERC20 token_, IERC20 reward_, ISIMDTESTFeeSource hook_) {
        if (
            address(token_) == address(0) || address(reward_) == address(0) || address(hook_) == address(0)
                || token_ == reward_
        ) revert InvalidAddress();
        stakingToken = token_;
        rewardToken = reward_;
        hook = hook_;
    }

    /// @notice All SIMDTEST principal in custody, eligible and still pending.
    function totalStaked() external view returns (uint256) {
        return activeStake + pendingStake;
    }

    /// @notice The account's whole principal, eligible and still pending.
    function balanceOf(address account) external view returns (uint256) {
        return activeOf[account] + pendingOf[account];
    }

    /// @notice Total unclaimed accrued IMD, including unswept claims and unallocated rewards.
    function pending() external view returns (uint256) {
        return hook.totalStakingFees() - totalClaimed;
    }

    function rewardPerToken() public view returns (uint256) {
        return _preview().value;
    }

    function earned(address account) public view returns (uint256) {
        Accrual memory a = _preview();
        (uint256 add,) = _owed(account, a.value, _activation(account, a));
        return rewards[account] + add;
    }

    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _update(msg.sender);
        // _update flushed every older bucket, so the global bucket is empty or belongs to this block.
        pendingBlock = block.number;
        pendingStake += amount;
        pendingFees = hook.totalStakingFees();
        pendingOf[msg.sender] += amount;
        pendingBlockOf[msg.sender] = block.number;
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _update(msg.sender);
        // Any pending stake left after _update was made in this block: cancel it first.
        uint256 cancelled = Math.min(pendingOf[msg.sender], amount);
        if (cancelled != 0) {
            pendingOf[msg.sender] -= cancelled;
            pendingStake -= cancelled;
        }
        uint256 fromActive = amount - cancelled;
        if (fromActive > activeOf[msg.sender]) revert InsufficientStake();
        activeOf[msg.sender] -= fromActive;
        activeStake -= fromActive;
        stakingToken.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    function claim() external nonReentrant returns (uint256 amount) {
        hook.sweep();
        _update(msg.sender);
        amount = rewards[msg.sender];
        rewards[msg.sender] = 0;
        totalClaimed += amount;
        if (amount != 0) rewardToken.safeTransfer(msg.sender, amount);
        emit RewardPaid(msg.sender, amount);
    }

    /// @dev Called only after the immutable hook has transferred rewards. No stake or principal power.
    function notifyReward(uint256 amount) external {
        if (msg.sender != address(hook)) revert OnlyHook();
        uint256 notified = totalNotified + amount;
        if (notified > hook.totalStakingFees() || rewardToken.balanceOf(address(this)) < notified - totalClaimed) {
            revert UnfundedReward();
        }
        totalNotified = notified;
        _updateGlobal();
        emit RewardNotified(amount);
    }

    /// @dev Fees accrued up to the end of the pending bucket's block go to the stake active before it;
    /// the bucket then joins and shares everything accrued afterwards.
    function _preview() private view returns (Accrual memory a) {
        a.value = rewardPerTokenStored;
        a.queue = queuedRewards;
        a.remainder = scaledRemainder;
        a.active = activeStake;
        uint256 total = hook.totalStakingFees();
        uint256 boundary = total;
        bool flush = pendingStake != 0 && block.number > pendingBlock;
        if (flush) boundary = _feesAtEndOf(pendingBlock, total);
        _distribute(a, boundary - accountedFees);
        if (flush) {
            a.activation = a.value;
            a.active += pendingStake;
            a.flushed = true;
            _distribute(a, total - boundary);
        }
    }

    /// @dev Cumulative staking fees at the end of `blockNumber`, a block in which a stake was made.
    /// The hook records the boundary of every block that accrued a fee; a block that accrued none
    /// ended with the total the vault snapshotted when the bucket was filled.
    function _feesAtEndOf(uint256 blockNumber, uint256 total) private view returns (uint256) {
        if (hook.lastAccrualBlock() <= blockNumber) return total;
        return Math.max(hook.stakingFeesAtEndOf(blockNumber), pendingFees);
    }

    function _distribute(Accrual memory a, uint256 fees) private pure {
        a.queue += fees;
        if (a.active != 0) {
            a.value += Math.mulDiv(a.queue, SCALE, a.active);
            uint256 carry = mulmod(a.queue, SCALE, a.active) + a.remainder;
            a.value += carry / a.active;
            a.remainder = carry % a.active;
            a.queue = 0;
        }
    }

    function _activation(address account, Accrual memory a) private view returns (uint256) {
        uint256 blockNumber = pendingBlockOf[account];
        if (a.flushed && blockNumber == pendingBlock) return a.activation;
        return activationRewardPerToken[blockNumber];
    }

    /// @dev Rewards owed to `account` at `value`, counting pending stake from an earlier block as
    /// eligible since `activation`; returns the whole units and the retained scaled fraction.
    function _owed(address account, uint256 value, uint256 activation)
        private
        view
        returns (uint256 add, uint256 fraction)
    {
        uint256 increment = value - userRewardPerTokenPaid[account];
        uint256 active = activeOf[account];
        add = Math.mulDiv(active, increment, SCALE);
        fraction = mulmod(active, increment, SCALE) + userRemainder[account];
        uint256 matured = pendingOf[account];
        if (matured != 0 && pendingBlockOf[account] < block.number) {
            uint256 since = value - activation;
            add += Math.mulDiv(matured, since, SCALE);
            fraction += mulmod(matured, since, SCALE);
        }
        add += fraction / SCALE;
        fraction %= SCALE;
    }

    function _updateGlobal() private {
        Accrual memory a = _preview();
        rewardPerTokenStored = a.value;
        queuedRewards = a.queue;
        scaledRemainder = a.remainder;
        accountedFees = hook.totalStakingFees();
        if (a.flushed) {
            activationRewardPerToken[pendingBlock] = a.activation;
            activeStake = a.active;
            pendingStake = 0;
        }
    }

    function _update(address account) private {
        _updateGlobal();
        uint256 value = rewardPerTokenStored;
        (uint256 add, uint256 fraction) = _owed(account, value, activationRewardPerToken[pendingBlockOf[account]]);
        rewards[account] += add;
        userRemainder[account] = fraction;
        userRewardPerTokenPaid[account] = value;
        uint256 matured = pendingOf[account];
        if (matured != 0 && pendingBlockOf[account] < block.number) {
            activeOf[account] += matured;
            pendingOf[account] = 0;
        }
    }
}
