// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title Compound-Style Lending Pool
 * @dev A decentralized lending protocol allowing users to supply assets as collateral,
 * borrow other assets, and earn interest on deposits.
 */
contract LendingPool is ReentrancyGuard {
    using SafeMath for uint256;

    // Interest rate model parameters
    uint256 private constant BASE_RATE = 1e16; // 1% annual
    uint256 private constant MULTIPLIER = 2e17; // 20% annual at full utilization
    uint256 private constant KINK = 0.8e18; // 80% utilization
    uint256 private constant JUMP_MULTIPLIER = 5e17; // 50% annual after kink

    // Protocol parameters
    uint256 private constant RESERVE_FACTOR = 0.1e18; // 10% of interest goes to reserves
    uint256 private constant COLLATERAL_FACTOR = 0.75e18; // 75% collateral factor
    uint256 private constant LIQUIDATION_PENALTY = 0.1e18; // 10% liquidation penalty

    // Asset configuration
    struct Market {
        bool isListed;
        uint256 collateralFactor;
        uint256 supplyRate;
        uint256 borrowRate;
        uint256 totalSupply;
        uint256 totalBorrows;
        uint256 reserves;
        uint256 exchangeRate;
        uint256 accrualBlockNumber;
        uint256 borrowIndex;
    }

    // User account data
    struct AccountSnapshot {
        uint256 supplyBalance;
        uint256 borrowBalance;
        uint256 exchangeRate;
    }

    // Supported markets
    mapping(address => Market) public markets;
    address[] public allMarkets;

    // User balances
    mapping(address => mapping(address => uint256)) public supplyBalances;
    mapping(address => mapping(address => uint256)) public borrowBalances;
    mapping(address => uint256) public borrowIndexes;

    // Protocol governance
    address public admin;
    address public pendingAdmin;

    // Events
    event MarketListed(address indexed token);
    event Supply(address indexed user, address indexed token, uint256 amount);
    event Withdraw(address indexed user, address indexed token, uint256 amount);
    event Borrow(address indexed user, address indexed token, uint256 amount);
    event Repay(address indexed user, address indexed token, uint256 amount);
    event Liquidate(
        address indexed liquidator,
        address indexed borrower,
        address indexed tokenRepaid,
        address tokenCollateral,
        uint256 amountRepaid,
        uint256 amountSeized
    );

    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin can perform this action");
        _;
    }

    constructor() {
        admin = msg.sender;
    }

    /**
     * @dev Lists a new market in the protocol
     * @param token The ERC20 token address to list
     * @param collateralFactor The collateral factor for this market (scaled by 1e18)
     */
    function listMarket(address token, uint256 collateralFactor) external onlyAdmin {
        require(!markets[token].isListed, "Market already listed");
        require(collateralFactor <= 0.9e18, "Collateral factor too high");

        markets[token] = Market({
            isListed: true,
            collateralFactor: collateralFactor,
            supplyRate: 0,
            borrowRate: 0,
            totalSupply: 0,
            totalBorrows: 0,
            reserves: 0,
            exchangeRate: 1e18,
            accrualBlockNumber: block.number,
            borrowIndex: 1e18
        });

        allMarkets.push(token);
        emit MarketListed(token);
    }

    /**
     * @dev Supplies assets to the protocol
     * @param token The ERC20 token address to supply
     * @param amount The amount to supply
     */
    function supply(address token, uint256 amount) external nonReentrant {
        require(markets[token].isListed, "Market not listed");
        require(amount > 0, "Amount must be greater than 0");

        Market storage market = markets[token];
        updateMarketState(token);

        // Transfer tokens from user
        IERC20(token).transferFrom(msg.sender, address(this), amount);

        // Calculate tokens to mint (amount / exchangeRate)
        uint256 supplyTokens = amount.mul(1e18).div(market.exchangeRate);
        supplyBalances[msg.sender][token] = supplyBalances[msg.sender][token].add(supplyTokens);
        market.totalSupply = market.totalSupply.add(supplyTokens);

        emit Supply(msg.sender, token, amount);
    }

    /**
     * @dev Withdraws assets from the protocol
     * @param token The ERC20 token address to withdraw
     * @param amount The amount to withdraw
     */
    function withdraw(address token, uint256 amount) external nonReentrant {
        require(markets[token].isListed, "Market not listed");
        require(amount > 0, "Amount must be greater than 0");

        Market storage market = markets[token];
        updateMarketState(token);

        // Calculate tokens to burn (amount / exchangeRate)
        uint256 supplyTokens = amount.mul(1e18).div(market.exchangeRate);
        require(supplyBalances[msg.sender][token] >= supplyTokens, "Insufficient balance");

        // Check account liquidity
        require(getAccountLiquidity(msg.sender) >= 0, "Account would become undercollateralized");

        supplyBalances[msg.sender][token] = supplyBalances[msg.sender][token].sub(supplyTokens);
        market.totalSupply = market.totalSupply.sub(supplyTokens);

        // Transfer tokens to user
        IERC20(token).transfer(msg.sender, amount);

        emit Withdraw(msg.sender, token, amount);
    }

    /**
     * @dev Borrows assets from the protocol
     * @param token The ERC20 token address to borrow
     * @param amount The amount to borrow
     */
    function borrow(address token, uint256 amount) external nonReentrant {
        require(markets[token].isListed, "Market not listed");
        require(amount > 0, "Amount must be greater than 0");

        Market storage market = markets[token];
        updateMarketState(token);

        // Check borrow availability
        require(market.totalSupply.sub(market.totalBorrows) >= amount, "Insufficient liquidity");

        // Check account liquidity
        uint256 liquidity = getAccountLiquidity(msg.sender);
        require(liquidity >= 0, "Insufficient collateral");
        require(uint256(liquidity) >= amount, "Borrow would exceed collateral limit");

        // Update borrow balance
        borrowBalances[msg.sender][token] = borrowBalances[msg.sender][token].add(amount);
        market.totalBorrows = market.totalBorrows.add(amount);
        borrowIndexes[msg.sender] = market.borrowIndex;

        // Transfer tokens to user
        IERC20(token).transfer(msg.sender, amount);

        emit Borrow(msg.sender, token, amount);
    }

    /**
     * @dev Repays a borrow
     * @param token The ERC20 token address to repay
     * @param amount The amount to repay
     */
    function repay(address token, uint256 amount) external nonReentrant {
        require(markets[token].isListed, "Market not listed");
        require(amount > 0, "Amount must be greater than 0");

        Market storage market = markets[token];
        updateMarketState(token);

        // Calculate accrued borrow balance
        uint256 borrowBalance = borrowBalances[msg.sender][token].mul(market.borrowIndex).div(borrowIndexes[msg.sender]);
        uint256 repayAmount = amount > borrowBalance ? borrowBalance : amount;

        // Transfer tokens from user
        IERC20(token).transferFrom(msg.sender, address(this), repayAmount);

        // Update borrow balance
        borrowBalances[msg.sender][token] = borrowBalance.sub(repayAmount);
        market.totalBorrows = market.totalBorrows.sub(repayAmount);

        emit Repay(msg.sender, token, repayAmount);
    }

    /**
     * @dev Liquidates an undercollateralized position
     * @param borrower The account to liquidate
     * @param tokenRepaid The token being repaid
     * @param tokenCollateral The collateral token to seize
     * @param amount The amount to repay
     */
    function liquidate(
        address borrower,
        address tokenRepaid,
        address tokenCollateral,
        uint256 amount
    ) external nonReentrant {
        require(markets[tokenRepaid].isListed && markets[tokenCollateral].isListed, "Market not listed");
        require(amount > 0, "Amount must be greater than 0");

        Market storage marketRepaid = markets[tokenRepaid];
        Market storage marketCollateral = markets[tokenCollateral];
        updateMarketState(tokenRepaid);
        updateMarketState(tokenCollateral);

        // Check if borrower is underwater
        require(getAccountLiquidity(borrower) < 0, "Borrower is not underwater");

        // Calculate accrued borrow balance
        uint256 borrowBalance = borrowBalances[borrower][tokenRepaid].mul(marketRepaid.borrowIndex).div(borrowIndexes[borrower]);
        uint256 repayAmount = amount > borrowBalance ? borrowBalance : amount;

        // Calculate collateral to seize (with penalty)
        uint256 exchangeRate = marketCollateral.exchangeRate;
        uint256 collateralAmount = repayAmount
            .mul(1e18)
            .div(exchangeRate)
            .mul(LIQUIDATION_PENALTY.add(1e18))
            .div(1e18);

        // Check borrower's collateral balance
        uint256 borrowerCollateral = supplyBalances[borrower][tokenCollateral].mul(exchangeRate).div(1e18);
        require(collateralAmount <= borrowerCollateral, "Too much collateral seized");

        // Transfer repaid tokens from liquidator
        IERC20(tokenRepaid).transferFrom(msg.sender, address(this), repayAmount);

        // Update balances
        borrowBalances[borrower][tokenRepaid] = borrowBalance.sub(repayAmount);
        marketRepaid.totalBorrows = marketRepaid.totalBorrows.sub(repayAmount);

        // Seize collateral
        uint256 collateralTokens = collateralAmount.mul(1e18).div(exchangeRate);
        supplyBalances[borrower][tokenCollateral] = supplyBalances[borrower][tokenCollateral].sub(collateralTokens);
        supplyBalances[msg.sender][tokenCollateral] = supplyBalances[msg.sender][tokenCollateral].add(collateralTokens);
        marketCollateral.totalSupply = marketCollateral.totalSupply; // No change in total supply

        emit Liquidate(msg.sender, borrower, tokenRepaid, tokenCollateral, repayAmount, collateralAmount);
    }

    /**
     * @dev Updates the market state (interest rates, indexes)
     * @param token The market token to update
     */
    function updateMarketState(address token) internal {
        Market storage market = markets[token];
        if (market.accrualBlockNumber == block.number) return;

        if (market.totalSupply == 0) {
            market.accrualBlockNumber = block.number;
            return;
        }

        // Calculate interest accrued
        uint256 blockDelta = block.number.sub(market.accrualBlockNumber);
        uint256 borrowRate = calculateBorrowRate(token);
        uint256 supplyRate = calculateSupplyRate(token, borrowRate);

        // Update borrow index
        uint256 borrowIndex = market.borrowIndex;
        uint256 borrowIndexNew = borrowRate.mul(blockDelta).div(1e18).add(1).mul(borrowIndex).div(1e18);
        market.borrowIndex = borrowIndexNew;

        // Update exchange rate
        uint256 supplyInterest = market.totalBorrows.mul(supplyRate).mul(blockDelta).div(1e18);
        uint256 reserves = supplyInterest.mul(RESERVE_FACTOR).div(1e18);
        uint256 supplyInterestToMarket = supplyInterest.sub(reserves);

        market.exchangeRate = market.totalSupply > 0
            ? market.exchangeRate.mul(market.totalSupply.add(supplyInterestToMarket)).div(market.totalSupply)
            : 1e18;
        market.reserves = market.reserves.add(reserves);
        market.totalBorrows = market.totalBorrows.add(market.totalBorrows.mul(borrowRate).mul(blockDelta).div(1e18);
        market.accrualBlockNumber = block.number;
        market.borrowRate = borrowRate;
        market.supplyRate = supplyRate;
    }

    /**
     * @dev Calculates the current borrow rate for a market
     * @param token The market token
     * @return The borrow rate (scaled by 1e18)
     */
    function calculateBorrowRate(address token) internal view returns (uint256) {
        Market storage market = markets[token];
        if (market.totalSupply == 0) return BASE_RATE;

        uint256 utilization = market.totalBorrows.mul(1e18).div(market.totalSupply);
        if (utilization <= KINK) {
            return BASE_RATE.add(utilization.mul(MULTIPLIER).div(1e18));
        } else {
            uint256 normalRate = BASE_RATE.add(KINK.mul(MULTIPLIER).div(1e18));
            uint256 excessUtil = utilization.sub(KINK);
            return normalRate.add(excessUtil.mul(JUMP_MULTIPLIER).div(1e18));
        }
    }

    /**
     * @dev Calculates the current supply rate for a market
     * @param token The market token
     * @param borrowRate The current borrow rate
     * @return The supply rate (scaled by 1e18)
     */
    function calculateSupplyRate(address token, uint256 borrowRate) internal view returns (uint256) {
        Market storage market = markets[token];
        if (market.totalSupply == 0) return 0;

        uint256 utilization = market.totalBorrows.mul(1e18).div(market.totalSupply);
        return borrowRate.mul(utilization).div(1e18).mul(1e18.sub(RESERVE_FACTOR)).div(1e18);
    }

    /**
     * @dev Calculates account liquidity (surplus or deficit)
     * @param user The user address
     * @return liquidity Surplus (positive) or deficit (negative), scaled by 1e18
     */
    function getAccountLiquidity(address user) public view returns (int256) {
        uint256 totalCollateral;
        uint256 totalBorrow;

        for (uint256 i = 0; i < allMarkets.length; i++) {
            address token = allMarkets[i];
            Market storage market = markets[token];

            // Calculate supply balance (in underlying)
            uint256 supplyBalance = supplyBalances[user][token].mul(market.exchangeRate).div(1e18);
            totalCollateral = totalCollateral.add(supplyBalance.mul(market.collateralFactor).div(1e18));

            // Calculate borrow balance (with interest)
            uint256 borrowBalance = borrowBalances[user][token].mul(market.borrowIndex).div(borrowIndexes[user]);
            totalBorrow = totalBorrow.add(borrowBalance);
        }

        return int256(totalCollateral) - int256(totalBorrow);
    }

    /**
     * @dev Returns the user's supply and borrow balances for a market
     * @param user The user address
     * @param token The market token
     * @return supplyBalance The supply balance (in underlying)
     * @return borrowBalance The borrow balance (with interest)
     */
    function getAccountSnapshot(address user, address token) external view returns (uint256 supplyBalance, uint256 borrowBalance) {
        Market storage market = markets[token];
        supplyBalance = supplyBalances[user][token].mul(market.exchangeRate).div(1e18);
        borrowBalance = borrowBalances[user][token].mul(market.borrowIndex).div(borrowIndexes[user]);
    }

    /**
     * @dev Sets the pending admin
     * @param newPendingAdmin The new pending admin address
     */
    function setPendingAdmin(address newPendingAdmin) external onlyAdmin {
        pendingAdmin = newPendingAdmin;
    }

    /**
     * @dev Accepts admin role
     */
    function acceptAdmin() external {
        require(msg.sender == pendingAdmin, "Only pending admin can accept");
        admin = msg.sender;
        pendingAdmin = address(0);
    }
}
