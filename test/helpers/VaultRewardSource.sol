// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SIMDTESTVault, ISIMDTESTFeeSource} from "src/SIMDTESTVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @dev Isolates vault accounting. Accrual is distinct from transfer/notification, as in the real hook,
/// and the per-block fee boundary record mirrors SIMDTESTHook._accrue exactly: a block's end total is
/// written only when a later block accrues, and zero-fee accruals leave no trace.
contract VaultRewardSource is ISIMDTESTFeeSource {
    uint256 public totalStakingFees;
    uint256 public lastAccrualBlock;
    mapping(uint256 => uint256) public stakingFeesAtEndOf;
    uint256 public swept;
    MockERC20 public immutable reward;
    SIMDTESTVault public immutable vault;

    constructor(IERC20 stake, MockERC20 reward_) {
        reward = reward_;
        lastAccrualBlock = block.number;
        vault = new SIMDTESTVault(stake, reward_, this);
    }

    function accrue(uint256 amount) external {
        if (amount == 0) return;
        if (block.number != lastAccrualBlock) {
            stakingFeesAtEndOf[lastAccrualBlock] = totalStakingFees;
            lastAccrualBlock = block.number;
        }
        totalStakingFees += amount;
        reward.mint(address(this), amount);
    }

    function sweep() external {
        uint256 amount = totalStakingFees - swept;
        if (amount == 0) return;
        swept = totalStakingFees;
        require(reward.transfer(address(vault), amount));
        vault.notifyReward(amount);
    }

    function notifyOnly(uint256 amount) external {
        vault.notifyReward(amount);
    }
}
