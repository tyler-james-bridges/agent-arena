// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

interface IERC165 {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

interface IACPHook is IERC165 {
    function beforeAction(uint256 jobId, bytes4 selector, bytes calldata data) external;
    function afterAction(uint256 jobId, bytes4 selector, bytes calldata data) external;
}

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
        address hook; // ERC-8183 ACP hook
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
    event JobCreated(uint256 indexed jobId, address indexed client, address provider, address evaluator, uint256 budget, uint256 expiredAt, string description, address hook);
    event ProviderSet(uint256 indexed jobId, address indexed provider, uint256 agentId);
    event BudgetSet(uint256 indexed jobId, uint256 amount);
    event JobFunded(uint256 indexed jobId, address indexed client, uint256 amount);
    event JobSubmitted(uint256 indexed jobId, address indexed provider, bytes32 deliverable);
    event JobCompleted(uint256 indexed jobId, address indexed evaluator, bytes32 reason);
    event JobRejected(uint256 indexed jobId, address indexed rejector, bytes32 reason);
    event JobExpired(uint256 indexed jobId);
    event PaymentReleased(uint256 indexed jobId, address indexed provider, uint256 amount);
    event Refunded(uint256 indexed jobId, address indexed client, uint256 amount);

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
    error HookNotSupported();

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
        uint256 providerAgentId,
        address hook
    ) public returns (uint256 jobId) {
        if (evaluator == address(0)) revert InvalidInput();
        if (expiredAt <= block.timestamp) revert InvalidInput();
        if (budget == 0) revert InvalidInput();
        if (hook != address(0)) {
            if (!IERC165(hook).supportsInterface(type(IACPHook).interfaceId)) revert HookNotSupported();
        }

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
        j.hook = hook;

        emit JobCreated(jobId, msg.sender, provider, evaluator, budget, expiredAt, description, hook);
    }

    /// @notice Set provider on an Open job (when created with provider=address(0)).
    /// @param agentId ERC-8004 agent identity for the provider
    function setProvider(uint256 jobId, address provider, uint256 agentId, bytes calldata optParams) external {
        Job storage j = jobs[jobId];
        if (j.status != Status.Open) revert InvalidStatus();
        if (msg.sender != j.client) revert NotAuthorized();
        if (j.provider != address(0)) revert ProviderAlreadySet();
        if (provider == address(0)) revert InvalidInput();

        _beforeHook(jobId, this.setProvider.selector, optParams);

        j.provider = provider;
        j.providerAgentId = agentId;
        emit ProviderSet(jobId, provider, agentId);

        _afterHook(jobId, this.setProvider.selector, optParams);
    }

    /// @notice Set or update budget on an Open job. Client or provider.
    function setBudget(uint256 jobId, uint256 amount, bytes calldata optParams) external {
        Job storage j = jobs[jobId];
        if (j.status != Status.Open) revert InvalidStatus();
        if (msg.sender != j.client && msg.sender != j.provider) revert NotAuthorized();
        if (amount == 0) revert InvalidInput();

        _beforeHook(jobId, this.setBudget.selector, optParams);

        j.budget = amount;
        emit BudgetSet(jobId, amount);

        _afterHook(jobId, this.setBudget.selector, optParams);
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

        _safeTransferFrom(msg.sender, address(this), j.budget);

        emit JobFunded(jobId, msg.sender, j.budget);
    }

    /// @notice Fund an Open job. Pulls budget from client into escrow.
    function fund(uint256 jobId, uint256 expectedBudget, bytes calldata optParams) external nonReentrant {
        _beforeHook(jobId, this.fund.selector, optParams);
        _fund(jobId, expectedBudget);
        _afterHook(jobId, this.fund.selector, optParams);
    }

    /// @notice Provider submits deliverable on a Funded job.
    function submit(uint256 jobId, bytes32 deliverable, bytes calldata optParams) external nonReentrant {
        Job storage j = jobs[jobId];
        if (j.status != Status.Funded) revert InvalidStatus();
        if (msg.sender != j.provider) revert NotAuthorized();
        if (block.timestamp >= j.expiredAt) revert AlreadyExpired();
        if (deliverable == bytes32(0)) revert InvalidInput();

        _beforeHook(jobId, this.submit.selector, optParams);

        j.deliverable = deliverable;
        j.status = Status.Submitted;

        emit JobSubmitted(jobId, msg.sender, deliverable);

        _afterHook(jobId, this.submit.selector, optParams);
    }

    /// @notice Evaluator completes a Submitted job. Pays provider.
    function complete(uint256 jobId, bytes32 reason, bytes calldata optParams) public nonReentrant {
        Job storage j = jobs[jobId];
        if (j.status != Status.Submitted) revert InvalidStatus();
        if (msg.sender != j.evaluator) revert NotAuthorized();

        _beforeHook(jobId, this.complete.selector, optParams);

        j.status = Status.Completed;

        _safeTransfer(j.provider, j.budget);

        emit JobCompleted(jobId, msg.sender, reason);
        emit PaymentReleased(jobId, j.provider, j.budget);

        _afterHook(jobId, this.complete.selector, optParams);
    }

    /// @notice Reject a job. Client when Open, evaluator when Funded/Submitted.
    function reject(uint256 jobId, bytes32 reason, bytes calldata optParams) public nonReentrant {
        Job storage j = jobs[jobId];

        if (j.status == Status.Open) {
            if (msg.sender != j.client) revert NotAuthorized();
        } else if (j.status == Status.Funded || j.status == Status.Submitted) {
            if (msg.sender != j.evaluator) revert NotAuthorized();
        } else {
            revert InvalidStatus();
        }

        _beforeHook(jobId, this.reject.selector, optParams);

        if (j.status == Status.Funded || j.status == Status.Submitted) {
            _safeTransfer(j.client, j.budget);
            emit Refunded(jobId, j.client, j.budget);
        }

        j.status = Status.Rejected;
        emit JobRejected(jobId, msg.sender, reason);

        _afterHook(jobId, this.reject.selector, optParams);
    }

    /// @notice Refund expired job. Anyone can call after expiry. Not hookable by design.
    function claimRefund(uint256 jobId) external nonReentrant {
        Job storage j = jobs[jobId];
        if (j.status != Status.Funded && j.status != Status.Submitted) revert InvalidStatus();
        if (block.timestamp < j.expiredAt) revert NotExpired();

        j.status = Status.Expired;

        _safeTransfer(j.client, j.budget);

        emit JobExpired(jobId);
        emit Refunded(jobId, j.client, j.budget);
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
        uint256 agentIdB,
        address hook
    ) external nonReentrant returns (uint256 battleId, uint256 jobIdA, uint256 jobIdB) {
        if (providerA == address(0) || providerB == address(0)) revert InvalidInput();
        if (providerA == providerB) revert InvalidInput();
        if (totalBudget == 0) revert InvalidInput();

        uint256 halfBudget = totalBudget / 2;
        if (halfBudget == 0) revert InvalidInput();
        uint256 actualTotal = halfBudget * 2;

        // Create two standard ERC-8183 jobs with ERC-8004 agent IDs
        jobIdA = createJob(providerA, evaluator, halfBudget, expiredAt, description, agentIdA, hook);
        jobIdB = createJob(providerB, evaluator, halfBudget, expiredAt, description, agentIdB, hook);

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

        _safeTransfer(winner.provider, b.totalBudget);

        emit PaymentReleased(winnerJobId, winner.provider, b.totalBudget);
        emit BattleResolved(battleId, winnerJobId, loserJobId, reason);
    }

    // ═══════════════════════════════════════════════════
    //  Hook Helpers
    // ═══════════════════════════════════════════════════

    function _beforeHook(uint256 jobId, bytes4 selector, bytes calldata data) internal {
        address hookAddr = jobs[jobId].hook;
        if (hookAddr == address(0)) return;
        IACPHook(hookAddr).beforeAction(jobId, selector, data);
    }

    function _afterHook(uint256 jobId, bytes4 selector, bytes calldata data) internal {
        address hookAddr = jobs[jobId].hook;
        if (hookAddr == address(0)) return;
        IACPHook(hookAddr).afterAction(jobId, selector, data);
    }

    // ═══════════════════════════════════════════════════
    //  Internal Transfer Helpers
    // ═══════════════════════════════════════════════════

    function _safeTransfer(address to, uint256 amount) internal {
        bool ok = paymentToken.transfer(to, amount);
        require(ok, "TRANSFER_FAILED");
    }

    function _safeTransferFrom(address from, address to, uint256 amount) internal {
        bool ok = paymentToken.transferFrom(from, to, amount);
        require(ok, "TRANSFER_FAILED");
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
        uint256 providerAgentId,
        address hook
    ) {
        Job storage j = jobs[jobId];
        return (j.client, j.provider, j.evaluator, j.budget, j.expiredAt, j.description, j.deliverable, j.status, j.providerAgentId, j.hook);
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
