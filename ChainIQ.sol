// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ChainIQ
 * @notice Quest setup and participation platform on BOT Chain
 * @dev Quest creators stake BOT tokens as rewards; participants submit proof hashes
 */
contract ChainIQ {

    // ─── Types ───────────────────────────────────────────────────────────────

    enum QuestStatus { Active, Paused, Completed, Cancelled }
    enum SubmissionStatus { Pending, Approved, Rejected }

    struct Quest {
        uint256 id;
        address creator;
        string title;
        string descriptionCID;   // IPFS CID for full description / task details
        uint256 rewardPerWinner; // in wei (BOT)
        uint256 maxWinners;
        uint256 deadline;        // unix timestamp
        QuestStatus status;
        uint256 winnersCount;
        uint256 totalRewardPool; // creator-deposited
    }

    struct Submission {
        uint256 id;
        uint256 questId;
        address participant;
        string proofCID;         // IPFS CID of proof (screenshot, tx hash, etc.)
        SubmissionStatus status;
        uint256 timestamp;
    }

    // ─── State ───────────────────────────────────────────────────────────────

    uint256 public questCount;
    uint256 public submissionCount;
    uint256 public platformFeeBps;   // basis points (e.g. 200 = 2%)
    address public owner;
    uint256 public accumulatedFees;

    mapping(uint256 => Quest) public quests;
    mapping(uint256 => Submission) public submissions;

    // questId => participant => submissionId (0 means not submitted)
    mapping(uint256 => mapping(address => uint256)) public participantSubmission;

    // questId => list of submission IDs
    mapping(uint256 => uint256[]) public questSubmissions;

    // ─── Events ──────────────────────────────────────────────────────────────

    event QuestCreated(
        uint256 indexed questId,
        address indexed creator,
        string title,
        uint256 rewardPerWinner,
        uint256 maxWinners,
        uint256 deadline
    );

    event QuestStatusChanged(uint256 indexed questId, QuestStatus status);

    event SubmissionMade(
        uint256 indexed submissionId,
        uint256 indexed questId,
        address indexed participant,
        string proofCID
    );

    event SubmissionReviewed(
        uint256 indexed submissionId,
        uint256 indexed questId,
        address indexed participant,
        SubmissionStatus status,
        uint256 rewardPaid
    );

    event RewardClaimed(uint256 indexed questId, address indexed winner, uint256 amount);
    event QuestRefunded(uint256 indexed questId, address indexed creator, uint256 amount);
    event FeesWithdrawn(address indexed owner, uint256 amount);

    // ─── Modifiers ───────────────────────────────────────────────────────────

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier onlyQuestCreator(uint256 questId) {
        require(quests[questId].creator == msg.sender, "Not quest creator");
        _;
    }

    modifier questExists(uint256 questId) {
        require(questId > 0 && questId <= questCount, "Quest not found");
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────────

    constructor(uint256 _platformFeeBps) {
        owner = msg.sender;
        platformFeeBps = _platformFeeBps; // e.g. 200 for 2%
    }

    // ─── Quest Management ────────────────────────────────────────────────────

    /**
     * @notice Create a new quest. Send BOT equal to rewardPerWinner * maxWinners.
     */
    function createQuest(
        string calldata title,
        string calldata descriptionCID,
        uint256 rewardPerWinner,
        uint256 maxWinners,
        uint256 deadline
    ) external payable returns (uint256 questId) {
        require(bytes(title).length > 0, "Title required");
        require(rewardPerWinner > 0, "Reward must be > 0");
        require(maxWinners > 0, "Max winners must be > 0");
        require(deadline > block.timestamp, "Deadline must be in future");

        uint256 requiredPool = rewardPerWinner * maxWinners;
        uint256 fee = (requiredPool * platformFeeBps) / 10000;
        uint256 totalRequired = requiredPool + fee;

        require(msg.value >= totalRequired, "Insufficient BOT sent");

        questCount++;
        questId = questCount;

        quests[questId] = Quest({
            id: questId,
            creator: msg.sender,
            title: title,
            descriptionCID: descriptionCID,
            rewardPerWinner: rewardPerWinner,
            maxWinners: maxWinners,
            deadline: deadline,
            status: QuestStatus.Active,
            winnersCount: 0,
            totalRewardPool: requiredPool
        });

        accumulatedFees += fee;

        // Refund excess
        uint256 excess = msg.value - totalRequired;
        if (excess > 0) {
            payable(msg.sender).transfer(excess);
        }

        emit QuestCreated(questId, msg.sender, title, rewardPerWinner, maxWinners, deadline);
    }

    /**
     * @notice Pause or reactivate a quest (creator only).
     */
    function togglePause(uint256 questId)
        external
        questExists(questId)
        onlyQuestCreator(questId)
    {
        Quest storage q = quests[questId];
        require(q.status == QuestStatus.Active || q.status == QuestStatus.Paused, "Cannot toggle");

        q.status = q.status == QuestStatus.Active ? QuestStatus.Paused : QuestStatus.Active;
        emit QuestStatusChanged(questId, q.status);
    }

    /**
     * @notice Cancel a quest and refund remaining pool to creator.
     * Only if no approved submissions exist.
     */
    function cancelQuest(uint256 questId)
        external
        questExists(questId)
        onlyQuestCreator(questId)
    {
        Quest storage q = quests[questId];
        require(
            q.status == QuestStatus.Active || q.status == QuestStatus.Paused,
            "Quest already ended"
        );

        uint256 remaining = q.totalRewardPool - (q.winnersCount * q.rewardPerWinner);
        q.status = QuestStatus.Cancelled;

        if (remaining > 0) {
            payable(q.creator).transfer(remaining);
        }

        emit QuestRefunded(questId, q.creator, remaining);
        emit QuestStatusChanged(questId, QuestStatus.Cancelled);
    }

    // ─── Participation ───────────────────────────────────────────────────────

    /**
     * @notice Submit proof for a quest.
     * @param proofCID IPFS CID of the proof document/screenshot.
     */
    function submitProof(uint256 questId, string calldata proofCID)
        external
        questExists(questId)
    {
        Quest storage q = quests[questId];
        require(q.status == QuestStatus.Active, "Quest not active");
        require(block.timestamp <= q.deadline, "Quest deadline passed");
        require(q.winnersCount < q.maxWinners, "Max winners reached");
        require(participantSubmission[questId][msg.sender] == 0, "Already submitted");
        require(bytes(proofCID).length > 0, "Proof CID required");

        submissionCount++;
        uint256 subId = submissionCount;

        submissions[subId] = Submission({
            id: subId,
            questId: questId,
            participant: msg.sender,
            proofCID: proofCID,
            status: SubmissionStatus.Pending,
            timestamp: block.timestamp
        });

        participantSubmission[questId][msg.sender] = subId;
        questSubmissions[questId].push(subId);

        emit SubmissionMade(subId, questId, msg.sender, proofCID);
    }

    // ─── Review & Reward ─────────────────────────────────────────────────────

    /**
     * @notice Approve or reject a submission. Approved submissions trigger reward transfer.
     */
    function reviewSubmission(uint256 submissionId, bool approve)
        external
        questExists(submissions[submissionId].questId)
        onlyQuestCreator(submissions[submissionId].questId)
    {
        Submission storage sub = submissions[submissionId];
        Quest storage q = quests[sub.questId];

        require(sub.status == SubmissionStatus.Pending, "Already reviewed");
        require(q.status == QuestStatus.Active || q.status == QuestStatus.Paused, "Quest ended");

        if (approve) {
            require(q.winnersCount < q.maxWinners, "Max winners reached");

            sub.status = SubmissionStatus.Approved;
            q.winnersCount++;

            if (q.winnersCount == q.maxWinners) {
                q.status = QuestStatus.Completed;
                emit QuestStatusChanged(sub.questId, QuestStatus.Completed);
            }

            payable(sub.participant).transfer(q.rewardPerWinner);
            emit RewardClaimed(sub.questId, sub.participant, q.rewardPerWinner);
        } else {
            sub.status = SubmissionStatus.Rejected;
        }

        emit SubmissionReviewed(submissionId, sub.questId, sub.participant, sub.status, approve ? q.rewardPerWinner : 0);
    }

    // ─── Post-deadline refund ─────────────────────────────────────────────────

    /**
     * @notice After deadline, creator can reclaim unfilled reward pool.
     */
    function reclaimExpiredPool(uint256 questId)
        external
        questExists(questId)
        onlyQuestCreator(questId)
    {
        Quest storage q = quests[questId];
        require(block.timestamp > q.deadline, "Deadline not passed");
        require(q.status == QuestStatus.Active || q.status == QuestStatus.Paused, "Already ended");

        uint256 remaining = q.totalRewardPool - (q.winnersCount * q.rewardPerWinner);
        q.status = QuestStatus.Completed;

        if (remaining > 0) {
            payable(q.creator).transfer(remaining);
        }

        emit QuestRefunded(questId, q.creator, remaining);
        emit QuestStatusChanged(questId, QuestStatus.Completed);
    }

    // ─── Views ───────────────────────────────────────────────────────────────

    function getQuestSubmissions(uint256 questId) external view returns (uint256[] memory) {
        return questSubmissions[questId];
    }

    function getSubmissionForParticipant(uint256 questId, address participant)
        external view returns (uint256)
    {
        return participantSubmission[questId][participant];
    }

    // ─── Admin ───────────────────────────────────────────────────────────────

    function withdrawFees() external onlyOwner {
        uint256 amount = accumulatedFees;
        accumulatedFees = 0;
        payable(owner).transfer(amount);
        emit FeesWithdrawn(owner, amount);
    }

    function setFeeBps(uint256 newFeeBps) external onlyOwner {
        require(newFeeBps <= 1000, "Max 10%");
        platformFeeBps = newFeeBps;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        owner = newOwner;
    }

    receive() external payable {}
}
