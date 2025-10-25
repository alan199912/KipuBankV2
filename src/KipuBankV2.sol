// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title KipuBankV2
/// @author Alan Di Masi
/// @notice Multi-token vault (ETH + ERC20) with global cap in USD (USDC-6), Chainlink-princed.
/// @custom:experimental This is an experimental contract.

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

type USD6 is uint256; // user-defined value type for accounting in USD (6 decimals)

contract KipuBankV2 is AccessControl, ReentrancyGuard {
     /*//////////////////////////////////////////////////////////////
                               ROLES
    //////////////////////////////////////////////////////////////*/
    /// @notice Role allowed to pause/unpause the bank.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

     /*//////////////////////////////////////////////////////////////
                        CONSTANTS / IMMUTABLES
    //////////////////////////////////////////////////////////////*/
    /// @notice Native ETH sentinel
    /// @dev We treat ETH as if it were a token at address(0)
    address public constant NATIVE = address(0);

    /// @notice Bank cap in USD6
    /// @dev Immutable to make the rule explicit and cheaper to read.
    USD6 public immutable i_bankCapUsd6;

    /// @notice Optional per-withdraw limit in USD6. Set 0 to disable.
    USD6 public immutable i_withdrawLimitUsd6;

    /*//////////////////////////////////////////////////////////////
                            STORAGE
    //////////////////////////////////////////////////////////////*/
    /// @notice Per-token, per-user balances in token units.
    /// @dev s_balance[token][user] -> amount (token-native decimals).
    mapping(address token => mapping(address user => uint256 amount)) private s_balance;

    /// @notice Aggregated book value in USD6 across all users and tokens.
    /// @dev Updated on every deposit/withdraw using Chainlink prices.
    USD6 private s_totalUsd6;

    /// @notice Registered Chainlink feeds per token.
    /// @dev Must be set before deposits; use NATIVE for ETH.
    mapping(address token => AggregatorV3Interface feed) public s_feed;

    /// @notice Pause flag; when true, state-changing actions are blocked.
    bool public s_paused;

    /*//////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/
     /**
     * @notice Emitted when a deposit succeeds.
     * @param token The asset deposited (address(0) for native ETH).
     * @param user The depositor whose balance increased.
     * @param amountToken The raw token amount (token decimals).
     * @param amountUsd6 The USD6 converted value at the time of deposit.
     * @param timestamp The block timestamp of the operation.
     */
    event Deposited(
        address indexed token,
        address indexed user,
        uint256 amountToken,
        USD6 amountUsd6,
        uint256 timestamp
    );

    /**
     * @notice Emitted when a withdrawal succeeds.
     * @param token The asset withdrawn (address(0) for native ETH).
     * @param user The account whose balance decreased.
     * @param amountToken The raw token amount (token decimals).
     * @param amountUsd6 The USD6 converted value at the time of withdrawal.
     * @param timestamp The block timestamp of the operation.
     */
    event Withdrawn(
        address indexed token,
        address indexed user,
        uint256 amountToken,
        USD6 amountUsd6,
        uint256 timestamp
    );

    /**
     * @notice Emitted when a Chainlink feed is (re)configured for a token.
     * @param token The asset whose feed is being set (address(0) for ETH).
     * @param feed The feed contract address.
     */
    event FeedSet(address indexed token, address indexed feed);

    /**
     * @notice Emitted when the pause status changes.
     * @param status True if paused; false if unpaused.
     */
    event Paused(bool status);

    /*//////////////////////////////////////////////////////////////
                                   ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when an action is attempted while the bank is paused.
    error PausedError();

    /// @notice Thrown when a zero amount is provided where a positive amount is required.
    error ZeroAmount();

    /**
     * @notice Thrown when a deposit would push total USD6 exposure above the cap.
     * @param cap The configured global cap in USD6.
     * @param attempted The resulting total exposure in USD6 if allowed.
     */
    error CapExceeded(USD6 cap, USD6 attempted);

    /**
     * @notice Thrown when a withdrawal exceeds the per-transaction USD6 limit (if enabled).
     * @param requested The requested USD6 value to withdraw.
     * @param limit The configured per-withdraw USD6 limit.
     */
    error WithdrawAboveLimit(USD6 requested, USD6 limit);

    /**
     * @notice Thrown when a user attempts to withdraw more tokens than available.
     * @param requested The requested token amount (raw token decimals).
     * @param available The current token balance for the user.
     */
    error InsufficientBalance(uint256 requested, uint256 available);

    /**
     * @notice Thrown when no Chainlink feed has been configured for the given token.
     * @param token The token address (address(0) for ETH) lacking a feed.
     */
    error FeedNotConfigured(address token);

    /// @notice Thrown when the `msg.value` does not exactly match the declared native amount.
    error NativeMismatch();

    /// @notice Thrown on failed ETH/ERC20 transfers.
    error TransferFailed();

    /// @notice Thrown when an oracle returns a non-positive price.
    error InvalidPrice();

     /*//////////////////////////////////////////////////////////////
                                 MODIFIERS
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Blocks state-changing operations while paused.
     */
    modifier whenNotPaused() {
        if(s_paused) revert PausedError();
        _;
    }

    /**
     * @notice Ensures `amount > 0`.
     * @param amount The amount to validate.
     */
     modifier nonZero(uint256 amount) {
        if(amount == 0) revert ZeroAmount();
        _;
     }

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Initializes roles and immutable parameters.
     * @param bankCapUsd6 Global cap in USD6 (e.g., 5e6 = 5 USDC).
     * @param withdrawLimitUsd6 Per-withdraw limit in USD6 (0 disables the limit).
     * @param admin Address receiving DEFAULT_ADMIN_ROLE and PAUSER_ROLE.
     */
    constructor(USD6 bankCapUsd6, USD6 withdrawLimitUsd6, address admin) {
        i_bankCapUsd6 = bankCapUsd6;
        i_withdrawLimitUsd6 = withdrawLimitUsd6;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
    }

    /*//////////////////////////////////////////////////////////////
                           ADMIN / CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets the Chainlink feed for a token (use NATIVE for ETH).
     * @dev The feed must expose `latestRoundData()` and `decimals()`.
     * @param token The asset whose feed is being set (address(0) for ETH).
     * @param feed The Chainlink AggregatorV3Interface contract.
     */
    function setFeed(address token, AggregatorV3Interface feed)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        s_feed[token] = feed;
        emit FeedSet(token, address(feed));
    }

    /**
     * @notice Toggles paused status for sensitive functions.
     * @param status True to pause; false to unpause.
     */
    function pause(bool status) external onlyRole(PAUSER_ROLE) {
        s_paused = status;
        emit Paused(status);
    }

    /*//////////////////////////////////////////////////////////////
                                DEPOSITS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposits native ETH. `msg.value` must equal `amount`.
     * @param amount The native amount in wei to deposit.
     *
     * @dev CEI + nonReentrant. Increments user balance and total USD6 exposure.
     * Reverts if the bank cap would be exceeded or the price is invalid.
     */
    function depositETH(uint256 amount)
        external
        payable
        whenNotPaused
        nonReentrant
        nonZero(amount)
    {
        if (msg.value != amount) revert NativeMismatch();
        _deposit(NATIVE, msg.sender, amount);
    }

    /**
     * @notice Deposits an ERC20 token. Caller must `approve` first.
     * @param token The ERC20 address.
     * @param amount The token amount (raw token decimals).
     *
     * @dev CEI + nonReentrant. Pulls tokens then updates accounting.
     */
    function depositERC20(address token, uint256 amount)
        external
        whenNotPaused
        nonReentrant
        nonZero(amount)
    {
        _pullToken(token, msg.sender, amount);
        _deposit(token, msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                               WITHDRAWALS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Withdraws native ETH.
     * @param amount The native amount in wei to withdraw.
     *
     * @dev CEI + nonReentrant. Validates balance, optional USD6 per-withdraw limit,
     * updates accounting, then transfers ETH via `call`.
     */
    function withdrawETH(uint256 amount)
        external
        whenNotPaused
        nonReentrant
        nonZero(amount)
    {
        _withdraw(NATIVE, msg.sender, amount);
        _sendETH(payable(msg.sender), amount);
    }

    /**
     * @notice Withdraws an ERC20 token.
     * @param token The ERC20 address.
     * @param amount The token amount (raw token decimals).
     *
     * @dev CEI + nonReentrant. Validates balance, optional USD6 per-withdraw limit,
     * updates accounting, then transfers tokens.
     */
    function withdrawERC20(address token, uint256 amount)
        external
        whenNotPaused
        nonReentrant
        nonZero(amount)
    {
        _withdraw(token, msg.sender, amount);
        _pushToken(token, msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                   VIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the stored balance for a user and token.
     * @param token The asset (address(0) for ETH).
     * @param user The account to query.
     * @return balance The raw token amount (token decimals).
     */
    function balanceOf(address token, address user)
        external
        view
        returns (uint256 balance)
    {
        return s_balance[token][user];
    }

    /**
     * @notice Returns aggregate USD6 exposure, global cap, and per-withdraw limit.
     * @return totalUsd6 Current total exposure in USD6.
     * @return capUsd6 Global cap in USD6.
     * @return withdrawLimitUsd6 Per-withdraw limit in USD6 (0 if disabled).
     */
    function totals()
        external
        view
        returns (USD6 totalUsd6, USD6 capUsd6, USD6 withdrawLimitUsd6)
    {
        return (s_totalUsd6, i_bankCapUsd6, i_withdrawLimitUsd6);
    }

    /*//////////////////////////////////////////////////////////////
                               INTERNAL CORE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Internal deposit flow: converts to USD6, checks cap, updates balances, emits event.
     * @param token The asset (address(0) for ETH).
     * @param user The depositor.
     * @param amount The raw token amount (token decimals).
     */
    function _deposit(address token, address user, uint256 amount) internal {
        AggregatorV3Interface feed = s_feed[token];
        if (address(feed) == address(0)) revert FeedNotConfigured(token);

        USD6 usd6 = _toUSD6(token, amount, feed);

        // Cap check: ensure new total won't exceed cap
        USD6 newTotal = USD6.wrap(USD6.unwrap(s_totalUsd6) + USD6.unwrap(usd6));
        if (USD6.unwrap(newTotal) > USD6.unwrap(i_bankCapUsd6)) {
            revert CapExceeded(i_bankCapUsd6, newTotal);
        }

        // EFFECTS (proven-safe unchecked writes)
        unchecked {
            s_balance[token][user] = s_balance[token][user] + amount;
            s_totalUsd6 = newTotal;
        }

        emit Deposited(token, user, amount, usd6, block.timestamp);
    }

    /**
     * @notice Internal withdraw flow: validates balance and optional USD6 limit, updates storage, emits.
     * @param token The asset (address(0) for ETH).
     * @param user The account withdrawing.
     * @param amount The raw token amount (token decimals).
     */
    function _withdraw(address token, address user, uint256 amount) internal {
        uint256 bal = s_balance[token][user];
        if (amount > bal) revert InsufficientBalance(amount, bal);

        AggregatorV3Interface feed = s_feed[token];
        if (address(feed) == address(0)) revert FeedNotConfigured(token);

        USD6 usd6 = _toUSD6(token, amount, feed);

        // Optional per-withdraw USD6 limit
        if (USD6.unwrap(i_withdrawLimitUsd6) != 0 && USD6.unwrap(usd6) > USD6.unwrap(i_withdrawLimitUsd6)) {
            revert WithdrawAboveLimit(usd6, i_withdrawLimitUsd6);
        }

        // EFFECTS (proven-safe unchecked writes)
        unchecked {
            s_balance[token][user] = bal - amount; // safe due to check above
            s_totalUsd6 = USD6.wrap(USD6.unwrap(s_totalUsd6) - USD6.unwrap(usd6));
        }

        emit Withdrawn(token, user, amount, usd6, block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                         TRANSFERS & CONVERSIONS (PRIVATE)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Pulls ERC20 from `from` to this contract.
     * @param token ERC20 address.
     * @param from Payer address.
     * @param amount Raw token amount (token decimals).
     */
    function _pullToken(address token, address from, uint256 amount) private {
        bool ok = IERC20(token).transferFrom(from, address(this), amount);
        if (!ok) revert TransferFailed();
    }

    /**
     * @notice Pushes ERC20 to `to` from this contract.
     * @param token ERC20 address.
     * @param to Recipient address.
     * @param amount Raw token amount (token decimals).
     */
    function _pushToken(address token, address to, uint256 amount) private {
        bool ok = IERC20(token).transfer(to, amount);
        if (!ok) revert TransferFailed();
    }

    /**
     * @notice Sends native ETH with proper revert on failure.
     * @param to Recipient address.
     * @param amount Amount in wei.
     */
    function _sendETH(address payable to, uint256 amount) private {
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /**
     * @notice Converts a `token` amount to USD6 using a Chainlink feed.
     * @dev Assumes the feed returns token/USD with `feed.decimals()` (commonly 8).
     * @param token Asset address (address(0) for ETH). Used to read token decimals (18 for native).
     * @param amount Raw token amount (token decimals).
     * @param feed Chainlink AggregatorV3Interface (token/USD).
     * @return usd6Value Amount converted to USD6.
     */
    function _toUSD6(
        address token,
        uint256 amount,
        AggregatorV3Interface feed
    ) private view returns (USD6 usd6Value) {
        uint8 tokenDec = token == NATIVE ? 18 : IERC20Metadata(token).decimals();
        (, int256 price,,,) = feed.latestRoundData();
        if (price <= 0) revert InvalidPrice();
        uint8 priceDec = feed.decimals();

        // Convert: amount[tokenDec] * price[USD priceDec] -> USD6
        // USD6 = amount * price * 10^6 / 10^(tokenDec + priceDec)
        uint256 numerator = uint256(price) * amount;

        // scale down by (tokenDec + priceDec - 6)
        uint32 pow = uint32(uint256(tokenDec) + uint256(priceDec) - 6);
        uint256 usd = _scaleDown10(numerator, pow);
        return USD6.wrap(usd);
    }

    /**
     * @notice Scales `x` down by 10^pow.
     * @dev For small pow this loop is fine; for larger pow, consider an optimized 10**pow table.
     * @param x The input value.
     * @param pow Decimal exponent to scale down by.
     * @return y x / 10^pow
     */
    function _scaleDown10(uint256 x, uint32 pow) private pure returns (uint256 y) {
        if (pow == 0) return x;
        uint256 d = 1;
        unchecked {
            for (uint32 i; i < pow; ++i) {
                d *= 10;
            }
        }
        return x / d;
    }

    /*//////////////////////////////////////////////////////////////
                              RECEIVE / FALLBACK
    //////////////////////////////////////////////////////////////*/

    /// @notice Direct native transfers are not allowed; use depositETH().
    receive() external payable { revert NativeMismatch(); }

    /// @notice Direct calls without data are not allowed; use the typed functions.
    fallback() external payable { revert NativeMismatch(); }

}

