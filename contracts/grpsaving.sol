// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title GrpSaving
 * @notice Rotating group savings (ROSCA): 10 members deposit each round.
 *         A random member who has not yet won receives the full pool.
 *         Continues until every member has won exactly once (10 rounds).
 */
contract GrpSaving {
    uint256 public constant MAX_MEMBERS = 2;

    address public immutable organizer;
    uint256 public immutable contributionAmount;
    uint256 public immutable roundDuration; // seconds (e.g. 30 days)

    address[] public members;
    mapping(address => bool) public isMember;
    mapping(address => bool) public hasWon;

    uint256 public currentRound; // 1-based once started
    uint256 public roundStartTime;
    uint256 public poolBalance;
    uint256 public winnersCount;

    bool public started;
    bool public completed;

    /// @dev round => member => whether they deposited this round
    mapping(uint256 => mapping(address => bool)) public hasDeposited;

    event MemberJoined(address indexed member, uint256 memberCount);
    event RoundStarted(uint256 indexed round, uint256 startTime);
    event Deposited(address indexed member, uint256 indexed round, uint256 amount);
    event WinnerSelected(address indexed winner, uint256 indexed round, uint256 amount);
    event GroupCompleted(uint256 totalRounds);

    error AlreadyMember();
    error GroupFull();
    error GroupAlreadyStarted();
    error GroupNotStarted();
    error GroupAlreadyCompleted();
    error NotMember();
    error AlreadyDeposited();
    error IncorrectAmount();
    error NotAllDeposited();
    error RoundNotOver();
    error AlreadyWon();
    error TransferFailed();
    error OnlyOrganizer();

    modifier onlyOrganizer() {
        if (msg.sender != organizer) revert OnlyOrganizer();
        _;
    }

    /**
     * @param _contributionAmount Fixed deposit each member pays per round (in wei / native token).
     * @param _roundDurationSeconds Length of each round (e.g. 30 days = 2_592_000).
     */
    constructor(uint256 _contributionAmount, uint256 _roundDurationSeconds) {
        require(_contributionAmount > 0, "invalid contribution");
        require(_roundDurationSeconds > 0, "invalid duration");
        organizer = msg.sender;
        contributionAmount = _contributionAmount;
        roundDuration = _roundDurationSeconds;
    }

    /// @notice Join the savings group. Opens until 10 members have joined.
    function join() external {
        if (started) revert GroupAlreadyStarted();
        if (isMember[msg.sender]) revert AlreadyMember();
        if (members.length >= MAX_MEMBERS) revert GroupFull();

        isMember[msg.sender] = true;
        members.push(msg.sender);

        emit MemberJoined(msg.sender, members.length);
    }

    /// @notice Start the first round once exactly 10 members have joined.
    function startGroup() external onlyOrganizer {
        if (started) revert GroupAlreadyStarted();
        require(members.length == MAX_MEMBERS, "need 10 members");

        started = true;
        currentRound = 1;
        roundStartTime = block.timestamp;

        emit RoundStarted(currentRound, roundStartTime);
    }

    /// @notice Deposit the fixed contribution for the current round.
    function deposit() external payable {
        if (!started) revert GroupNotStarted();
        if (completed) revert GroupAlreadyCompleted();
        if (!isMember[msg.sender]) revert NotMember();
        if (hasDeposited[currentRound][msg.sender]) revert AlreadyDeposited();
        if (msg.value != contributionAmount) revert IncorrectAmount();

        hasDeposited[currentRound][msg.sender] = true;
        poolBalance += msg.value;

        emit Deposited(msg.sender, currentRound, msg.value);
    }

    /**
     * @notice After all members deposited (and optionally after the round duration),
     *         pick a random eligible winner who has never won, pay them the pool,
     *         then open the next round — or finish if all 10 have won.
     * @dev Pseudo-randomness from block data; fine for demos. Prefer VRF in production.
     */
    function selectWinner() external {
        if (!started) revert GroupNotStarted();
        if (completed) revert GroupAlreadyCompleted();
        if (!_allDeposited()) revert NotAllDeposited();
        // Enforce monthly spacing after the first deposit window is full
        if (block.timestamp < roundStartTime + roundDuration) revert RoundNotOver();

        address winner = _pickRandomEligibleWinner();
        uint256 payout = poolBalance;
        poolBalance = 0;
        hasWon[winner] = true;
        winnersCount += 1;

        (bool ok, ) = payable(winner).call{value: payout}("");
        if (!ok) revert TransferFailed();

        emit WinnerSelected(winner, currentRound, payout);

        if (winnersCount == MAX_MEMBERS) {
            completed = true;
            emit GroupCompleted(currentRound);
            return;
        }

        currentRound += 1;
        roundStartTime = block.timestamp;
        emit RoundStarted(currentRound, roundStartTime);
    }

    function memberCount() external view returns (uint256) {
        return members.length;
    }

    function getMembers() external view returns (address[] memory) {
        return members;
    }

    function depositedCount(uint256 round) public view returns (uint256 count) {
        for (uint256 i = 0; i < members.length; i++) {
            if (hasDeposited[round][members[i]]) count++;
        }
    }

    function eligibleWinners() public view returns (address[] memory) {
        uint256 n;
        for (uint256 i = 0; i < members.length; i++) {
            if (!hasWon[members[i]]) n++;
        }
        address[] memory list = new address[](n);
        uint256 j;
        for (uint256 i = 0; i < members.length; i++) {
            if (!hasWon[members[i]]) {
                list[j] = members[i];
                j++;
            }
        }
        return list;
    }

    function _allDeposited() internal view returns (bool) {
        for (uint256 i = 0; i < members.length; i++) {
            if (!hasDeposited[currentRound][members[i]]) return false;
        }
        return true;
    }

    function _pickRandomEligibleWinner() internal view returns (address) {
        address[] memory eligible = eligibleWinners();
        require(eligible.length > 0, "no eligible winners");

        uint256 entropy = uint256(
            keccak256(
                abi.encodePacked(
                    block.prevrandao,
                    block.timestamp,
                    block.number,
                    currentRound,
                    poolBalance,
                    msg.sender
                )
            )
        );
        return eligible[entropy % eligible.length];
    }
}
