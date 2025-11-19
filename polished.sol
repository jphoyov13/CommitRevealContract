// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/*
  Here polish Second Draft !!!
  YesNoCommitRevealWithDeposit.sol
  - Binary (Yes/No) commit-reveal voting with:
      * ETH deposit at commit that is refunded on reveal or slashed after finish to mitigate griefing (commiting but not revealing)
      * nonReentrant protection via simple mutex
    
*/

interface IERC20Minimal {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract CommitRevealVoting {
    // ---------- Types ----------
    enum Phase { Commit, Reveal, Finished }   // [Commit = 0; Reveal = 1; Finished = 2]

    struct CommitInfo {
        bytes32 commitHash;
        bool revealed;
        uint256 committedAt;
    }

    // State Variables: (variables that live and persist in the contract storage; are written on the blockchain thus cost gas; do not belong to/inside functions)
    address public admin;
    IERC20Minimal public votingToken; // token interface to interact with ERC20 token contract

    uint256 public commitEnd;   // timestamp when commit phase ends        *+*+*+*+*+*+*+*
    uint256 public revealEnd;   // timestamp when reveal phase ends        *+*+*+*+*+*+*+*
    uint256 public depositAmountWei; // required ETH deposit at commit (slashed if unrevealed)

    mapping(address => CommitInfo) public commits;
    mapping(address => uint256) public lockedWeight; // to check how much Token weight was locked when voting
    mapping(address => uint256) public deposits;     // to check ETH deposits per voter and helps to see if refunded succefull or not

    uint256 public totalYesWeight;  // Returns the total weight of YES votes, 
    uint256 public totalNoWeight;   // Returns the total weight of NO votes
    uint256 public totalRevealedWeight; // Returns the total weight of revealed votes

    // reentrancy guard variable, inspired from: https://github.com/U-GOD/reentrancy-guard-comparison/blob/main/SimpleReentrancyGuard.sol
    uint256 private _locked;

    // Events: 
    event Committed(address indexed voter, bytes32 commitHash, bool lockedAtCommit, uint256 lockedWeight);
    event Revealed(address indexed voter, uint8 vote, uint256 weight, bool depositRefunded);
    event DepositRefunded(address indexed voter, uint256 amount);
    event DepositPendingRefund(address indexed voter, uint256 amount);
    event DepositSlashed(address indexed voter, uint256 amount, address to);
    event TokensSlashed(address indexed voter, uint256 amount, address to);

    //  Modifiers: to restrict functions according to contract flow
    modifier onlyAdmin() {
        require(msg.sender == admin, "only admin");
        _;
    }

    modifier onlyDuringPhase(Phase p) {
        require(currentPhase() == p, "wrong phase");
        _;
    }

    modifier nonReentrant() {   // reentrancy guard (simple mutex) see reference with variable above
        require(_locked == 0, "reentrancy");
        _locked = 1;
        _;
        _locked = 0;
    }

    //  Constructor parameters: what will be set at deployment by contract owner account 
    /*
     _votingToken: ERC20 token address used as voting weight
     _commitDurationSeconds, _revealDurationSeconds: durations for phases
     _depositAmountWei: amount of ETH deposit required to commit */
    constructor(
        address _votingToken,
        uint256 _commitDurationSeconds,
        uint256 _revealDurationSeconds,
        uint256 _depositAmountWei  // deposit >= 0.01ETH to avoid mitigate griefing attach
    ) {
        require(_votingToken != address(0), "token zero");
        require(_commitDurationSeconds > 0 && _revealDurationSeconds > 0, "durations>0");
        admin = msg.sender;
        votingToken = IERC20Minimal(_votingToken);
        commitEnd = block.timestamp + _commitDurationSeconds;
        revealEnd = commitEnd + _revealDurationSeconds;
        depositAmountWei = _depositAmountWei;
    }

    // Phase helper: to show current phase of voting [Commit = 0; Reveal = 1; Finished = 2] 
    function currentPhase() public view returns (Phase) {
        if (block.timestamp <= commitEnd) {
            return Phase.Commit;
        } else if (block.timestamp <= revealEnd) {
            return Phase.Reveal;
        } else {
            return Phase.Finished;
        }
    }

    // Commit phase:
    // Voter/caller must send depositAmountWei as Value and must have 
    // approved this contract as spender for `weight` in token contract before commiting. It locks tokens immediately when committing
    function commitAndLock(uint256 weight, bytes32 commitHash) external payable onlyDuringPhase(Phase.Commit) nonReentrant {
        require(commitHash != bytes32(0), "empty hash");
        CommitInfo storage info = commits[msg.sender];
        require(info.commitHash == bytes32(0), "already committed");
        require(msg.value == depositAmountWei, "deposit incorrect");
        require(weight > 0, "weight>0"); // voter must have minimal token weight due to voting token right

        // transfer tokens from voter to lock them
        bool ok = votingToken.transferFrom(msg.sender, address(this), weight);
        require(ok, "token transferFrom failed");

        // store commit, locked weight and deposit
        info.commitHash = commitHash;
        info.committedAt = block.timestamp;  // <- not necesary but low-cost addition for transparency
        lockedWeight[msg.sender] = weight;
        deposits[msg.sender] += msg.value;

        emit Committed(msg.sender, commitHash, true, weight);
    }
    // Commit hash generator:
    function generateCommitHash( uint8 vote, uint256 weight, string memory secret ) public view returns (bytes32 commitHash) {
    commitHash= keccak256( abi.encode(vote, weight, secret, msg.sender) ); // here is the hash encoding process to create sealed vote
    }

