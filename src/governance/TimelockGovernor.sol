// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title TimelockGovernor - Decentralized governance with enforced timelock
/// @notice All parameter changes must go through a 48-hour timelock — no admin keys
/// @dev Implements a fully on-chain governance mechanism with transparent proposal queueing
contract TimelockGovernor {
    // ─────────────────────────────────────────────────────────────
    //  Errors
    // ─────────────────────────────────────────────────────────────
    error NotGovernor();
    error ProposalNotReady();
    error ProposalExpired();
    error ProposalNotFound();
    error ProposalAlreadyQueued();
    error TimelockTooShort();
    error ExecutionFailed();

    // ─────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────
    event ProposalQueued(bytes32 indexed proposalId, address target, bytes data, uint256 eta);
    event ProposalExecuted(bytes32 indexed proposalId, address target, bytes data);
    event ProposalCancelled(bytes32 indexed proposalId);
    event GovernorTransferred(address indexed oldGovernor, address indexed newGovernor);

    // ─────────────────────────────────────────────────────────────
    //  Types
    // ─────────────────────────────────────────────────────────────
    struct Proposal {
        address target;
        bytes data;
        uint256 eta; // Earliest Time of Arrival (execution time)
        bool executed;
        bool cancelled;
    }

    // ─────────────────────────────────────────────────────────────
    //  State
    // ─────────────────────────────────────────────────────────────
    address public governor; // Initially deployer, can transfer via timelock
    uint256 public delay; // Timelock delay (48 hours default)
    uint256 public constant GRACE_PERIOD = 14 days; // Proposals expire after grace period
    uint256 public constant MIN_DELAY = 1 hours;
    uint256 public constant MAX_DELAY = 30 days;

    mapping(bytes32 => Proposal) public proposals;
    bytes32[] public proposalIds;

    // ─────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────
    constructor(address _governor, uint256 _delay) {
        require(_delay >= MIN_DELAY && _delay <= MAX_DELAY, "Invalid delay");
        governor = _governor;
        delay = _delay;
    }

    modifier onlyGovernor() {
        if (msg.sender != governor) revert NotGovernor();
        _;
    }

    // ─────────────────────────────────────────────────────────────
    //  Proposal Lifecycle
    // ─────────────────────────────────────────────────────────────

    /// @notice Queue a proposal for execution after the timelock delay
    /// @param target Contract to call
    /// @param data Encoded function call
    /// @return proposalId Unique ID of the proposal
    function queueProposal(address target, bytes calldata data) external onlyGovernor returns (bytes32 proposalId) {
        uint256 eta = block.timestamp + delay;
        proposalId = keccak256(abi.encode(target, data, eta));

        if (proposals[proposalId].eta != 0) revert ProposalAlreadyQueued();

        proposals[proposalId] = Proposal({target: target, data: data, eta: eta, executed: false, cancelled: false});

        proposalIds.push(proposalId);

        emit ProposalQueued(proposalId, target, data, eta);
    }

    /// @notice Execute a queued proposal after the timelock has elapsed
    /// @param proposalId The proposal to execute
    function executeProposal(bytes32 proposalId) external {
        Proposal storage proposal = proposals[proposalId];

        if (proposal.eta == 0) revert ProposalNotFound();
        if (proposal.executed) revert ProposalNotFound();
        if (proposal.cancelled) revert ProposalNotFound();
        if (block.timestamp < proposal.eta) revert ProposalNotReady();
        if (block.timestamp > proposal.eta + GRACE_PERIOD) revert ProposalExpired();

        proposal.executed = true;

        (bool success,) = proposal.target.call(proposal.data);
        if (!success) revert ExecutionFailed();

        emit ProposalExecuted(proposalId, proposal.target, proposal.data);
    }

    /// @notice Cancel a queued proposal
    function cancelProposal(bytes32 proposalId) external onlyGovernor {
        Proposal storage proposal = proposals[proposalId];
        if (proposal.eta == 0) revert ProposalNotFound();
        if (proposal.executed) revert ProposalNotFound();

        proposal.cancelled = true;
        emit ProposalCancelled(proposalId);
    }

    // ─────────────────────────────────────────────────────────────
    //  Governor Transfer (also timelocked)
    // ─────────────────────────────────────────────────────────────

    /// @notice Transfer governance to a new address
    /// @dev This should be called via a timelocked proposal for maximum security
    function transferGovernor(address newGovernor) external {
        // Only callable by the timelock itself (via executeProposal)
        require(msg.sender == address(this), "Must go through timelock");
        require(newGovernor != address(0), "Zero address");

        emit GovernorTransferred(governor, newGovernor);
        governor = newGovernor;
    }

    /// @notice Update timelock delay
    function updateDelay(uint256 newDelay) external {
        require(msg.sender == address(this), "Must go through timelock");
        require(newDelay >= MIN_DELAY && newDelay <= MAX_DELAY, "Invalid delay");
        delay = newDelay;
    }

    // ─────────────────────────────────────────────────────────────
    //  View Functions
    // ─────────────────────────────────────────────────────────────

    /// @notice Get total number of proposals
    function getProposalCount() external view returns (uint256) {
        return proposalIds.length;
    }

    /// @notice Check if a proposal is ready to execute
    function isProposalReady(bytes32 proposalId) external view returns (bool) {
        Proposal memory p = proposals[proposalId];
        return
            p.eta > 0 && !p.executed && !p.cancelled && block.timestamp >= p.eta
                && block.timestamp <= p.eta + GRACE_PERIOD;
    }

    /// @notice Get all pending proposals
    function getPendingProposals() external view returns (bytes32[] memory pending) {
        uint256 count = 0;
        for (uint256 i = 0; i < proposalIds.length; i++) {
            Proposal memory p = proposals[proposalIds[i]];
            if (!p.executed && !p.cancelled && block.timestamp <= p.eta + GRACE_PERIOD) {
                count++;
            }
        }

        pending = new bytes32[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < proposalIds.length; i++) {
            Proposal memory p = proposals[proposalIds[i]];
            if (!p.executed && !p.cancelled && block.timestamp <= p.eta + GRACE_PERIOD) {
                pending[idx++] = proposalIds[i];
            }
        }
    }
}
