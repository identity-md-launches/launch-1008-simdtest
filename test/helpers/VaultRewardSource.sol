// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SIMDTESTVault, ISIMDTESTFeeSource} from "src/SIMDTESTVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @dev Isolates vault accounting. Accrual is distinct from transfer/notification, as in the real hook.
contract VaultRewardSource is ISIMDTESTFeeSource {
    uint256 public totalStakingFees;
    uint256 public swept;
    MockERC20 public immutable reward;
    SIMDTESTVault public immutable vault;

    constructor(IERC20 stake, MockERC20 reward_) {
        reward = reward_;
        vault = new SIMDTESTVault(stake, reward_, this);
    }

    function accrue(uint256 amount) external {
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
