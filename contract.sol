pragma solidity ^0.8.0;

/**
 * @title TaskCampaignContract
 * @dev Simplified contract: tasks created off-chain; store funding, influencer assignments, payouts, and disputes per influencer.
 *      Improved: track influencer IDs for iteration, auto-close tasks, support cancel before assignment, ensure refunds,
 *      limit influencer count, allow reuse of IDs after removal, bulk cancel remaining, emit TaskClosed once.
 */
contract TaskCampaignContract {
    address public admin;
    uint256 public nextTaskId;
    uint256 public constant MAX_INFLUENCERS = 100;

    enum InfluencerStatus { Funded, Paid, Rejected, Disputed }
    enum DisputeStatus { None, Open, Resolved }

    struct InfluencerInfo {
        address influencerAddress;
        uint256 reward;
        InfluencerStatus status;
        DisputeStatus disputeStatus;
    }

    struct Task {
        address company;
        uint256 budget;
        bool isClosed;
        uint256[] influencerIDs;
        mapping(uint256 => InfluencerInfo) influencers;
        mapping(uint256 => bool) influencerExists;
    }

    mapping(uint256 => Task) private tasks;

    event TaskFunded(uint256 indexed taskId, address indexed company, uint256 amount);
    event TaskCancelled(uint256 indexed taskId);
    event InfluencerAdded(uint256 indexed taskId, address indexed influencerAddress, uint256 influencerID, uint256 reward);
    event InfluencerPaid(uint256 indexed taskId, address indexed influencerAddress, uint256 reward);
    event InfluencerRejected(uint256 indexed taskId, address indexed influencerAddress);
    event DisputeRaised(uint256 indexed taskId, address indexed party, address indexed influencerAddress);
    event DisputeResolved(uint256 indexed taskId, address indexed winner, address indexed influencerAddress, uint256 reward);
    event TaskClosed(uint256 indexed taskId);
    event RemainingWithdrawn(uint256 indexed taskId, uint256 amount);
    event RemainingCancelled(uint256 indexed taskId);

    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin");
        _;
    }

    modifier onlyCompany(uint256 _taskId) {
        require(tasks[_taskId].company == msg.sender, "Only task owner");
        _;
    }

    modifier taskExists(uint256 _taskId) {
        require(tasks[_taskId].company != address(0), "Task does not exist");
        _;
    }

    modifier notClosed(uint256 _taskId) {
        require(!tasks[_taskId].isClosed, "Task is closed");
        _;
    }

    constructor() {
        admin = msg.sender;
        nextTaskId = 1;
    }

    /**
     * @dev Company registers and funds a new task off-chain identified by generated ID.
     */
    function createAndFundTask() external payable {
        require(msg.value > 0, "Must send funds");
        uint256 taskId = nextTaskId;
        Task storage t = tasks[taskId];
        t.company = msg.sender;
        t.budget = msg.value;
        t.isClosed = false;
        nextTaskId++;
        emit TaskFunded(taskId, msg.sender, msg.value);
    }

    /**
     * @dev Company cancels task before any influencer added, refunds entire budget.
     */
    function cancelTask(uint256 _taskId) external taskExists(_taskId) onlyCompany(_taskId) notClosed(_taskId) {
        Task storage t = tasks[_taskId];
        require(t.influencerIDs.length == 0, "Cannot cancel after adding influencers");
        uint256 amount = t.budget;
        t.budget = 0;
        t.isClosed = true;
        payable(t.company).transfer(amount);
        emit TaskCancelled(_taskId);
    }

    /**
     * @dev Company adds influencer assignment after off-chain selection.
     */
    function addInfluencer(uint256 _taskId, address _influencerAddress, uint256 _influencerID, uint256 _reward)
        external
        taskExists(_taskId)
        onlyCompany(_taskId)
        notClosed(_taskId)
    {
        Task storage t = tasks[_taskId];
        require(t.influencerIDs.length < MAX_INFLUENCERS, "Max influencers reached");
        require(!t.influencerExists[_influencerID], "Influencer already added");
        require(_reward <= t.budget, "Reward exceeds budget");
        t.budget -= _reward; // reserve reward
        t.influencers[_influencerID] = InfluencerInfo({
            influencerAddress: _influencerAddress,
            reward: _reward,
            status: InfluencerStatus.Funded,
            disputeStatus: DisputeStatus.None
        });
        t.influencerExists[_influencerID] = true;
        t.influencerIDs.push(_influencerID);
        emit InfluencerAdded(_taskId, _influencerAddress, _influencerID, _reward);
    }

    /**
     * @dev Company pays specific influencer on-chain and updates status.
     */
    function payInfluencer(uint256 _taskId, uint256 _influencerID)
        external
        taskExists(_taskId)
        onlyCompany(_taskId)
        notClosed(_taskId)
    {
        Task storage t = tasks[_taskId];
        require(t.influencerExists[_influencerID], "Influencer not found");
        InfluencerInfo storage info = t.influencers[_influencerID];
        require(info.status == InfluencerStatus.Funded, "Influencer not eligible for payment");
        info.status = InfluencerStatus.Paid;
        payable(info.influencerAddress).transfer(info.reward);
        emit InfluencerPaid(_taskId, info.influencerAddress, info.reward);
        _removeInfluencer(_taskId, _influencerID);
        _checkAndClose(_taskId);
    }

    /**
     * @dev Company rejects influencer's work (off-chain) and updates status.
     */
    function rejectInfluencer(uint256 _taskId, uint256 _influencerID)
        external
        taskExists(_taskId)
        onlyCompany(_taskId)
        notClosed(_taskId)
    {
        Task storage t = tasks[_taskId];
        require(t.influencerExists[_influencerID], "Influencer not found");
        InfluencerInfo storage info = t.influencers[_influencerID];
        require(info.status == InfluencerStatus.Funded, "Cannot reject after payment or dispute started");
        info.status = InfluencerStatus.Rejected;
        t.budget += info.reward; // return reserved reward
        emit InfluencerRejected(_taskId, info.influencerAddress);
        _removeInfluencer(_taskId, _influencerID);
        _checkAndClose(_taskId);
    }

    /**
     * @dev Either party raises a dispute for a specific influencer.
     */
    function raiseDispute(uint256 _taskId, uint256 _influencerID)
        external
        taskExists(_taskId)
        notClosed(_taskId)
    {
        Task storage t = tasks[_taskId];
        require(t.influencerExists[_influencerID], "Influencer not found");
        InfluencerInfo storage info = t.influencers[_influencerID];
        require(msg.sender == t.company || msg.sender == info.influencerAddress, "Not involved");
        require(info.status == InfluencerStatus.Funded, "Cannot dispute at this stage");
        info.status = InfluencerStatus.Disputed;
        info.disputeStatus = DisputeStatus.Open;
        emit DisputeRaised(_taskId, msg.sender, info.influencerAddress);
    }

    /**
     * @dev Admin resolves dispute; if influencer wins, pay from reserved funds and update status.
     */
    function resolveDispute(uint256 _taskId, uint256 _influencerID, bool influencerWins)
        external
        onlyAdmin
        taskExists(_taskId)
        notClosed(_taskId)
    {
        Task storage t = tasks[_taskId];
        require(t.influencerExists[_influencerID], "Influencer not found");
        InfluencerInfo storage info = t.influencers[_influencerID];
        require(info.disputeStatus == DisputeStatus.Open && info.status == InfluencerStatus.Disputed, "No open dispute for influencer");
        if (influencerWins) {
            info.status = InfluencerStatus.Paid;
            payable(info.influencerAddress).transfer(info.reward);
            emit DisputeResolved(_taskId, info.influencerAddress, info.influencerAddress, info.reward);
        } else {
            info.status = InfluencerStatus.Rejected;
            t.budget += info.reward; // return reserved reward
            emit DisputeResolved(_taskId, t.company, info.influencerAddress, 0);
        }
        info.disputeStatus = DisputeStatus.Resolved;
        _removeInfluencer(_taskId, _influencerID);
        _checkAndClose(_taskId);
    }

    /**
     * @dev Company withdraws remaining funds after all influencer assignments finalized or after task closed.
     */
    function withdrawRemaining(uint256 _taskId)
        external
        taskExists(_taskId)
        onlyCompany(_(taskId)
    {
        Task storage t = tasks[_taskId];
        require(t.budget > 0, "No funds");
        require(_allFinalized(_taskId), "Some influencers still pending or in dispute");
        uint256 amount = t.budget;
        t.budget = 0;
        t.isClosed = true;
        payable(t.company).transfer(amount);
        emit RemainingWithdrawn(_taskId, amount);
        emit TaskClosed(_taskId);
    }

    /**
     * @dev Returns remaining budget for a given task.
     */
    function getRemainingBudget(uint256 _taskId) external view taskExists(_taskId) returns (uint256) {
        return tasks[_taskId].budget;
    }

    /**
     * @dev Check if all influencers are in final states (Paid or Rejected) or disputes resolved.
     */
    function _allFinalized(uint256 _taskId) internal view returns (bool) {
        Task storage t = tasks[_taskId];
        for (uint256 i = 0; i < t.influencerIDs.length; i++) {
            uint256 id = t.influencerIDs[i];
            if (!t.influencerExists[id]) {
                continue;
            }
            InfluencerInfo storage info = t.influencers[id];
            if (info.status == InfluencerStatus.Funded || (info.status == InfluencerStatus.Disputed && info.disputeStatus == DisputeStatus.Open)) {
                return false;
            }
        }
        return true;
    }

    /**
     * @dev Internal: auto-close if all finalized and budget may be zero.
     */
    function _checkAndClose(uint256 _taskId) internal {
        Task storage t = tasks[_taskId];
        if (!t.isClosed && _allFinalized(_taskId) && t.budget == 0) {
            t.isClosed = true;
            emit TaskClosed(_taskId);
        }
    }

    /**
     * @dev Internal: remove influencer from tracking, allow ID reuse.
     */
    function _removeInfluencer(uint256 _taskId, uint256 _influencerID) internal {
        Task storage t = tasks[_taskId];
        if (!t.influencerExists[_influencerID]) return;
        t.influencerExists[_influencerID] = false;
        // remove from influencerIDs array
        for (uint256 i = 0; i < t.influencerIDs.length; i++) {
            if (t.influencerIDs[i] == _influencerID) {
                t.influencerIDs[i] = t.influencerIDs[t.influencerIDs.length - 1];
                t.influencerIDs.pop();
                break;
            }
        }
    }
}
