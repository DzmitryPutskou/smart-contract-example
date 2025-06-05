pragma solidity ^0.8.0;

/**
 * @title TaskCampaignContract
 * @dev Simplified contract: tasks created off-chain; store funding, influencer assignments, payouts, and auto-close tasks.
 *      Removed dispute and rejection logic. Once funded, company can only pay influencers; no refunds.
 */
contract TaskCampaignContract {
    address public admin;
    uint256 public nextTaskId;
    uint256 public constant MAX_INFLUENCERS = 100;

    enum InfluencerStatus { Funded, Paid }

    struct InfluencerInfo {
        address influencerAddress;
        uint256 reward;
        InfluencerStatus status;
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
    event TaskClosed(uint256 indexed taskId);
    event RemainingWithdrawn(uint256 indexed taskId, uint256 amount);

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
    function addInfluencer(
        uint256 _taskId,
        address _influencerAddress,
        uint256 _influencerID,
        uint256 _reward
    ) external taskExists(_taskId) onlyCompany(_taskId) notClosed(_taskId) {
        Task storage t = tasks[_taskId];
        require(t.influencerIDs.length < MAX_INFLUENCERS, "Max influencers reached");
        require(!t.influencerExists[_influencerID], "Influencer already added");
        require(_reward <= t.budget, "Reward exceeds budget");

        // Reserve the reward amount immediately
        t.budget -= _reward;
        t.influencers[_influencerID] = InfluencerInfo({
            influencerAddress: _influencerAddress,
            reward: _reward,
            status: InfluencerStatus.Funded
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
     * @dev Company withdraws remaining funds after all influencer assignments finalized or after task closed.
     */
    function withdrawRemaining(uint256 _taskId)
        external
        taskExists(_taskId)
        onlyCompany(_taskId)
        notClosed(_taskId)
    {
        Task storage t = tasks[_taskId];
        require(_allPaid(_taskId), "Some influencers still pending payment");

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
     * @dev Check if all influencers have been paid.
     */
    function _allPaid(uint256 _taskId) internal view returns (bool) {
        Task storage t = tasks[_taskId];
        for (uint256 i = 0; i < t.influencerIDs.length; i++) {
            uint256 id = t.influencerIDs[i];
            if (!t.influencerExists[id]) {
                continue;
            }
            InfluencerInfo storage info = t.influencers[id];
            if (info.status == InfluencerStatus.Funded) {
                return false;
            }
        }
        return true;
    }

    /**
     * @dev Internal: auto-close if all influencers have been paid and budget is zero.
     */
    function _checkAndClose(uint256 _taskId) internal {
        Task storage t = tasks[_taskId];
        if (!t.isClosed && _allPaid(_taskId) && t.budget == 0) {
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

        // Remove from influencerIDs array by swapping with last and popping
        for (uint256 i = 0; i < t.influencerIDs.length; i++) {
            if (t.influencerIDs[i] == _influencerID) {
                t.influencerIDs[i] = t.influencerIDs[t.influencerIDs.length - 1];
                t.influencerIDs.pop();
                break;
            }
        }
    }
}
