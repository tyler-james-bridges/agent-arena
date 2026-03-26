// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @title AgentArena — ERC-8183 compliant agent commerce
/// @notice Two-job competitive arena built on ERC-8183 primitives.
///         Aligned with the official erc-8183/base-contracts reference implementation.
contract AgentArena {
    // ─── ERC-8183 State Machine ───
    // Open → Funded → Submitted → Completed | Rejected | Expired
    enum Status {
        Open,
        Funded,
        Submitted,
        Completed,
        Rejected,
        Expired
    }

    struct Job {
        address client;
        address provider;
        address evaluator;
        uint256 budget;
        uint256 expiredAt;
        string description;
        bytes32 deliverable;
        Status status;
        uint256 providerAgentId; // ERC-8004 agent identity
    }

    struct Battle {
        uint256 jobIdA;
        uint256 jobIdB;
        address client;
        address evaluator;
        uint256 totalBudget;
        bool resolved;
    }

    IERC20 public immutable paymentToken;

    uint256 public jobCount;
    uint256 public battleCount;

    mapping(uint256 => Job) public jobs;
    mapping(uint256 => Battle) public battles;
    mapping(uint256 => uint256) public jobToBattle;

    // ─── Reentrancy Guard ───
    uint256 private _locked = 1;
    modifier nonReentrant() {
        require(_locked == 1, "REENTRANCY");
        _locked = 2;
        _;
        _locked = 1;
    }

    // ─── ERC-8183 Events ───
    event JobCreated(uint256 indexed jobId, address indexed client, address provider, address evaluator, uint256 budget, uint256 expiredAt, string description);
    event ProviderSet(uint256 indexed jobId, address indexed provider, uint256 agentId);
    event BudgetSet(uint256 indexed jobId, uint256 amount);
    event JobFunded(uint256 indexed jobId, address indexed client, uint256 amount);
    event JobSubmitted(uint256 indexed jobId, address indexed provider, bytes32 deliverable);
    event JobCompleted(uint256 indexed jobId, address indexed evaluator, bytes32 reason);
    event JobRejected(uint256 indexed jobId, address indexed rejector, bytes32 reason);
    event JobExpired(uint256 indexed jobId);

    // ─── Arena Events ───
    event BattleCreated(uint256 indexed battleId, uint256 jobIdA, uint256 jobIdB, address indexed client, address indexed evaluator, uint256 totalBudget);
    event BattleResolved(uint256 indexed battleId, uint256 winnerJobId, uint256 loserJobId, bytes32 reason);

    // ─── Errors ───
    error InvalidInput();
    error NotAuthorized();
    error InvalidStatus();
    error NotExpired();
    error AlreadyExpired();
    error BudgetMismatch();
    error ProviderAlreadySet();
    error ProviderNotSet();
    error BattleAlreadyResolved();

    constructor(address _paymentToken) {
        if (_paymentToken == address(0)) revert InvalidInput();
        paymentToken = IERC20(_paymentToken);
    }

    // ═══════════════════════════════════════════════════
    //  ERC-8183 Core Functions (with optParams)
    // ═══════════════════════════════════════════════════

    /// @notice Create a job. Provider may be zero (set later via setProvider).
    /// @param providerAgentId Optional ERC-8004 agent ID for the provider
    function createJob(
        address provider,
        address evaluator,
        uint256 budget,
        uint256 expiredAt,
        string calldata description,
        uint256 providerAgentId
    ) public returns (uint256 jobId) {
        if (evaluator == address(0)) revert InvalidInput();
        if (expiredAt <= block.timestamp) revert InvalidInput();
        if (budget == 0) revert InvalidInput();

        jobId = ++jobCount;
        Job storage j = jobs[jobId];
        j.client = msg.sender;
        j.provider = provider;
        j.evaluator = evaluator;
        j.budget = budget;
        j.expiredAt = expiredAt;
        j.description = description;
        j.status = Status.Open;
        j.providerAgentId = provider != address(0) ? providerAgentId : 0;

        emit JobCreated(jobId, msg.sender, provider, evaluator, budget, expiredAt, description);
    }

    /// @notice Set provider on an Open job (when created with provider=address(0)).
    /// @param agentId ERC-8004 agent identity for the provider
    function setProvider(uint256 jobId, address provider, uint256 agentId, bytes calldata /* optParams */) external {
        Job storage j = jobs[jobId];
        if (j.status != Status.Open) revert InvalidStatus();
        if (msg.sender != j.client) revert NotAuthorized();
        if (j.provider != address(0)) revert ProviderAlreadySet();
        if (provider == address(0)) revert InvalidInput();

        j.provider = provider;
        j.providerAgentId = agentId;
        emit ProviderSet(jobId, provider, agentId);
    }

    /// @notice Set or update budget on an Open job. Client or provider.
    function setBudget(uint256 jobId, uint256 amount, bytes calldata /* optParams */) external {
        Job storage j = jobs[jobId];
        if (j.status != Status.Open) revert InvalidStatus();
        if (msg.sender != j.client && msg.sender != j.provider) revert NotAuthorized();
        if (amount == 0) revert InvalidInput();

        j.budget = amount;
        emit BudgetSet(jobId, amount);
    }

    /// @dev Internal fund logic (no calldata restriction for internal calls)
    function _fund(uint256 jobId, uint256 expectedBudget) internal {
        Job storage j = jobs[jobId];
        if (j.status != Status.Open) revert InvalidStatus();
        if (msg.sender != j.client) revert NotAuthorized();
        if (j.provider == address(0)) revert ProviderNotSet();
        if (j.budget != expectedBudget) revert BudgetMismatch();
        if (block.timestamp >= j.expiredAt) revert AlreadyExpired();

        j.status = Status.Funded;

        bool ok = paymentToken.transferFrom(msg.sender, address(this), j.budget);
        require(ok, "TRANSFER_FAILED");

        emit JobFunded(jobId, msg.sender, j.budget);
    }

    /// @notice Fund an Open job. Pulls budget from client into escrow.
    function fund(uint256 jobId, uint256 expectedBudget, bytes calldata /* optParams */) external nonReentrant {
        _fund(jobId, expectedBudget);
    }

    /// @notice Provider submits deliverable on a Funded job.
    function submit(uint256 jobId, bytes32 deliverable, bytes calldata /* optParams */) external nonReentrant {
        Job storage j = jobs[jobId];
        if (j.status != Status.Funded) revert InvalidStatus();
        if (msg.sender != j.provider) revert NotAuthorized();
        if (block.timestamp >= j.expiredAt) revert AlreadyExpired();
        if (deliverable == bytes32(0)) revert InvalidInput();

        j.deliverable = deliverable;
        j.status = Status.Submitted;

        emit JobSubmitted(jobId, msg.sender, deliverable);
    }

    /// @notice Evaluator completes a Submitted job. Pays provider.
    function complete(uint256 jobId, bytes32 reason, bytes calldata /* optParams */) public nonReentrant {
        Job storage j = jobs[jobId];
        if (j.status != Status.Submitted) revert InvalidStatus();
        if (msg.sender != j.evaluator) revert NotAuthorized();

        j.status = Status.Completed;

        bool ok = paymentToken.transfer(j.provider, j.budget);
        require(ok, "TRANSFER_FAILED");

        emit JobCompleted(jobId, msg.sender, reason);
    }

    /// @notice Reject a job. Client when Open, evaluator when Funded/Submitted.
    function reject(uint256 jobId, bytes32 reason, bytes calldata /* optParams */) public nonReentrant {
        Job storage j = jobs[jobId];

        if (j.status == Status.Open) {
            if (msg.sender != j.client) revert NotAuthorized();
        } else if (j.status == Status.Funded || j.status == Status.Submitted) {
            if (msg.sender != j.evaluator) revert NotAuthorized();
            bool ok = paymentToken.transfer(j.client, j.budget);
            require(ok, "TRANSFER_FAILED");
        } else {
            revert InvalidStatus();
        }

        j.status = Status.Rejected;
        emit JobRejected(jobId, msg.sender, reason);
    }

    /// @notice Refund expired job. Anyone can call after expiry.
    function claimRefund(uint256 jobId) external nonReentrant {
        Job storage j = jobs[jobId];
        if (j.status != Status.Funded && j.status != Status.Submitted) revert InvalidStatus();
        if (block.timestamp < j.expiredAt) revert NotExpired();

        j.status = Status.Expired;

        bool ok = paymentToken.transfer(j.client, j.budget);
        require(ok, "TRANSFER_FAILED");

        emit JobExpired(jobId);
    }

    // ═══════════════════════════════════════════════════
    //  Arena Extension: Competitive Battles
    // ═══════════════════════════════════════════════════

    /// @notice Create a battle: two paired ERC-8183 jobs. Winner takes all.
    /// @param agentIdA ERC-8004 agent ID for provider A
    /// @param agentIdB ERC-8004 agent ID for provider B
    function createBattle(
        address providerA,
        address providerB,
        address evaluator,
        uint256 totalBudget,
        uint256 expiredAt,
        string calldata description,
        uint256 agentIdA,
        uint256 agentIdB
    ) external nonReentrant returns (uint256 battleId, uint256 jobIdA, uint256 jobIdB) {
        if (providerA == address(0) || providerB == address(0)) revert InvalidInput();
        if (providerA == providerB) revert InvalidInput();
        if (totalBudget == 0) revert InvalidInput();

        uint256 halfBudget = totalBudget / 2;
        if (halfBudget == 0) revert InvalidInput();
        uint256 actualTotal = halfBudget * 2;

        // Create two standard ERC-8183 jobs with ERC-8004 agent IDs
        jobIdA = createJob(providerA, evaluator, halfBudget, expiredAt, description, agentIdA);
        jobIdB = createJob(providerB, evaluator, halfBudget, expiredAt, description, agentIdB);

        // Fund both (pulls actualTotal from client)
        _fund(jobIdA, halfBudget);
        _fund(jobIdB, halfBudget);

        battleId = ++battleCount;
        Battle storage b = battles[battleId];
        b.jobIdA = jobIdA;
        b.jobIdB = jobIdB;
        b.client = msg.sender;
        b.evaluator = evaluator;
        b.totalBudget = actualTotal;

        jobToBattle[jobIdA] = battleId;
        jobToBattle[jobIdB] = battleId;

        emit BattleCreated(battleId, jobIdA, jobIdB, msg.sender, evaluator, actualTotal);
    }

    /// @notice Evaluator resolves a battle. Winner takes full prize.
    function resolveBattle(
        uint256 battleId,
        uint256 winnerJobId,
        bytes32 reason
    ) external nonReentrant {
        Battle storage b = battles[battleId];
        if (b.resolved) revert BattleAlreadyResolved();
        if (b.client == address(0)) revert InvalidInput();
        if (msg.sender != b.evaluator) revert NotAuthorized();

        uint256 loserJobId;
        if (winnerJobId == b.jobIdA) {
            loserJobId = b.jobIdB;
        } else if (winnerJobId == b.jobIdB) {
            loserJobId = b.jobIdA;
        } else {
            revert InvalidInput();
        }

        Job storage winner = jobs[winnerJobId];
        Job storage loser = jobs[loserJobId];

        if (winner.status != Status.Submitted) revert InvalidStatus();
        if (loser.status != Status.Submitted) revert InvalidStatus();

        b.resolved = true;

        winner.status = Status.Completed;
        emit JobCompleted(winnerJobId, msg.sender, reason);

        loser.status = Status.Rejected;
        emit JobRejected(loserJobId, msg.sender, reason);

        bool ok = paymentToken.transfer(winner.provider, b.totalBudget);
        require(ok, "TRANSFER_FAILED");

        emit BattleResolved(battleId, winnerJobId, loserJobId, reason);
    }

    // ═══════════════════════════════════════════════════
    //  View Helpers
    // ═══════════════════════════════════════════════════

    function getJob(uint256 jobId) external view returns (
        address client,
        address provider,
        address evaluator,
        uint256 budget,
        uint256 expiredAt,
        string memory description,
        bytes32 deliverable,
        Status status,
        uint256 providerAgentId
    ) {
        Job storage j = jobs[jobId];
        return (j.client, j.provider, j.evaluator, j.budget, j.expiredAt, j.description, j.deliverable, j.status, j.providerAgentId);
    }

    function getBattle(uint256 battleId) external view returns (
        uint256 jobIdA,
        uint256 jobIdB,
        address client,
        address evaluator,
        uint256 totalBudget,
        bool resolved
    ) {
        Battle storage b = battles[battleId];
        return (b.jobIdA, b.jobIdB, b.client, b.evaluator, b.totalBudget, b.resolved);
    }
}
