// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface ISIMDTESTFeeSource {
    function totalStakingFees() external view returns (uint256);
    function sweep() external;
}

/// @notice Non-transferable stakes. Only each staker can withdraw their principal or rewards.
/// @dev Rewards accrue from the hook's cumulative IMD claims, independently of sweep timing.
contract SIMDTESTVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant SCALE = 1e36;
    IERC20 public immutable stakingToken;
    IERC20 public immutable rewardToken;
    ISIMDTESTFeeSource public immutable hook;
    uint256 public totalStaked;
    uint256 public rewardPerTokenStored;
    uint256 public accountedFees;
    uint256 public queuedRewards;
    uint256 public scaledRemainder;
    uint256 public totalNotified;
    uint256 public totalClaimed;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;
    mapping(address => uint256) public userRemainder;

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

    /// @notice Total unclaimed accrued IMD, including unswept claims and unallocated rewards.
    function pending() external view returns (uint256) {
        return hook.totalStakingFees() - totalClaimed;
    }

    function rewardPerToken() public view returns (uint256 value) {
        (value,,) = _preview();
    }

    function earned(address account) public view returns (uint256) {
        uint256 increment = rewardPerToken() - userRewardPerTokenPaid[account];
        uint256 fraction = mulmod(balanceOf[account], increment, SCALE) + userRemainder[account];
        return rewards[account] + Math.mulDiv(balanceOf[account], increment, SCALE) + fraction / SCALE;
    }

    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _update(msg.sender);
        totalStaked += amount;
        balanceOf[msg.sender] += amount;
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        // Rewards earned with nobody staked are explicitly allocated to the first subsequent stake.
        _update(msg.sender);
        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _update(msg.sender);
        if (amount > balanceOf[msg.sender]) revert InsufficientStake();
        balanceOf[msg.sender] -= amount;
        totalStaked -= amount;
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

    function _preview() private view returns (uint256 value, uint256 queue, uint256 remainder) {
        value = rewardPerTokenStored;
        queue = queuedRewards + hook.totalStakingFees() - accountedFees;
        remainder = scaledRemainder;
        if (totalStaked != 0) {
            value += Math.mulDiv(queue, SCALE, totalStaked);
            uint256 carry = mulmod(queue, SCALE, totalStaked) + remainder;
            value += carry / totalStaked;
            remainder = carry % totalStaked;
            queue = 0;
        }
    }

    function _updateGlobal() private {
        (rewardPerTokenStored, queuedRewards, scaledRemainder) = _preview();
        accountedFees = hook.totalStakingFees();
    }

    function _update(address account) private {
        _updateGlobal();
        uint256 increment = rewardPerTokenStored - userRewardPerTokenPaid[account];
        uint256 fraction = mulmod(balanceOf[account], increment, SCALE) + userRemainder[account];
        rewards[account] += Math.mulDiv(balanceOf[account], increment, SCALE) + fraction / SCALE;
        userRemainder[account] = fraction % SCALE;
        userRewardPerTokenPaid[account] = rewardPerTokenStored;
    }
}
