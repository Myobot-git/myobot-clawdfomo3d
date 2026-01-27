// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title ClawdFomo3D
 * @notice King-of-the-hill game with $CLAWD. Last buyer wins when timer expires.
 *         Burns $CLAWD on every buy and at round end for deflationary pressure.
 */
contract ClawdFomo3D is ReentrancyGuard {
    // ============ Constants ============
    uint256 public constant BURN_ON_BUY_BPS = 1000;       // 10% burned on every buy
    uint256 public constant WINNER_BPS = 4000;              // 40% of pot to winner
    uint256 public constant BURN_ON_END_BPS = 3000;         // 30% of pot burned at round end
    uint256 public constant DIVIDENDS_BPS = 2500;           // 25% to key holders
    uint256 public constant DEV_BPS = 500;                  // 5% to dev
    uint256 public constant BPS = 10000;

    uint256 public constant ANTI_SNIPE_THRESHOLD = 2 minutes;
    uint256 public constant ANTI_SNIPE_EXTENSION = 2 minutes;

    // Key pricing: starts at BASE_PRICE, increases by INCREMENT per key sold
    uint256 public constant BASE_PRICE = 1000 * 1e18;      // 1000 CLAWD base
    uint256 public constant PRICE_INCREMENT = 10 * 1e18;    // +10 CLAWD per key sold

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // ============ State ============
    IERC20 public immutable clawd;
    address public immutable dev;
    uint256 public immutable timerDuration;

    uint256 public currentRound;
    uint256 public roundStart;
    uint256 public roundEnd;
    uint256 public pot;
    uint256 public totalKeys;
    address public lastBuyer;
    uint256 public totalBurned;

    // Dividend tracking (points-per-share)
    uint256 public pointsPerKey;
    uint256 internal constant MAGNITUDE = 2**128;

    struct Player {
        uint256 keys;
        int256 pointsCorrection;
        uint256 withdrawnDividends;
    }

    mapping(uint256 => mapping(address => Player)) public players; // round => player
    mapping(uint256 => RoundResult) public roundResults;

    struct RoundResult {
        address winner;
        uint256 potSize;
        uint256 winnerPayout;
        uint256 burned;
        uint256 endTime;
    }

    // ============ Events ============
    event KeysPurchased(uint256 indexed round, address indexed buyer, uint256 keys, uint256 cost, uint256 burned);
    event RoundEnded(uint256 indexed round, address indexed winner, uint256 payout, uint256 burned);
    event DividendsClaimed(uint256 indexed round, address indexed player, uint256 amount);
    event RoundStarted(uint256 indexed round, uint256 endTime);

    // ============ Constructor ============
    constructor(address _clawd, uint256 _timerDuration, address _dev) {
        clawd = IERC20(_clawd);
        timerDuration = _timerDuration;
        dev = _dev;
        currentRound = 1;
        roundStart = block.timestamp;
        roundEnd = block.timestamp + _timerDuration;
        emit RoundStarted(1, roundEnd);
    }

    // ============ Core ============

    /**
     * @notice Buy keys with $CLAWD. Requires prior approval.
     * @param numKeys Number of keys to buy (1+)
     */
    function buyKeys(uint256 numKeys) external nonReentrant {
        require(numKeys > 0, "Buy at least 1 key");
        require(block.timestamp < roundEnd, "Round ended, call endRound()");

        uint256 cost = getCostForKeys(numKeys);
        require(cost > 0, "Cost must be > 0");

        // Transfer CLAWD from buyer
        require(clawd.transferFrom(msg.sender, address(this), cost), "Transfer failed");

        // Burn 10% immediately
        uint256 burnAmount = (cost * BURN_ON_BUY_BPS) / BPS;
        uint256 toPot = cost - burnAmount;

        clawd.transfer(DEAD, burnAmount);
        totalBurned += burnAmount;

        // Add to pot
        pot += toPot;

        // Update player keys
        Player storage p = players[currentRound][msg.sender];
        p.keys += numKeys;
        p.pointsCorrection -= int256(pointsPerKey * numKeys);
        totalKeys += numKeys;

        // Update last buyer and timer
        lastBuyer = msg.sender;

        // Anti-snipe: if within last 2 min, only extend by 2 min
        uint256 timeLeft = roundEnd - block.timestamp;
        if (timeLeft < ANTI_SNIPE_THRESHOLD) {
            roundEnd = block.timestamp + ANTI_SNIPE_EXTENSION;
        } else {
            roundEnd = block.timestamp + timerDuration;
        }

        emit KeysPurchased(currentRound, msg.sender, numKeys, cost, burnAmount);
    }

    /**
     * @notice End the round and distribute the pot. Anyone can call.
     */
    function endRound() external nonReentrant {
        require(block.timestamp >= roundEnd, "Round not over yet");
        require(lastBuyer != address(0), "No one played");

        uint256 potSize = pot;
        pot = 0;

        // Split pot
        uint256 winnerPayout = (potSize * WINNER_BPS) / BPS;
        uint256 burnPayout = (potSize * BURN_ON_END_BPS) / BPS;
        uint256 dividendPayout = (potSize * DIVIDENDS_BPS) / BPS;
        uint256 devPayout = potSize - winnerPayout - burnPayout - dividendPayout; // remainder to dev

        // Pay winner
        clawd.transfer(lastBuyer, winnerPayout);

        // Burn
        clawd.transfer(DEAD, burnPayout);
        totalBurned += burnPayout;

        // Distribute dividends via points-per-key
        if (totalKeys > 0) {
            pointsPerKey += (dividendPayout * MAGNITUDE) / totalKeys;
        }

        // Dev fee
        clawd.transfer(dev, devPayout);

        // Record result
        roundResults[currentRound] = RoundResult({
            winner: lastBuyer,
            potSize: potSize,
            winnerPayout: winnerPayout,
            burned: burnPayout,
            endTime: block.timestamp
        });

        emit RoundEnded(currentRound, lastBuyer, winnerPayout, burnPayout);

        // Start new round
        currentRound++;
        roundStart = block.timestamp;
        roundEnd = block.timestamp + timerDuration;
        // Reset per-round state (keys/points carry over for dividend claims)
        // New round starts with fresh pot, totalKeys, lastBuyer
        totalKeys = 0;
        lastBuyer = address(0);
        pointsPerKey = 0;

        emit RoundStarted(currentRound, roundEnd);
    }

    /**
     * @notice Claim accumulated dividends for a specific round.
     */
    function claimDividends(uint256 round) external nonReentrant {
        Player storage p = players[round][msg.sender];
        uint256 owed = _dividendsOf(round, msg.sender);
        require(owed > 0, "No dividends");

        p.withdrawnDividends += owed;
        clawd.transfer(msg.sender, owed);

        emit DividendsClaimed(round, msg.sender, owed);
    }

    // ============ Views ============

    function getCostForKeys(uint256 numKeys) public view returns (uint256) {
        // Sum of arithmetic sequence: sum = n * (2*a + (n-1)*d) / 2
        // where a = BASE_PRICE + totalKeys * PRICE_INCREMENT (current price)
        // d = PRICE_INCREMENT, n = numKeys
        uint256 startPrice = BASE_PRICE + (totalKeys * PRICE_INCREMENT);
        uint256 endPrice = startPrice + ((numKeys - 1) * PRICE_INCREMENT);
        return (numKeys * (startPrice + endPrice)) / 2;
    }

    function currentKeyPrice() external view returns (uint256) {
        return BASE_PRICE + (totalKeys * PRICE_INCREMENT);
    }

    function timeRemaining() external view returns (uint256) {
        if (block.timestamp >= roundEnd) return 0;
        return roundEnd - block.timestamp;
    }

    function dividendsOf(uint256 round, address player) external view returns (uint256) {
        return _dividendsOf(round, player);
    }

    function _dividendsOf(uint256 round, address player) internal view returns (uint256) {
        Player storage p = players[round][player];
        int256 accumulated = int256(pointsPerKey * p.keys) + p.pointsCorrection;
        if (accumulated < 0) return 0;
        uint256 total = uint256(accumulated) / MAGNITUDE;
        return total - p.withdrawnDividends;
    }

    function getPlayerKeys(uint256 round, address player) external view returns (uint256) {
        return players[round][player].keys;
    }

    function getRoundResult(uint256 round) external view returns (RoundResult memory) {
        return roundResults[round];
    }
}