    // Reveal phase: 
    // vote: 0 => No, 1 => Yes
    function reveal(uint8 vote, uint256 weight, string calldata secret)
        external onlyDuringPhase(Phase.Reveal) nonReentrant {
        require(vote == 0 || vote == 1, "vote 0/1");
        CommitInfo storage info = commits[msg.sender];
        require(info.commitHash != bytes32(0), "no commit");
        require(!info.revealed, "already revealed");
        require(weight > 0, "weight>0");

        // Recreate commit hash (must match exact commit hash enconding
        bytes32 expected = keccak256(abi.encode(vote, weight, secret, msg.sender));
        require(expected == info.commitHash, "commitment mismatch");
        require(lockedWeight[msg.sender] == weight, "weight mismatch with locked");
            // tokens already held in contract

        // mark revealed and add vote & weight to totals
        info.revealed = true;
        if (vote == 1) totalYesWeight += weight;
        else totalNoWeight += weight;
        totalRevealedWeight += weight;

        // attempt to refund deposit immediately
        uint256 dep = deposits[msg.sender];
        bool refunded = false;
        if (dep > 0) {
            // zero-out deposit first to avoid reentrancy issues
            deposits[msg.sender] = 0;
            (bool sent, ) = msg.sender.call{value: dep}("");
            if (sent) {
                refunded = true;
                emit DepositRefunded(msg.sender, dep);
            } else {
                // failed to send -> restore deposit mapping so user can claim later
                deposits[msg.sender] = dep;
                emit DepositPendingRefund(msg.sender, dep);
            }
        }

        emit Revealed(msg.sender, vote, weight, refunded);
    }

    //  Claim refund (if automatic refund failed or admin hasn't slashed)
    function claimRefund() external nonReentrant {
        CommitInfo storage info = commits[msg.sender];
        require(info.commitHash != bytes32(0), "no commit");
        require(info.revealed, "not revealed");
        uint256 dep = deposits[msg.sender];
        require(dep > 0, "no deposit");
        deposits[msg.sender] = 0;
        (bool sent,) = msg.sender.call{value: dep}("");
        require(sent, "refund failed");
        emit DepositRefunded(msg.sender, dep);
    }

    // Admin utility: slash unrevealed commits (after Finished) 
    // Admin provides list of voter addresses to slash. For each:
    // - if they committed but did not reveal: transfer their deposit to `to` and transfer any locked tokens to `to`.
    // - clears their stored state so funds can't be double-slashed.
    function adminSlashUnrevealed(address[] calldata voters, address to) external onlyAdmin nonReentrant {
        require(currentPhase() == Phase.Finished, "not finished");
        require(to != address(0), "zero to");
        for (uint i = 0; i < voters.length; i++) {
            address voter = voters[i];
            CommitInfo storage info = commits[voter];
            if (info.commitHash == bytes32(0)) continue; // no commit
            if (info.revealed) continue; // already revealed so skip

            // slash deposit
            uint256 dep = deposits[voter];
            if (dep > 0) {
                deposits[voter] = 0;
                (bool sent,) = to.call{value: dep}("");
                if (sent) {
                    emit DepositSlashed(voter, dep, to);
                } else {
                    // if sending ETH to `to` fails, restore deposit for admin to try later
                    deposits[voter] = dep;
                }
            }

            // slash tokens locked at commit (if any)
            uint256 lw = lockedWeight[voter];
            if (lw > 0) {
                lockedWeight[voter] = 0;
                bool ok = votingToken.transfer(to, lw);
                if (ok) {
                    emit TokensSlashed(voter, lw, to);
                } else {
                    // if token transfer fails, attempt no further action (admin must handle)
                }
            }

            // clear commit so it can't be used later
            delete commits[voter];
        }
    }

    //  Get results:
    // returns 0 if No is greater, 1 if Yes is greater, 2 for a Tie (equal)
    function winningOutcome() external view returns (uint8) {
        if (totalYesWeight > totalNoWeight) return 1;
        if (totalNoWeight > totalYesWeight) return 0;
        return 2;
    }

    function yesVotes() external view returns (uint256) { return totalYesWeight; }
    function noVotes() external view returns (uint256) { return totalNoWeight; }

    // Admin helper: Admin can withdraw tokens or stuck ETH after voting finished if necessary.
    function adminWithdrawTokens(address to, uint256 amount) external onlyAdmin nonReentrant {
        require(currentPhase() == Phase.Finished, "not finished");
        require(to != address(0), "zero to");
        bool ok = votingToken.transfer(to, amount);
        require(ok, "token transfer failed");
    }

    function adminWithdrawETH(address payable to, uint256 amount) external onlyAdmin nonReentrant {
        require(currentPhase() == Phase.Finished, "not finished");
        require(to != address(0), "zero to");
        (bool sent,) = to.call{value: amount}("");
        require(sent, "eth transfer failed");
    }

   
}
