// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "./StakingStorage.sol";

contract StakingGov is StakingStorage {

    /* ========== VIEWS ========== */

    /**
     * @notice Gets the current sum of votes balance all accounts in all pools
     * @return The number of current total votes
     */
    function getTotalVotes() external view returns (uint256) {
        return totalVotes;
    }

    /**
     * @notice Gets the current votes balance for `account`
     * @param account The address to get votes balance
     * @return The number of current votes for `account`
     */
    function getCurrentVotes(address account) external view returns (uint256) {
        uint32 nCheckpoints = numCheckpoints[account];
        return nCheckpoints > 0 ? checkpoints[account][nCheckpoints - 1].votes : 0;
    }

    /**
     * @notice Determine the prior number of votes for an account as of a block number
     * @dev Block number must be a finalized block or else this function will revert to prevent misinformation.
     * @param account The address of the account to check
     * @param blockNumber The block number to get the vote balance at
     * @return The number of votes the account had as of the given block
     */
    function getPriorVotes(address account, uint blockNumber) public view returns (uint256) {
        require(blockNumber < block.number, "ERR_VOTES_NOT_YET_DETERMINED");

        uint32 nCheckpoints = numCheckpoints[account];
        if (nCheckpoints == 0) {
            return 0;
        }

        // First check most recent balance
        if (checkpoints[account][nCheckpoints - 1].fromBlock <= blockNumber) {
            return checkpoints[account][nCheckpoints - 1].votes;
        }

        // Next check implicit zero balance
        if (checkpoints[account][0].fromBlock > blockNumber) {
            return 0;
        }

        uint32 lower = 0;
        uint32 upper = nCheckpoints - 1;
        while (upper > lower) {
            uint32 center = upper - (upper - lower) / 2; // ceil, avoiding overflow
            Checkpoint memory cp = checkpoints[account][center];
            if (cp.fromBlock == blockNumber) {
                return cp.votes;
            } else if (cp.fromBlock < blockNumber) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return checkpoints[account][lower].votes;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    /**
     * @notice Delegate votes from `msg.sender` in `pid` to `delegatee`
     * @param pid Pool id to be staked in
     * @param delegatee The address to delegate votes to
     */
    function delegate(uint256 pid, address delegatee) public {
        return _delegate(pid, msg.sender, delegatee);
    }

    /**
     * @notice Delegates votes from signatory to `delegatee`
     * @param delegatee The address to delegate votes to
     * @param nonce The contract state required to match the signature
     * @param expiry The time at which to expire the signature
     * @param v The recovery byte of the signature
     * @param r Half of the ECDSA signature pair
     * @param s Half of the ECDSA signature pair
     */
    function delegateBySig(uint256 pid, address delegatee, uint nonce, uint expiry, uint8 v, bytes32 r, bytes32 s) public {
        bytes32 domainSeparator = keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256(bytes(name)), _getChainId(), address(this)));
        bytes32 structHash = keccak256(abi.encode(DELEGATION_TYPEHASH, delegatee, nonce, expiry, pid));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        address signatory = ecrecover(digest, v, r, s);
        require(signatory != address(0), "ERR_INVALID_SIGNATURE");
        require(nonce == nonces[signatory]++, "ERR_INVALID_NONCE");
        require(block.timestamp <= expiry, "ERR_SIGNATURE_EXPIRED");
        return _delegate(pid, signatory, delegatee);
    }


    function _delegate(uint256 pid, address delegator, address delegatee) internal {
        UserInfo storage user = userInfo[pid][delegator];
        address currentDelegate = user.delegatee;
        uint256 delegatorVotes = _getPoolDelegatorVotes(pid, delegator);
        user.delegatee = delegatee;

        emit DelegateChanged(delegator, currentDelegate, delegatee);

        _moveDelegates(currentDelegate, delegatee, delegatorVotes);
    }

    function _moveDelegates(address srcRep, address dstRep, uint256 votes) internal {
        if (srcRep != dstRep && votes > 0) {
            if (srcRep != address(0)) {
                _decreaseVotingPower(srcRep, votes);
            }
            if (dstRep != address(0)) {
                _increaseVotingPower(dstRep, votes);
            }
        }
    }

    function _decreaseVotingPower(address delegatee, uint256 votes) internal {
            uint32 nCheckpoints = numCheckpoints[delegatee];
            uint256 oldVotingPower = nCheckpoints > 0 ? checkpoints[delegatee][nCheckpoints - 1].votes : 0;
            uint256 newVotingPower = oldVotingPower - votes;
            totalVotes -= votes;
            _writeCheckpoint(delegatee, nCheckpoints, oldVotingPower, newVotingPower);
    }

    function _increaseVotingPower(address delegatee, uint256 votes) internal {
            uint32 nCheckpoints = numCheckpoints[delegatee];
            uint256 oldVotingPower = nCheckpoints > 0 ? checkpoints[delegatee][nCheckpoints - 1].votes : 0;
            uint256 newVotingPower = oldVotingPower + votes;
            totalVotes += votes;
            _writeCheckpoint(delegatee, nCheckpoints, oldVotingPower, newVotingPower);
    }

    function _getPoolDelegatorVotes(uint256 pid, address delegator) internal view returns(uint256) {
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][delegator];

        uint256 delegatorVotes;

        if (user.unstakeRequestTime == 0) {
            delegatorVotes = user.amount * pool.votingMultiplier;
        } else {
            delegatorVotes = user.amount;
        }

        return delegatorVotes;
    }

    function _unboostVotingPower(uint256 pid, address delegator) internal {
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][delegator];
        address delegatee = user.delegatee;
        uint256 lostVotingPower = user.amount * (pool.votingMultiplier - 1);
        _decreaseVotingPower(delegatee, lostVotingPower);
    }

    function _boostVotingPower(uint256 pid, address delegator) internal {
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][delegator];
        address delegatee = user.delegatee;
        uint256 recoveredVotingPower = user.amount * (pool.votingMultiplier - 1);
        _increaseVotingPower(delegatee, recoveredVotingPower);
    }

    function _writeCheckpoint(address delegatee, uint32 nCheckpoints, uint256 oldVotes, uint256 newVotes) internal {
      uint32 blockNumber = _safe32(block.number, "StakingGov::_writeCheckpoint: block number exceeds 32 bits");

      if (nCheckpoints > 0 && checkpoints[delegatee][nCheckpoints - 1].fromBlock == blockNumber) {
          checkpoints[delegatee][nCheckpoints - 1].votes = newVotes;
      } else {
          checkpoints[delegatee][nCheckpoints] = Checkpoint(blockNumber, newVotes);
          numCheckpoints[delegatee] = nCheckpoints + 1;
      }

      emit DelegateVotesChanged(delegatee, oldVotes, newVotes);
    }

    /* ========== PURES ========== */

    function _safe32(uint n, string memory errorMessage) internal pure returns (uint32) {
        require(n < 2**32, errorMessage);
        return uint32(n);
    }

    function _getChainId() internal view returns (uint) {
        uint256 chainId;
        assembly { chainId := chainid() }
        return chainId;
    }

    /* ========== EVENTS ========== */

    /// @notice An event thats emitted when the minter address is changed
    event MinterChanged(address minter, address newMinter);

    /// @notice An event thats emitted when an account changes its delegate
    event DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate);

    /// @notice An event thats emitted when a delegate account's vote balance changes
    event DelegateVotesChanged(address indexed delegate, uint previousBalance, uint newBalance);

    /// @notice The standard EIP-20 transfer event
    event Transfer(address indexed from, address indexed to, uint256 amount);

    /// @notice The standard EIP-20 approval event
    event Approval(address indexed owner, address indexed spender, uint256 amount);

}