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
    function depositedAmount(uint256 pid) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[pid];
        return pool.depositedAmount;
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
     * @notice Gets the balance of the address `account` in the pool `pid`
     * @param pid The pool id to get the balance from
     * @param account The address to get the balance
     * @return Deposited amount in the pool `pid` by `account`
     */
    function balanceOf(uint256 pid, address account) public view returns (uint256) {
        return userInfo[pid][account].amount;
    }

    /**
     * @notice Gets the last time that the pool `pid` was giving rewards
     * @dev Stops increasing when `pool.rewardsDuration` ends
     * @param pid The pool id to get the time from
     * @return The timestamp of whether the pool was last updated
     */
    function lastTimeRewardApplicable(uint pid) public view returns (uint256) {
        PoolInfo storage pool = poolInfo[pid];
        return _min(block.timestamp, pool.periodFinish);
    }

    /**
     * @notice Gets the reward rate per token deposited in the pool `pid`
     * @param pid The pool id to get the reward per token from
     * @return The reward rate per token for the pool `pid`
     */
    function rewardPerToken(uint pid) public view returns (uint256) {
        PoolInfo storage pool = poolInfo[pid];
        if (pool.depositedAmount == 0) {
            return pool.rewardPerTokenStored;
        } else if (pool.lastUpdateTime > lastTimeRewardApplicable(pid)) {
            return 0;
        }
        return
            pool.rewardPerTokenStored + (
                (lastTimeRewardApplicable(pid) - pool.lastUpdateTime) * pool.rewardRate * (1e18) / pool.depositedAmount
            );
    }

    /**
     * @notice Gets the claimable rewards for `account` in the pool `pid`
     * @dev Unstaking stops rewards
     * @param pid The pool id to get the rewards earned from
     * @param account The address to get the rewards earned from
     * @return The claimable rewards for `account` in the pool `pid`
     */
    function earned(uint256 pid, address account) public view returns (uint256) {
        UserInfo storage user = userInfo[pid][account];
        if (user.unstakeRequestTime != 0) {
            return user.pendingRewards;
        } else {
            return user.amount * (rewardPerToken(pid) - user.rewardPerTokenPaid) / 1e18  + user.pendingRewards;
        }
    }

    /**
     * @notice Gets the timestamp that the tokens will be locked until
     * @dev This doesnt take withdrawal delay into account
     * @param pid The pool id to get the timestamp from
     * @param account The address to get the timestamp from
     * @return The lock timestamp of `account` in the pool `pid`
     */
    function lockUntil(uint256 pid, address account) public view returns (uint256) {
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][account];
        return user.depositTime + pool.lockPeriod;
    }

    /**
     * @notice Gets wether the `account` is locked by the pool locking period
     * @dev This doesnt take withdrawal delay into account
     * @param pid The pool id to check
     * @param account The address to check
     * @return A boolean of wheter the `account` is locked or not in pool `pid`
     */
    function locked(uint256 pid, address account) public view returns (bool) {
        return (block.timestamp < lockUntil(pid, account));
    }

    /**
     * @notice Gets the timestamp that the withdrawal delay ends
     * @dev For pools with withdrawal delay the returned value keep incresing until unstake requested
     * @param pid The pool id to check
     * @param account The address to check
     * @return The staked timestamp of `account` in the pool `pid`
     */
    function stakedUntil(uint256 pid, address account) public view returns (uint256) {
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][account];
        uint256 delayedTime; 
        if (pool.withdrawDelay == 0) {
            // If no withdrawDelay
            delayedTime = 0;
        } else if (user.unstakeRequestTime == 0) {
            // If withdrawDelay and no withdraw request
            delayedTime = block.timestamp + pool.withdrawDelay;
        } else {
            // If withdrawDelay and already requested withdraw a previous time
            delayedTime = user.unstakeRequestTime + pool.withdrawDelay;
        }
        return delayedTime;
    }

    /**
     * @notice Gets wether the `account` needs to be unstacked to be withdrawable
     * @dev Checks if the pool has withdrawal delay and unstake hasnt been requested yet
     * @param pid The pool id to check
     * @param account The address to check
     * @return A boolean of wheter unstake needs to be called
     */
    function needUnstake(uint256 pid, address account) public view returns (bool) {
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][account];
        return (pool.withdrawDelay != 0 && user.unstakeRequestTime == 0);
    }

    /**
     * @notice Gets when the `account` has a running withdrawal delay
     * @dev Returns false for pools that withdrawal delay has ended
     * @param pid The pool id to check
     * @param account The address to check
     * @return A boolean of wheter the `account` is unstaking `pid`
     */
    function unstaking(uint256 pid, address account) public view returns (bool) {
        PoolInfo storage pool = poolInfo[pid];
        if (pool.withdrawDelay == 0) {
            return false;
        } else if (needUnstake(pid, account)) {
            return false;
        } else {
            return (block.timestamp < stakedUntil(pid, account));
        }
    }

    /**
     * @notice Gets whether the `account` can withdraw from pool `pid`
     * @dev If pool have withdraw delay, then ensure it has been runned and finished, else calls `lockUntil`
     * @param pid The pool id to check
     * @param account The address to check
     * @return A boolean of wheter the `account` can withdraw from pool `pid`
     */
    function withdrawable(uint256 pid, address account) public view returns (bool) {
        PoolInfo storage pool = poolInfo[pid];
        if (pool.withdrawDelay == 0 && pool.lockPeriod == 0) {
            return true;
        } else if (needUnstake(pid, account)) {
            return false;
        } else {
            return (!locked(pid, account) && !unstaking(pid, account));
        }
    }

    /**
     * @notice Gets the available withdrawable amount for `account` in the pool `pid`
     * @dev If not withdawable return 0, if lock and vesting period ended return the full amount,
     * else linear release by the vesting period
     * @param pid The pool id to get the timestamp from
     * @param account The address to get the timestamp from
     * @return The available withdrawable amount for `account` in the pool `pid`
     */
    function availableWithdraw(uint256 pid, address account) public view returns (uint256) {
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][account];
        if (!withdrawable(pid, account)) {
            return 0;
        } else if (block.timestamp >= user.depositTime + pool.lockPeriod + pool.vestingPeriod) {
            return user.amount;
        } else {
            return user.amount * (
                block.timestamp - user.depositTime)/(pool.lockPeriod + pool.vestingPeriod
            ) - user.withdrawn;
        }
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    /**
     * @notice Stake tokens to the pool `pid`
     * @dev `StakeFor` and `delegatee` can be passed as `address(0)` and the `stake` will work in a sensible way
     * @param pid Pool id to be staked in
     * @param amount The amount of tokens to stake
     * @param stakeFor The address to stake the tokens for or 0x0 if staking for oneself
     * @param delegatee The address of the delegatee or 0x0 if there is none
     */
    function stake(
        uint256 pid,
        uint256 amount,
        address stakeFor,
        address delegatee
        ) external nonReentrant whenNotPaused updateReward(pid, msg.sender)
    {
        require(amount > 0, "ERR_CAN_NOT_STAKE_ZERO");

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

        if (stakeFor != msg.sender) {
            // Avoid third parties to reset stake vestings
            require(user.amount == 0, "ERR_STAKE_FOR_LIVE_USER");
        }

        //  Reset withdrawDelay due to new stake
        if (pool.withdrawDelay != 0 && user.unstakeRequestTime != 0){
            user.unstakeRequestTime = 0;
            _undelayVotingPower(pid, stakeFor);
        }

        // Update voting power if there is a new delegatee
        address previousDelegatee = user.delegatee;
        if (previousDelegatee != delegatee) {
            uint256 previousVotingPower = user.amount * pool.votingMultiplier;
            _decreaseVotingPower(previousDelegatee, previousVotingPower);
            _increaseVotingPower(delegatee, previousVotingPower);
            // Update delegatee.
            user.delegatee = delegatee;

        }

        // Update stake parms
        pool.depositedAmount = pool.depositedAmount + amount;
        user.amount = user.amount + amount;
        // Beware, depositing in a pool with running vesting resets it
        user.depositTime = block.timestamp;
        user.withdrawn = 0;
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);

        // Increase voting power due to new stake
        uint256 newVotingPower = amount * pool.votingMultiplier;
        _increaseVotingPower(delegatee, newVotingPower);

        emit Staked(pid, stakeFor, amount);
    }

    /**
     * @notice Unstake tokens to start the withdrawal delay
     * @dev Only needed for pools with withdrawal delay
     * @param pid Pool id to be withdrawn from
     */
    function unstake(uint256 pid) external nonReentrant updateReward(pid, msg.sender) {
        require(needUnstake(pid, msg.sender), "ERR_ALREADY_UNSTAKED");
        require(!locked(pid, msg.sender), "ERR_TOKENS_LOCKED");

        UserInfo storage user = userInfo[pid][msg.sender];

        _delayVotingPower(pid, user.delegatee);
        user.unstakeRequestTime = block.timestamp;
        emit Unstaking(pid, msg.sender, stakedUntil(pid, msg.sender));
    }

    /**
     * @notice Withdraw tokens from pool according to the delay, lock and vesting schedules
     * @param pid Pool id to be withdrawn from
     * @param amount The amount of tokens to be withdrawn
     */
    function withdraw(uint256 pid, uint256 amount) public nonReentrant updateReward(pid, msg.sender) {
        require(amount > 0, "ERR_CAN_NOT_WTIHDRAW_ZERO");
        require(amount <= availableWithdraw(pid, msg.sender), "ERR_WITHDRAW_MORE_THAN_AVAILABLE");
 
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][msg.sender];

        // Remove voting power
        uint256 votingPower = user.unstakeRequestTime == 0 ? amount * pool.votingMultiplier : amount;
        _decreaseVotingPower(user.delegatee, votingPower);
        IERC20 stakingToken = IERC20(pool.stakingToken);

        // Update stake parms
        pool.depositedAmount = pool.depositedAmount - amount;
        user.amount = user.amount - amount;
        user.withdrawn = user.withdrawn + amount;
        stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(pid, msg.sender, amount);
    }

    /**
     * @notice Claim the earned rewards for the transaction sender in the pool `pid`
     * @param pid Pool id to get the rewards from
     */
    function getReward(uint256 pid) public nonReentrant updateReward(pid, msg.sender) {
        UserInfo storage user = userInfo[pid][msg.sender];
        uint256 reward = user.pendingRewards;
        if (reward > 0) {
            user.pendingRewards = 0;
            kacy.safeTransfer(msg.sender, reward);
            emit RewardPaid(pid, msg.sender, reward);
        }
    }

    /**
     * @notice Withdraw fund and claim the earned rewards for the transaction sender in the pool `pid`
     * @param pid Pool id to get the rewards from
     */
    function exit(uint256 pid) external {
        UserInfo storage user = userInfo[pid][msg.sender];
        withdraw(pid, user.amount);
        getReward(pid);
    }

    /**
     * @notice Delegate all votes from `msg.sender` to `delegatee`
     * @dev This is a governance function, but it is defined here because it depends on `balanceOf`
     * @param delegatee The address to delegate votes to
     */
    function delegateAll(address delegatee) external {
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
    function addPool(
        address _stakingToken,
        uint256 _rewardsDuration,
        uint256 _lockPeriod,
        uint256 _withdrawDelay,
        uint256 _vestingPeriod,
        uint256 _votingMultiplier
        ) external onlyOwner
    {
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
        require(pool.rewardsDuration > 0, "ERR_REWARD_DURATION_ZERO");

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
        require(tokenAddress != address(pool.stakingToken), "ERR_RECOVER_STAKING_TOKEN");
        address owner = owner();
        IERC20(tokenAddress).safeTransfer(owner, tokenAmount);
        emit Recovered(pid, tokenAddress, tokenAmount);
    }

    /// @dev Set new rewards distribution duration
    function setRewardsDuration(uint256 pid, uint256 _rewardsDuration) external onlyOwner {
        PoolInfo storage pool = poolInfo[pid];
        require(block.timestamp > pool.periodFinish, "ERR_RUNNING_REWARDS");
        pool.rewardsDuration = _rewardsDuration;
        emit RewardsDurationUpdated(pid, pool.rewardsDuration);
    }
    
    /// @dev Set the governance and reward token
    function setKacy(address _kacy) external onlyOwner {
        bool returnValue = IERC20(_kacy).transfer(msg.sender, 0);
        require(returnValue, "ERR_NONCONFORMING_TOKEN");
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

    /* ========== PURE FUNCTIONS ========== */

    function _max(uint a, uint b) private pure returns (uint) {
        return a > b ? a : b;
    }

    function _min(uint a, uint b) private pure returns (uint) {
        return a < b ? a : b;
    }

    /* ========== EVENTS ========== */

    event NewPool(uint256 indexed pid);
    event RewardAdded(uint256 indexed pid, uint256 indexed reward);
    event Staked(uint256 indexed pid, address indexed user, uint256 amount);
    event Unstaking(uint256 indexed pid, address indexed user,uint256 availableAt);
    event Withdrawn(uint256 indexed pid, address indexed user, uint256 amount);
    event RewardPaid(uint256 indexed pid, address indexed user, uint256 reward);
    event RewardsDurationUpdated(uint256 indexed pid, uint256 duration);
    event Recovered(uint256 indexed pid, address indexed token, uint256 indexed amount);

}
