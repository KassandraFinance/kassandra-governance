// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract StakingStorage {

    string public constant name = "Kassandra Staking";

    IERC20 public kacy;

    /// @dev Struct to store user data for each pool
    /// @dev `withdrawRequestTime` only with be set to different than zero during withdrawal delays (if the pool have one)
    struct UserInfo {
        uint256 amount;
        uint256 depositTime;
        uint256 pendingRewards;
        uint256 rewardPerTokenPaid;
        uint256 withdrawRequestTime;
        uint256 lastWithdraw;
        address delegatee;
    }

    /// @dev Struct to store pool params
    /// @dev `lockPeriod` is a fixed timestamp that need to be achieved to user deposit amount be withdrawable
    /// @dev `withdrawDelay` is a time locking period that starts after the user makes a withdraw request, after it finish a new withdraw request will fullfil the withdraw
    /// @dev `vestingPeriod` is a time period that starts after the `lockPeriod` that will linear release the withdrawable amount
    struct PoolInfo {
        // General data
        address stakingToken;
        uint256 depositedAmount;
        // Rewards data and params
        uint256 lastUpdateTime;
        uint256 rewardPerTokenStored;
        uint256 rewardsDuration;
        uint256 rewardRate;
        uint256 periodFinish;
        // Vesting params
        uint256 lockPeriod;
        uint256 withdrawDelay;
        uint256 vestingPeriod;
        // Gov params
        uint256 votingMultiplier;
    }

    /// @dev Array of pool infos
    PoolInfo[] public poolInfo;

    /// @dev A map to access the user info for each account: PoolId => Address => UserInfo
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

	/************************** Checkpoints ******************************/

    /// @dev A aggregated record of the total voting power of all accounts
    uint256 totalVotes;

    /// @dev A checkpoint for marking the voting power from a given block
    struct Checkpoint {
        uint32 fromBlock;
        uint256 votes;
    }

    /// @dev A record of votes checkpoints for each account, by index
    mapping (address => mapping (uint32 => Checkpoint)) public checkpoints;

    /// @dev The number of checkpoints for each account
    mapping (address => uint32) public numCheckpoints;

    /// @notice The EIP-712 typehash for the contract's domain
    bytes32 public constant DOMAIN_TYPEHASH = keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");

    /// @notice The EIP-712 typehash for the delegation struct used by the contract
    bytes32 public constant DELEGATION_TYPEHASH = keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)");

    /// @notice The EIP-712 typehash for the permit struct used by the contract
    bytes32 public constant PERMIT_TYPEHASH = keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    /// @notice A record of states for signing / validating signatures
    mapping (address => uint) public nonces;

}
