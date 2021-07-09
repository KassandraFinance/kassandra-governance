// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./StakingGov.sol";

contract Staking is StakingGov, Pausable, ReentrancyGuard, Ownable {

    using SafeERC20 for IERC20;

    /* ========== VIEWS ========== */

    /**
     * @notice Gets the total deposited amount in the pool `pid`
     * @param pid The pool id to get the deposited amount from
     * @return Deposited amount in the pool
     */
    function depositedAmount(uint256 pid) public view poolInteraction(pid) returns (uint256) {
        PoolInfo storage pool = poolInfo[pid];
        return pool.depositedAmount;
    }

    /**
     * @notice Gets the balance of the address `account` in the pool `pid`
     * @param pid The pool id to get the balance from
     * @param account The address to get the balance
     * @return Deposited amount in the pool `pid` by `account`
     */
    function balanceOf(uint256 pid, address account) public view poolInteraction(pid) returns (uint256) {
        return userInfo[pid][account].amount;
    }

    /**
     * @notice Gets the last time that the pool `pid` was last updated
     * @dev The `lastUpdateTime` param is usually updated by the modifier `updateReward`
     * @param pid The pool id to get the time from
     * @return The timestamp of whether the pool was last updated
     */
    function lastTimeRewardApplicable(uint pid) public view poolInteraction(pid) returns (uint256) {
        PoolInfo storage pool = poolInfo[pid];
        return min(block.timestamp, pool.periodFinish);
    }

    /**
     * @notice Gets the reward rate per token deposited in the pool `pid`
     * @param pid The pool id to get the reward per token from
     * @return The reward rate per token for the pool `pid`
     */
    function rewardPerToken(uint pid) public view poolInteraction(pid) returns (uint256) {
        PoolInfo storage pool = poolInfo[pid];
        if (pool.depositedAmount == 0) {
            return pool.rewardPerTokenStored;
        }
        return
            pool.rewardPerTokenStored + (
                (lastTimeRewardApplicable(pid) - pool.lastUpdateTime) * pool.rewardRate * (1e18) / pool.depositedAmount
            );
    }

    /**
     * @notice Gets the claimable rewards for `account` in the pool `pid`
     * @param pid The pool id to get the rewards earned from
     * @param account The address to get the rewards earned from
     * @return The claimable rewards for `account` in the pool `pid`
     */
    function earned(uint256 pid, address account) public view poolInteraction(pid) returns (uint256) {
        UserInfo storage user = userInfo[pid][account];
        return user.amount * (rewardPerToken(pid) - user.rewardPerTokenPaid) / 1e18  + user.pendingRewards;
    }

    /**
     * @notice Gets how much rewards will be distributed through the pool `pid` during the whole distribution period
     * @param pid The pool id to get the rewards from
     * @return The amount that the pool `pid` will distribute
     */
    function getRewardForDuration(uint256 pid) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[pid];
        return pool.rewardRate * pool.rewardsDuration;
    }

    /**
     * @notice Gets the timestamp that the tokens will be locked until
     * @dev If the pool have a withdrawal Delay, to the lock until timestamp be known it's needed that the user have already made a withdrawal request
     * @param pid The pool id to get the timestamp from
     * @param account The address to get the timestamp from
     * @return The lock timestamp of `account` in the pool `pid`
     */
    function lockUntil(uint256 pid, address account) public view poolInteraction(pid) returns (uint256) {
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][account];
        require(user.withdrawRequestTime == 0 && pool.withdrawDelay != 0, "Staking::lockUntil: tokens indefinitely locked, request withdraw to start the delay");
        return max(user.withdrawRequestTime + pool.withdrawDelay, user.depositTime + pool.lockPeriod);
    }

    /**
     * @notice Gets whether the `account` can withdraw from pool `pid`
     * @dev If pool have withdraw delay, then ensure it has been runned and finished, else calls `lockUntil`
     * @param pid The pool id to check
     * @param account The address to check
     * @return A boolean of wheter the `account` can withdraw from pool `pid`
     */
    function withdrawable(uint256 pid, address account) public view poolInteraction(pid) returns (bool) {
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][account];
        if (pool.withdrawDelay == 0 && pool.lockPeriod == 0) {
            return true;
        } else if (pool.withdrawDelay != 0 && user.withdrawRequestTime == 0) {
            return false;
        } else {
            return (block.timestamp > lockUntil(pid, account));
        }
    }

    /**
     * @notice Gets the available withdrawable amount for `account` in the pool `pid`
     * @dev If not withdawable return 0, if lock and vesting period ended return the full amount, else linear release by the vesting period
     * @param pid The pool id to get the timestamp from
     * @param account The address to get the timestamp from
     * @return The available withdrawable amount for `account` in the pool `pid`
     */
    function availableWithdraw(uint256 pid, address account) public view poolInteraction(pid) returns (uint256) {
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][account];
        if (!withdrawable(pid, account)) {
            return 0;
        } else if (block.timestamp >= user.depositTime + pool.lockPeriod + pool.vestingPeriod) {
            return user.amount;
        } else {
            return user.amount * (block.timestamp -  user.lastWithdraw)/(user.depositTime + pool.lockPeriod + pool.vestingPeriod);
        }
    }

    /* ========== PURE FUNCTIONS ========== */

    function max(uint a, uint b) private pure returns (uint) {
        return a > b ? a : b;
    }

    function min(uint a, uint b) private pure returns (uint) {
        return a < b ? a : b;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

	/**
	 * @notice Stake tokens to the pool `pid`
     * @dev `StakeFor` and `delegatee` can be passed as `address(0)` and the `stake` will work in a sensible way
     * @param pid Pool id to be staked in
	 * @param amount The amount of tokens to stake
	 * @param stakeFor The address to stake the tokens for or 0x0 if staking for oneself
	 * @param delegatee The address of the delegatee or 0x0 if there is none
	 * */
    function stake(uint256 pid, uint256 amount, address stakeFor, address delegatee) external nonReentrant whenNotPaused updateReward(pid, msg.sender) {
        require(amount > 0, "Staking::stake: cannot stake 0");

		// Stake for the sender if not specified otherwise.
		if (stakeFor == address(0)) {
			stakeFor = msg.sender;
		}

		// Delegate for stakeFor if not specified otherwise.
		if (delegatee == address(0)) {
			delegatee = stakeFor;
		}

        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][stakeFor];
        IERC20 stakingToken = IERC20(pool.stakingToken);

        //  Reset withdrawDelay due to new stake
        if (pool.withdrawDelay != 0 && user.withdrawRequestTime != 0){
            user.withdrawRequestTime = 0;
            _undelayVotingPower(pid, stakeFor);
        }

        // Decrease voting power of previous delegatee
		address previousDelegatee = user.delegatee;
		if (previousDelegatee != delegatee) {
            uint256 previousVotingPower = user.amount * pool.votingMultiplier;
			_decreaseVotingPower(previousDelegatee, previousVotingPower);
			// Update delegatee.
			user.delegatee = delegatee;
		}

        // Update stake parms
        pool.depositedAmount = pool.depositedAmount + amount;
        user.amount = user.amount + amount;
        user.depositTime = block.timestamp;
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);

        // Increase voting power of new delegatee
        uint256 newVotingPower = amount * pool.votingMultiplier;
        _increaseVotingPower(delegatee, newVotingPower);

        emit Staked(pid, stakeFor, amount);
    }

	/**
	 * @notice Withdraw tokens according to the delay, lock and vesting schedules
     * @param pid Pool id to be withdrawn from
	 * @param amount The amount of tokens to be withdrawn
	 * */
    function withdraw(uint256 pid, uint256 amount) public nonReentrant updateReward(pid, msg.sender) {
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][msg.sender];

        require(block.timestamp >= (user.depositTime + pool.lockPeriod), 'Staking::withdraw: tokens locked');
        require(amount <= availableWithdraw(pid, msg.sender), "Staking::withdraw: cannot withdraw more than available");
        require(amount > 0, "Staking::withdraw: cannot withdraw 0");

        //  If withdrawable: withdraw
        if (withdrawable(pid, msg.sender)) {
            // Remove voting power
            uint256 votingPower = user.withdrawRequestTime == 0 ? amount * pool.votingMultiplier : amount;
            _decreaseVotingPower(user.delegatee, votingPower);
            IERC20 stakingToken = IERC20(pool.stakingToken);

            pool.depositedAmount = pool.depositedAmount - amount;
            user.amount = user.amount - amount;
            user.lastWithdraw = block.timestamp;
            stakingToken.safeTransfer(msg.sender, amount);
            emit Withdrawn(pid, msg.sender, amount);

        // If pool with `withdrawDelay` and it's the first withdraw request: start withdrawal delay
        } else if (user.withdrawRequestTime == 0 && pool.withdrawDelay != 0) { 
            _delayVotingPower(pid, user.delegatee);
            // Setting `withdrawRequestTime` to different than zero starts the withdrawal delay
            user.withdrawRequestTime = block.timestamp;
            emit Vesting(pid, msg.sender, amount, lockUntil(pid, msg.sender));

        // Only gets here during `lockPeriod` or running `withdrawDelay`: tokens are locked
        } else {
            emit WithdrawDenied(pid, msg.sender, amount, lockUntil(pid, msg.sender));
        }
    }

	/**
	 * @notice Claim the earned rewards for the transaction sender in the pool `pid`
     * @param pid Pool id to get the rewards from
	 * */
    function getReward(uint256 pid) public nonReentrant updateReward(pid, msg.sender) {
        UserInfo storage user = userInfo[pid][msg.sender];
        uint256 reward = user.pendingRewards;
        if (reward > 0) {
            user.pendingRewards = 0;
            kacy.safeTransfer(msg.sender, reward);
            emit RewardPaid(pid, msg.sender, reward);
        } else {
            emit RewardDenied(pid, msg.sender, reward);
        }
    }

	/**
	 * @notice Withdraw fund and claim the earned rewards for the transaction sender in the pool `pid`
     * @param pid Pool id to get the rewards from
	 * */
    function exit(uint256 pid) external {
        UserInfo storage user = userInfo[pid][msg.sender];
        withdraw(pid, user.amount);
        getReward(pid);
    }

    /**
     * @notice Delegate all votes from `msg.sender` to `delegatee`
     * @dev This is a governance function, but it is defined here because it dependes of `balanceOf`
     * @param delegatee The address to delegate votes to
     */
    function delegateAll(address delegatee) public {
        for (uint256 pid; pid <= poolInfo.length; pid++){
            if (balanceOf(pid, msg.sender) > 0){
                UserInfo storage user = userInfo[pid][msg.sender];
                if(user.delegatee != delegatee) {
                    _delegate(pid, msg.sender, delegatee);
                }
            }
        }
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    /// @dev Add new staking pool
      function addPool(address _stakingToken, uint256 _rewardsDuration, uint256 _lockPeriod, uint256 _withdrawDelay, uint256 _vestingPeriod, uint256 _votingMultiplier) external onlyOwner {
        poolInfo.push(
            PoolInfo({
                stakingToken: _stakingToken,
                depositedAmount: 0,
                lastUpdateTime: 0,
                rewardPerTokenStored: 0,
                rewardsDuration: _rewardsDuration,
                rewardRate: 0,
                periodFinish: 0,
                lockPeriod: _lockPeriod,
                withdrawDelay: _withdrawDelay,
                vestingPeriod: _vestingPeriod,
                votingMultiplier: _votingMultiplier
            })
        );
        emit NewPool(poolInfo.length - 1);
    }

    /// @dev Add rewards to the pool
    function addReward(uint256 pid, uint256 reward) external onlyOwner updateReward(pid, address(0)) {
        PoolInfo storage pool = poolInfo[pid];
        require(pool.rewardsDuration > 0, "Staking::addReward: rewardDuration must be greater than zero");

        kacy.safeTransferFrom(msg.sender, address(this), reward);

        if (block.timestamp >= pool.periodFinish) {
            pool.rewardRate = reward / pool.rewardsDuration;
        } else {
            uint256 remaining = pool.periodFinish - block.timestamp;
            uint256 leftover = remaining * pool.rewardRate;
            pool.rewardRate = (reward + leftover) / pool.rewardsDuration;
        }

        pool.lastUpdateTime = block.timestamp;
        pool.periodFinish = (block.timestamp + pool.rewardsDuration);
        emit RewardAdded(pid, reward);
    }

    /// @dev End rewards emission earlier
    function updatePeriodFinish(uint256 pid, uint256 timestamp) external onlyOwner updateReward(pid, address(0)) {
        PoolInfo storage pool = poolInfo[pid];
        pool.periodFinish = timestamp;
    }

    /// @dev Recover tokens from pool
    function recoverERC20(uint256 pid, address tokenAddress, uint256 tokenAmount) external onlyOwner {
        PoolInfo storage pool = poolInfo[pid];
        require(tokenAddress != address(pool.stakingToken), "Cannot withdraw the staking token");
        address owner = owner();
        IERC20(tokenAddress).safeTransfer(owner, tokenAmount);
        emit Recovered(pid, tokenAddress, tokenAmount);
    }

    /// @dev Set new rewards distribution duration
    function setRewardsDuration(uint256 pid, uint256 _rewardsDuration) external onlyOwner {
        PoolInfo storage pool = poolInfo[pid];
        require(
            block.timestamp > pool.periodFinish,
            "Staking::setRewardsDuration: previous rewards period must be complete before changing the duration for the new period"
        );
        pool.rewardsDuration = _rewardsDuration;
        emit RewardsDurationUpdated(pid, pool.rewardsDuration);
    }
    
    /// @dev Set the governance and reward token
    function setKacy(address _kacy) external onlyOwner {
        kacy = IERC20(_kacy);
    }

    /* ========== MODIFIERS ========== */

    /// @dev Modifier that is called to update pool and user rewards stats everytime a user interact with a pool
    modifier updateReward(uint pid, address account) {
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][account];
        
        if (poolInfo[pid].lastUpdateTime == 0) {
            pool.lastUpdateTime = block.timestamp;
        } else {
            pool.rewardPerTokenStored = rewardPerToken(pid);
            pool.lastUpdateTime = lastTimeRewardApplicable(pid);
        }


        if (account != address(0)) {
            user.pendingRewards = earned(pid, account);
            user.rewardPerTokenPaid = pool.rewardPerTokenStored;
        }
        _;
    }

    /// @dev Modifier to unsure staking has started
    modifier poolInteraction(uint pid) {
        require(poolInfo[pid].lastUpdateTime > 0 && block.timestamp >= poolInfo[pid].lastUpdateTime, 'Staking::poolInteraction: staking not started yet');
        _;
    }

    /* ========== EVENTS ========== */

    event NewPool(uint256 indexed pid);
    event RewardAdded(uint256 indexed pid, uint256 indexed reward);
    event Staked(uint256 indexed pid, address indexed user, uint256 amount);
    event Vesting(uint256 indexed pid, address indexed user, uint256 amount, uint256 availableTime);
    event Withdrawn(uint256 indexed pid, address indexed user, uint256 amount);
    event WithdrawDenied(uint256 indexed pid, address indexed user, uint256 amount, uint256 availableTime);
    event RewardPaid(uint256 indexed pid, address indexed user, uint256 reward);
    event RewardDenied(uint256 indexed pid, address indexed user, uint256 reward);
    event RewardsDurationUpdated(uint256 indexed pid, uint256 duration);
    event Recovered(uint256 indexed pid, address indexed token, uint256 indexed amount);

}