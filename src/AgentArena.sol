// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IERC165 {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

interface IACPHook is IERC165 {
    function beforeAction(uint256 jobId, bytes4 selector, bytes calldata data) external;
    function afterAction(uint256 jobId, bytes4 selector, bytes calldata data) external;
}

/// @title AgentArena -- ERC-8183 compliant agent commerce
/// @notice Two-job competitive arena built on ERC-8183 primitives.
///         Aligned with the official erc-8183/base-contracts reference implementation.
contract AgentArena {
    using SafeERC20 for IERC20;

    // --- ERC-8183 State Machine ---
    // Open -> Funded -> Submitted -> Completed | Rejected | Expired
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
    address public admin;

    uint256 public jobCount;
    uint256 public battleCount;

    mapping(uint256 => Job) public jobs;
    mapping(uint256 => Battle) public battles;
    mapping(uint256 => uint256) public jobToBattle;

    // --- Fee Infrastructure ---
    uint256 public platformFeeBP;
    uint256 public evaluatorFeeBP;
    address public platformTreasury;

    // --- Hook Whitelisting ---
    mapping(address => bool) public whitelistedHooks;

    // --- Reentrancy Guard ---
    uint256 private _locked = 1;
    modifier nonReentrant() {
        require(_locked == 1, "REENTRANCY");
        _locked = 2;
        _;
        _locked = 1;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAuthorized();
        _;
    }

    // --- ERC-8183 Events ---
    event JobCreated(uint256 indexed jobId, address indexed client, address indexed provider, address evaluator, uint256 expiredAt, address hook);
    event ProviderSet(uint256 indexed jobId, address indexed provider, uint256 agentId);
    event BudgetSet(uint256 indexed jobId, uint256 amount);
    event JobFunded(uint256 indexed jobId, address indexed client, uint256 amount);
    event JobSubmitted(uint256 indexed jobId, address indexed provider, bytes32 deliverable);
    event JobCompleted(uint256 indexed jobId, address indexed evaluator, bytes32 reason);
    event JobRejected(uint256 indexed jobId, address indexed rejector, bytes32 reason);
    event JobExpired(uint256 indexed jobId);
    event PaymentReleased(uint256 indexed jobId, address indexed provider, uint256 amount);
    event Refunded(uint256 indexed jobId, address indexed client, uint256 amount);

    // --- Fee Events ---
    event PlatformFeePaid(uint256 indexed jobId, address indexed treasury, uint256 amount);
    event EvaluatorFeePaid(uint256 indexed jobId, address indexed evaluator, uint256 amount);
    event PlatformFeeSet(uint256 feeBP, address treasury);
    event EvaluatorFeeSet(uint256 feeBP);

    // --- Hook Events ---
    event HookWhitelistUpdated(address indexed hook, bool status);

    // --- Arena Events ---
    event BattleCreated(uint256 indexed battleId, uint256 jobIdA, uint256 jobIdB, address indexed client, address indexed evaluator, uint256 totalBudget);
    event BattleResolved(uint256 indexed battleId, uint256 winnerJobId, uint256 loserJobId, bytes32 reason);

    // --- Errors ---
    error ZeroAddress();
    error ZeroBudget();
    error ExpiryTooShort();
    error InvalidDeliverable();
    error SameProvider();
    error InvalidJob();
    error NotAuthorized();
    error InvalidStatus();
    error NotExpired();
    error AlreadyExpired();
    error BudgetMismatch();
    error ProviderAlreadySet();
    error ProviderNotSet();
    error BattleAlreadyResolved();
    error HookNotSupported();
    error HookNotWhitelisted();
    error FeesTooHigh();
    error JobInBattle();

    constructor(address _paymentToken) {
        if (_paymentToken == address(0)) revert ZeroAddress();
        paymentToken = IERC20(_paymentToken);
        admin = msg.sender;
        whitelistedHooks[address(0)] = true; // no-hook always allowed
    }

    // ===================================================
    //  ERC-8183 Core Functions (with optParams)
    // ===================================================

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
        if (evaluator == address(0)) revert ZeroAddress();
        if (expiredAt <= block.timestamp + 5 minutes) revert ExpiryTooShort();
        if (!whitelistedHooks[hook]) revert HookNotWhitelisted();
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

        emit JobCreated(jobId, msg.sender, provider, evaluator, expiredAt, hook);
    }

    /// @notice Set provider on an Open job (when created with provider=address(0)).
    /// @param agentId ERC-8004 agent identity for the provider
    function setProvider(uint256 jobId, address provider, uint256 agentId, bytes calldata optParams) external {
        _validateJob(jobId);
        Job storage j = jobs[jobId];
        if (j.status != Status.Open) revert InvalidStatus();
        if (msg.sender != j.client) revert NotAuthorized();
        if (j.provider != address(0)) revert ProviderAlreadySet();
        if (provider == address(0)) revert ZeroAddress();

        _beforeHook(jobId, this.setProvider.selector, abi.encode(provider, optParams));

        j.provider = provider;
        j.providerAgentId = agentId;
        emit ProviderSet(jobId, provider, agentId);

        _afterHook(jobId, this.setProvider.selector, abi.encode(provider, optParams));
    }

    /// @notice Set or update budget on an Open job. Client or provider.
    function setBudget(uint256 jobId, uint256 amount, bytes calldata optParams) external {
        _validateJob(jobId);
        Job storage j = jobs[jobId];
        if (j.status != Status.Open) revert InvalidStatus();
        if (msg.sender != j.client && msg.sender != j.provider) revert NotAuthorized();
        if (amount == 0) revert ZeroBudget();

        _beforeHook(jobId, this.setBudget.selector, abi.encode(amount, optParams));

        j.budget = amount;
        emit BudgetSet(jobId, amount);

        _afterHook(jobId, this.setBudget.selector, abi.encode(amount, optParams));
    }

    /// @dev Internal fund logic (no calldata restriction for internal calls)
    function _fund(uint256 jobId, uint256 expectedBudget) internal {
        Job storage j = jobs[jobId];
        if (j.status != Status.Open) revert InvalidStatus();
        if (msg.sender != j.client) revert NotAuthorized();
        if (j.provider == address(0)) revert ProviderNotSet();
        if (j.budget == 0) revert ZeroBudget();
        if (j.budget != expectedBudget) revert BudgetMismatch();
        if (block.timestamp >= j.expiredAt) revert AlreadyExpired();

        j.status = Status.Funded;

        paymentToken.safeTransferFrom(msg.sender, address(this), j.budget);

        emit JobFunded(jobId, msg.sender, j.budget);
    }

    /// @notice Fund an Open job. Pulls budget from client into escrow.
    function fund(uint256 jobId, uint256 expectedBudget, bytes calldata optParams) external nonReentrant {
        _validateJob(jobId);
        _beforeHook(jobId, this.fund.selector, optParams);
        _fund(jobId, expectedBudget);
        _afterHook(jobId, this.fund.selector, optParams);
    }

    /// @notice Provider submits deliverable on a Funded job.
    function submit(uint256 jobId, bytes32 deliverable, bytes calldata optParams) external nonReentrant {
        _validateJob(jobId);
        Job storage j = jobs[jobId];
        if (j.status != Status.Funded) revert InvalidStatus();
        if (msg.sender != j.provider) revert NotAuthorized();
        if (block.timestamp >= j.expiredAt) revert AlreadyExpired();
        if (deliverable == bytes32(0)) revert InvalidDeliverable();

        _beforeHook(jobId, this.submit.selector, abi.encode(deliverable, optParams));

        j.deliverable = deliverable;
        j.status = Status.Submitted;

        emit JobSubmitted(jobId, msg.sender, deliverable);

        _afterHook(jobId, this.submit.selector, abi.encode(deliverable, optParams));
    }

    /// @notice Evaluator completes a Submitted job. Pays provider (minus fees).
    function complete(uint256 jobId, bytes32 reason, bytes calldata optParams) public nonReentrant {
        _validateJob(jobId);
        if (jobToBattle[jobId] != 0) revert JobInBattle();
        Job storage j = jobs[jobId];
        if (j.status != Status.Submitted) revert InvalidStatus();
        if (msg.sender != j.evaluator) revert NotAuthorized();

        _beforeHook(jobId, this.complete.selector, abi.encode(reason, optParams));

        j.status = Status.Completed;

        _distributePayment(jobId, j.provider, j.evaluator, j.budget);

        emit JobCompleted(jobId, msg.sender, reason);

        _afterHook(jobId, this.complete.selector, abi.encode(reason, optParams));
    }

    /// @notice Reject a job. Client when Open, evaluator when Funded/Submitted.
    function reject(uint256 jobId, bytes32 reason, bytes calldata optParams) public nonReentrant {
        _validateJob(jobId);
        if (jobToBattle[jobId] != 0) revert JobInBattle();
        Job storage j = jobs[jobId];

        if (j.status == Status.Open) {
            if (msg.sender != j.client) revert NotAuthorized();
        } else if (j.status == Status.Funded || j.status == Status.Submitted) {
            if (msg.sender != j.evaluator) revert NotAuthorized();
        } else {
            revert InvalidStatus();
        }

        _beforeHook(jobId, this.reject.selector, abi.encode(reason, optParams));

        if (j.status == Status.Funded || j.status == Status.Submitted) {
            paymentToken.safeTransfer(j.client, j.budget);
            emit Refunded(jobId, j.client, j.budget);
        }

        j.status = Status.Rejected;
        emit JobRejected(jobId, msg.sender, reason);

        _afterHook(jobId, this.reject.selector, abi.encode(reason, optParams));
    }

    /// @notice Refund expired job. Anyone can call after expiry. Not hookable by design.
    function claimRefund(uint256 jobId) external nonReentrant {
        _validateJob(jobId);
        Job storage j = jobs[jobId];
        if (j.status != Status.Funded && j.status != Status.Submitted) revert InvalidStatus();
        if (block.timestamp < j.expiredAt) revert NotExpired();

        j.status = Status.Expired;

        paymentToken.safeTransfer(j.client, j.budget);

        emit JobExpired(jobId);
        emit Refunded(jobId, j.client, j.budget);
    }

    // ===================================================
    //  Arena Extension: Competitive Battles
    // ===================================================

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
        if (providerA == address(0) || providerB == address(0)) revert ZeroAddress();
        if (providerA == providerB) revert SameProvider();
        if (totalBudget == 0) revert ZeroBudget();

        uint256 halfBudget = totalBudget / 2;
        if (halfBudget == 0) revert ZeroBudget();
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

    /// @notice Evaluator resolves a battle. Winner takes full prize (minus fees).
    function resolveBattle(
        uint256 battleId,
        uint256 winnerJobId,
        bytes32 reason
    ) external nonReentrant {
        Battle storage b = battles[battleId];
        if (b.resolved) revert BattleAlreadyResolved();
        if (b.client == address(0)) revert InvalidJob();
        if (msg.sender != b.evaluator) revert NotAuthorized();

        uint256 loserJobId;
        if (winnerJobId == b.jobIdA) {
            loserJobId = b.jobIdB;
        } else if (winnerJobId == b.jobIdB) {
            loserJobId = b.jobIdA;
        } else {
            revert InvalidJob();
        }

        Job storage winner = jobs[winnerJobId];
        Job storage loser = jobs[loserJobId];

        if (winner.status != Status.Submitted) revert InvalidStatus();
        if (loser.status != Status.Submitted) revert InvalidStatus();

        b.resolved = true;

        // Call hooks on winner (complete) and loser (reject)
        bytes memory completeData = abi.encode(reason, "");
        bytes memory rejectData = abi.encode(reason, "");

        _beforeHook(winnerJobId, this.complete.selector, completeData);
        _beforeHook(loserJobId, this.reject.selector, rejectData);

        winner.status = Status.Completed;
        emit JobCompleted(winnerJobId, msg.sender, reason);

        loser.status = Status.Rejected;
        emit JobRejected(loserJobId, msg.sender, reason);

        _distributePayment(winnerJobId, winner.provider, winner.evaluator, b.totalBudget);

        emit BattleResolved(battleId, winnerJobId, loserJobId, reason);

        _afterHook(winnerJobId, this.complete.selector, completeData);
        _afterHook(loserJobId, this.reject.selector, rejectData);
    }

    // ===================================================
    //  Admin Functions
    // ===================================================

    function setPlatformFee(uint256 feeBP, address treasury) external onlyAdmin {
        if (treasury == address(0) && feeBP > 0) revert ZeroAddress();
        if (feeBP + evaluatorFeeBP > 10000) revert FeesTooHigh();
        platformFeeBP = feeBP;
        platformTreasury = treasury;
        emit PlatformFeeSet(feeBP, treasury);
    }

    function setEvaluatorFee(uint256 feeBP) external onlyAdmin {
        if (feeBP + platformFeeBP > 10000) revert FeesTooHigh();
        evaluatorFeeBP = feeBP;
        emit EvaluatorFeeSet(feeBP);
    }

    function setHookWhitelist(address hook, bool status) external onlyAdmin {
        whitelistedHooks[hook] = status;
        emit HookWhitelistUpdated(hook, status);
    }

    // ===================================================
    //  Internal Helpers
    // ===================================================

    function _validateJob(uint256 jobId) internal view {
        if (jobId == 0 || jobId > jobCount) revert InvalidJob();
    }

    function _distributePayment(uint256 jobId, address provider, address evaluator, uint256 amount) internal {
        uint256 platformFee = (amount * platformFeeBP) / 10000;
        uint256 evalFee = (amount * evaluatorFeeBP) / 10000;
        uint256 netPayment = amount - platformFee - evalFee;

        if (platformFee > 0) {
            paymentToken.safeTransfer(platformTreasury, platformFee);
            emit PlatformFeePaid(jobId, platformTreasury, platformFee);
        }
        if (evalFee > 0) {
            paymentToken.safeTransfer(evaluator, evalFee);
            emit EvaluatorFeePaid(jobId, evaluator, evalFee);
        }

        paymentToken.safeTransfer(provider, netPayment);
        emit PaymentReleased(jobId, provider, netPayment);
    }

    // --- Hook Helpers ---

    function _beforeHook(uint256 jobId, bytes4 selector, bytes memory data) internal {
        address hookAddr = jobs[jobId].hook;
        if (hookAddr == address(0)) return;
        IACPHook(hookAddr).beforeAction{gas: 500_000}(jobId, selector, data);
    }

    function _afterHook(uint256 jobId, bytes4 selector, bytes memory data) internal {
        address hookAddr = jobs[jobId].hook;
        if (hookAddr == address(0)) return;
        IACPHook(hookAddr).afterAction{gas: 500_000}(jobId, selector, data);
    }

    // ===================================================
    //  View Helpers
    // ===================================================

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
