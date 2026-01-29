// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MyobotFomo3D
 * @author Myobot 🦞 (forked from ClawdFomo3D by @clawdbotatg)
 * @notice King-of-the-hill game — last buyer wins when timer runs out
 * @dev Uses $MYOBOT token on Base
 * 
 * Changes from ClawdFomo3D:
 * - Uses $MYOBOT token instead of $CLAWD
 * - Added health research fund (5% of pot)
 * - Adjusted dividends to 20% (from 25%)
 * - Added Pausable for emergencies
 * 
 * Token: 0x24d837b72d264a6db5830edd42e4535663a12b07
 */
contract MyobotFomo3D is ReentrancyGuard, Pausable, Ownable {
    using SafeERC20 for IERC20;

    // ============ Events ============

    event KeysPurchased(
        uint256 indexed round,
        address indexed player,
        uint256 numKeys,
        uint256 cost
    );
    
    event RoundEnded(
        uint256 indexed round,
        address indexed winner,
        uint256 winnerPrize,
        uint256 burned,
        uint256 dividends,
        uint256 healthFund
    );
    
    event DividendsClaimed(
        uint256 indexed round,
        address indexed player,
        uint256 amount
    );
    
    event HealthFundWithdrawn(address indexed to, uint256 amount);

    // ============ Errors ============

    error RoundNotActive();
    error RoundStillActive();
    error InvalidKeyAmount();
    error InsufficientBalance();
    error NoDividendsToClaim();
    error AlreadyClaimed();
    error NoKeysInRound();

    // ============ Constants ============

    /// @notice $MYOBOT token on Base
    IERC20 public immutable token;
    
    /// @notice Burn address
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    
    /// @notice Base price for first key (1000 tokens with 18 decimals)
    uint256 public constant BASE_PRICE = 1000 ether;
    
    /// @notice Price increment per key sold (10 tokens)
    uint256 public constant PRICE_INCREMENT = 10 ether;
    
    /// @notice Anti-snipe threshold (2 minutes)
    uint256 public constant ANTI_SNIPE_THRESHOLD = 2 minutes;
    
    /// @notice Max timer extension during anti-snipe (2 minutes)
    uint256 public constant ANTI_SNIPE_EXTENSION = 2 minutes;

    // ============ Distribution (basis points) ============

    uint256 public constant BUY_BURN_BPS = 1000;        // 10% burned on buy
    uint256 public constant WINNER_BPS = 4000;          // 40% to winner
    uint256 public constant END_BURN_BPS = 3000;        // 30% burned at end
    uint256 public constant DIVIDEND_BPS = 2000;        // 20% to key holders
    uint256 public constant HEALTH_FUND_BPS = 500;      // 5% to health fund
    uint256 public constant DEV_FEE_BPS = 500;          // 5% to dev

    // ============ State ============

    /// @notice Current round number
    uint256 public currentRound;
    
    /// @notice Round duration in seconds
    uint256 public roundDuration;
    
    /// @notice Health research fund balance
    uint256 public healthFundBalance;
    
    /// @notice Health fund recipient address
    address public healthFundRecipient;
    
    /// @notice Dev fee recipient
    address public devFeeRecipient;

    // ============ Round Data ============

    struct Round {
        uint256 pot;                    // Total pot for this round
        uint256 totalKeys;              // Total keys sold
        uint256 endTime;                // When round ends
        address lastBuyer;              // Current king
        bool ended;                     // Whether round has ended
        uint256 dividendPool;           // Dividends to distribute
    }
    
    /// @notice Round data by round number
    mapping(uint256 => Round) public rounds;
    
    /// @notice Keys held by player in each round
    mapping(uint256 => mapping(address => uint256)) public playerKeys;
    
    /// @notice Whether player has claimed dividends for round
    mapping(uint256 => mapping(address => bool)) public hasClaimed;

    // ============ Constructor ============

    /**
     * @notice Initialize the game
     * @param _token $MYOBOT token address
     * @param _roundDuration Initial round duration in seconds
     * @param _healthFundRecipient Address to receive health fund
     * @param _devFeeRecipient Address to receive dev fees
     */
    constructor(
        address _token,
        uint256 _roundDuration,
        address _healthFundRecipient,
        address _devFeeRecipient
    ) Ownable(msg.sender) {
        token = IERC20(_token);
        roundDuration = _roundDuration;
        healthFundRecipient = _healthFundRecipient;
        devFeeRecipient = _devFeeRecipient;
        
        // Start first round
        currentRound = 1;
        rounds[1].endTime = block.timestamp + _roundDuration;
    }

    // ============ Game Functions ============

    /**
     * @notice Buy keys in the current round
     * @param numKeys Number of keys to purchase
     */
    function buyKeys(uint256 numKeys) external nonReentrant whenNotPaused {
        if (numKeys == 0) revert InvalidKeyAmount();
        
        Round storage round = rounds[currentRound];
        
        // Check if round is active
        if (round.ended || block.timestamp >= round.endTime) {
            revert RoundNotActive();
        }
        
        // Calculate cost
        uint256 cost = getCostForKeys(numKeys);
        
        // Transfer tokens from player
        token.safeTransferFrom(msg.sender, address(this), cost);
        
        // Burn 10% immediately
        uint256 burnAmount = (cost * BUY_BURN_BPS) / 10000;
        token.safeTransfer(DEAD, burnAmount);
        
        // Add rest to pot
        uint256 toPot = cost - burnAmount;
        round.pot += toPot;
        
        // Update keys
        round.totalKeys += numKeys;
        playerKeys[currentRound][msg.sender] += numKeys;
        
        // Update last buyer (new king!)
        round.lastBuyer = msg.sender;
        
        // Handle timer
        if (block.timestamp >= round.endTime - ANTI_SNIPE_THRESHOLD) {
            // Anti-snipe: only extend by 2 minutes
            round.endTime = block.timestamp + ANTI_SNIPE_EXTENSION;
        } else {
            // Normal: reset full timer
            round.endTime = block.timestamp + roundDuration;
        }
        
        emit KeysPurchased(currentRound, msg.sender, numKeys, cost);
    }

    /**
     * @notice End the current round (anyone can call when timer expires)
     */
    function endRound() external nonReentrant {
        Round storage round = rounds[currentRound];
        
        if (round.ended) revert RoundStillActive();
        if (block.timestamp < round.endTime) revert RoundStillActive();
        if (round.lastBuyer == address(0)) revert NoKeysInRound();
        
        round.ended = true;
        
        uint256 pot = round.pot;
        
        // Calculate distributions
        uint256 winnerPrize = (pot * WINNER_BPS) / 10000;
        uint256 burnAmount = (pot * END_BURN_BPS) / 10000;
        uint256 dividends = (pot * DIVIDEND_BPS) / 10000;
        uint256 healthFund = (pot * HEALTH_FUND_BPS) / 10000;
        uint256 devFee = (pot * DEV_FEE_BPS) / 10000;
        
        // Store dividends for claiming
        round.dividendPool = dividends;
        
        // Distribute
        token.safeTransfer(round.lastBuyer, winnerPrize);
        token.safeTransfer(DEAD, burnAmount);
        token.safeTransfer(devFeeRecipient, devFee);
        
        // Add to health fund
        healthFundBalance += healthFund;
        
        emit RoundEnded(
            currentRound,
            round.lastBuyer,
            winnerPrize,
            burnAmount,
            dividends,
            healthFund
        );
        
        // Start next round
        currentRound++;
        rounds[currentRound].endTime = block.timestamp + roundDuration;
    }

    /**
     * @notice Claim dividends from a completed round
     * @param roundNum Round number to claim from
     */
    function claimDividends(uint256 roundNum) external nonReentrant {
        Round storage round = rounds[roundNum];
        
        if (!round.ended) revert RoundNotActive();
        if (hasClaimed[roundNum][msg.sender]) revert AlreadyClaimed();
        
        uint256 keys = playerKeys[roundNum][msg.sender];
        if (keys == 0) revert NoDividendsToClaim();
        
        // Calculate share
        uint256 share = (round.dividendPool * keys) / round.totalKeys;
        if (share == 0) revert NoDividendsToClaim();
        
        hasClaimed[roundNum][msg.sender] = true;
        
        token.safeTransfer(msg.sender, share);
        
        emit DividendsClaimed(roundNum, msg.sender, share);
    }

    // ============ View Functions ============

    /**
     * @notice Get current price for one key
     */
    function currentKeyPrice() public view returns (uint256) {
        return BASE_PRICE + (rounds[currentRound].totalKeys * PRICE_INCREMENT);
    }

    /**
     * @notice Calculate total cost for n keys
     * @param numKeys Number of keys to calculate
     */
    function getCostForKeys(uint256 numKeys) public view returns (uint256) {
        uint256 currentKeys = rounds[currentRound].totalKeys;
        uint256 total = 0;
        
        for (uint256 i = 0; i < numKeys; i++) {
            total += BASE_PRICE + ((currentKeys + i) * PRICE_INCREMENT);
        }
        
        return total;
    }

    /**
     * @notice Get time remaining in current round
     */
    function timeRemaining() public view returns (uint256) {
        Round storage round = rounds[currentRound];
        if (block.timestamp >= round.endTime || round.ended) {
            return 0;
        }
        return round.endTime - block.timestamp;
    }

    /**
     * @notice Get unclaimed dividends for a player in a round
     */
    function dividendsOf(uint256 roundNum, address player) external view returns (uint256) {
        Round storage round = rounds[roundNum];
        
        if (!round.ended || hasClaimed[roundNum][player]) {
            return 0;
        }
        
        uint256 keys = playerKeys[roundNum][player];
        if (keys == 0 || round.totalKeys == 0) {
            return 0;
        }
        
        return (round.dividendPool * keys) / round.totalKeys;
    }

    /**
     * @notice Get keys held by player in a round
     */
    function getPlayerKeys(uint256 roundNum, address player) external view returns (uint256) {
        return playerKeys[roundNum][player];
    }

    /**
     * @notice Get round info
     */
    function getRoundInfo(uint256 roundNum) external view returns (
        uint256 pot,
        uint256 totalKeys,
        uint256 endTime,
        address lastBuyer,
        bool ended,
        uint256 dividendPool
    ) {
        Round storage round = rounds[roundNum];
        return (
            round.pot,
            round.totalKeys,
            round.endTime,
            round.lastBuyer,
            round.ended,
            round.dividendPool
        );
    }

    // ============ Admin Functions ============

    /**
     * @notice Withdraw health fund to recipient
     */
    function withdrawHealthFund() external {
        require(msg.sender == healthFundRecipient || msg.sender == owner(), "Not authorized");
        
        uint256 amount = healthFundBalance;
        healthFundBalance = 0;
        
        token.safeTransfer(healthFundRecipient, amount);
        
        emit HealthFundWithdrawn(healthFundRecipient, amount);
    }

    /**
     * @notice Update health fund recipient
     */
    function setHealthFundRecipient(address _recipient) external onlyOwner {
        healthFundRecipient = _recipient;
    }

    /**
     * @notice Update dev fee recipient
     */
    function setDevFeeRecipient(address _recipient) external onlyOwner {
        devFeeRecipient = _recipient;
    }

    /**
     * @notice Update round duration (for future rounds)
     */
    function setRoundDuration(uint256 _duration) external onlyOwner {
        roundDuration = _duration;
    }

    /**
     * @notice Pause the game (emergencies)
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause the game
     */
    function unpause() external onlyOwner {
        _unpause();
    }
}
