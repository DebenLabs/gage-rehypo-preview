// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IRehypoPriceSource} from "../interfaces/rehypo/IRehypoPriceSource.sol";

/// @title RehypoNavPriceSource
/// @notice A fund token's price for a rehypo pool on a guarded daily NAV: the token's manager signs each day's NAV, and
/// the pool's anchor follows it within on-chain limits. A second, independent signer (gage's keeper, from a licensed
/// London feed) signs the fund's London price, used only as a brake. While any rule says the anchor cannot be trusted
/// the source is shut: `valueOf` refuses, and a rehypo source reading it through a `RehypoGuardedPriceSource` pulls its
/// swap float instead of leaving its last position trading.
///
/// The rules:
/// - Each NAV report is signed by `navSigner`, newer than the last (its valuation time) and at most `NAV_MAX_AGE` old;
///   once the last NAV is older than that the source is shut.
/// - The anchor is the NAV, moved at most `MAX_DAILY_MOVE_BPS` from the anchor at the start of the London day (07:00
///   UTC, by the block's time): a cap, not a refusal. While the anchor is capped (short of the NAV) the source is shut;
///   each later NAV report moves it on, so it catches up at the cap's pace.
/// - An anchor move of more than `BREAKER_BPS` from the London day's start shuts the source until a NAV report moves
///   the anchor less (a calm NAV).
/// - Two consecutive London reports further than `LONDON_DEV_BPS` from the anchor shut it; it reopens after
///   `REOPEN_SECONDS` of consecutive London reports within half of that. Reports are consecutive when no more than
///   `LONDON_MAX_GAP` apart; each is newer than the last and at most `LONDON_MAX_AGE` old, so no old or replayed print
///   reopens it, and one stale print never does.
/// - A signer changes only after `SIGNER_DELAY` (no instant feed switch). The owner may revoke a signer at once, which
///   only shuts the source until a new one is applied.
/// @dev Reports are EIP-712 typed data for this contract on this chain (`NavReport`, `LondonReport`), posted by anyone:
/// the signature, not the sender, is what counts. Prices have eight decimals, in US dollars per whole token; values are
/// in `USDG`, taken at a dollar, as `NuntiusPriceSource` takes it. `valueOf` reads the state the reports left and takes
/// no report of its own, so a rehypo source's keeper brings an empty one. The owner is gage's deployment EOA. The
/// rules' values are fixed at deployment, each within a compile-time bound (`RulesSet`).
contract RehypoNavPriceSource is IRehypoPriceSource, Ownable2Step, EIP712 {
    /// @notice The two signers: the NAV's (the fund token's manager) and the London price's (gage's keeper).
    enum Role {
        Nav,
        London
    }

    /// @notice What the deployment fixes: the NAV's age limit, the anchor's daily cap, the breaker, the London brake's
    /// deviation and its reopen delay.
    struct Rules {
        uint32 navMaxAge;
        uint16 maxDailyMoveBps;
        uint16 breakerBps;
        uint16 londonDevBps;
        uint32 reopenSeconds;
    }

    /// @notice A signer the owner queued, and when anyone may apply it.
    struct PendingSigner {
        address signer;
        uint40 readyAt;
    }

    uint16 public constant BPS = 10_000;
    /// @notice The bounds of `NAV_MAX_AGE`: one trading day plus a weekend is about four days.
    uint32 public constant MIN_NAV_MAX_AGE = 1 days;
    uint32 public constant MAX_NAV_MAX_AGE = 7 days;
    /// @notice The widest daily cap on the anchor's move.
    uint16 public constant MAX_DAILY_MOVE_LIMIT_BPS = 300;
    /// @notice The bounds of the London brake's deviation: at least two, so half of it is a basis point.
    uint16 public constant MIN_LONDON_DEV_BPS = 2;
    uint16 public constant MAX_LONDON_DEV_BPS = 300;
    /// @notice The bounds of the London brake's reopen delay.
    uint32 public constant MIN_REOPEN_SECONDS = 30 minutes;
    uint32 public constant MAX_REOPEN_SECONDS = 1 days;
    /// @notice The oldest London report accepted.
    uint32 public constant LONDON_MAX_AGE = 10 minutes;
    /// @notice The longest gap between two London reports that still counts them as consecutive.
    uint32 public constant LONDON_MAX_GAP = 15 minutes;
    /// @notice How far ahead of the block a report's time may run (the signer's clock against the chain's).
    uint32 public constant MAX_FUTURE_SKEW = 1 minutes;
    /// @notice When a London day starts, after midnight UTC: before the London open in winter and in summer.
    uint32 public constant DAY_START = 7 hours;
    /// @notice The wait before a queued signer may be applied.
    uint32 public constant SIGNER_DELAY = 3 days;
    /// @notice The prices' decimals.
    uint8 public constant PRICE_DECIMALS = 8;
    /// @notice The most decimals the token or USDG may have here.
    uint8 public constant MAX_DECIMALS = 18;

    /// @notice Why the source is shut, as bits of `shutReasons`: no NAV yet, the NAV too old, the anchor capped, the
    /// breaker, the London brake, a signer missing.
    uint8 public constant NO_NAV = 1;
    uint8 public constant STALE = 2;
    uint8 public constant CAPPED = 4;
    uint8 public constant BREAKER = 8;
    uint8 public constant LONDON = 16;
    uint8 public constant NO_SIGNER = 32;

    bytes32 public constant NAV_TYPEHASH = keccak256("NavReport(address token,uint256 nav,uint256 navTime)");
    bytes32 public constant LONDON_TYPEHASH = keccak256("LondonReport(address token,uint256 price,uint256 observedAt)");

    /// @inheritdoc IRehypoPriceSource
    address public immutable USDG;
    /// @notice The fund token this source prices.
    address public immutable TOKEN;
    uint8 internal immutable USDG_DECIMALS;
    uint8 internal immutable TOKEN_DECIMALS;
    /// @notice The oldest NAV, by its valuation time, the source opens on.
    uint32 public immutable NAV_MAX_AGE;
    /// @notice The most the anchor moves in a London day, in basis points of its value at the day's start.
    uint16 public immutable MAX_DAILY_MOVE_BPS;
    /// @notice An anchor move in a London day above this shuts the source until a calm NAV.
    uint16 public immutable BREAKER_BPS;
    /// @notice Two consecutive London reports further than this from the anchor shut the source.
    uint16 public immutable LONDON_DEV_BPS;
    /// @notice How long London reports must stay within half of `LONDON_DEV_BPS` to reopen the source.
    uint32 public immutable REOPEN_SECONDS;

    /// @notice Each role's signer; zero once revoked.
    mapping(Role role => address signer) public signerOf;
    /// @notice Each role's queued signer, if any.
    mapping(Role role => PendingSigner pending) public pendingSignerOf;

    /// @notice The last NAV accepted, its valuation time, the London day the anchor last moved in, and whether the
    /// breaker holds.
    uint128 public nav;
    uint40 public navTime;
    uint32 public navDay;
    bool public breaker;
    /// @notice The anchor, and its value at the start of the London day it last moved in.
    uint128 public anchor;
    uint128 public dayAnchor;
    /// @notice The last London report accepted and its time; when the current run of calm reports began (zero when
    /// none runs); whether the last report was beyond `LONDON_DEV_BPS`; whether the London brake holds.
    uint128 public londonPrice;
    uint40 public londonAt;
    uint40 public calmSince;
    bool public londonBeyond;
    bool public londonShut;

    /// @notice What the deployment fixed (`Rules`).
    event RulesSet(
        uint32 navMaxAge, uint16 maxDailyMoveBps, uint16 breakerBps, uint16 londonDevBps, uint32 reopenSeconds
    );
    /// @notice A NAV report was accepted: the NAV, its valuation time, the anchor it left, whether that anchor is capped
    /// short of the NAV and whether the breaker holds.
    event NavPosted(uint256 nav, uint256 navTime, uint256 anchor, bool capped, bool breaker);
    /// @notice A London report was accepted: its price and time, whether it was beyond `LONDON_DEV_BPS` from the anchor,
    /// and whether the London brake holds after it.
    event LondonPosted(uint256 price, uint256 observedAt, bool beyond, bool shut);
    event SignerQueued(Role indexed role, address indexed signer, uint40 readyAt);
    event SignerCancelled(Role indexed role, address indexed signer);
    /// @notice `role`'s signer is `signer` from now on; zero when revoked.
    event SignerSet(Role indexed role, address indexed signer);

    /// @dev A bound, an address or a signer the constructor or a signer change refuses.
    error InvalidConfiguration();
    error NoAsset(address token);
    /// @notice This source reads its own state: the report a rehypo source's keeper brings must be empty.
    error ReportNotEmpty();
    /// @notice The source is shut, for the `shutReasons` bits given.
    error Shut(uint8 reasons);
    error ZeroValue(address token, uint256 amount);
    error InvalidPrice(uint256 price);
    /// @notice A report no newer than the last one accepted of its kind.
    error NotNewer(uint256 at, uint256 last);
    /// @notice A report older than its kind's limit, or further ahead of the block than `MAX_FUTURE_SKEW`.
    error OutOfDate(uint256 at);
    /// @notice The signature recovers to no one, or to someone other than the role's signer.
    error InvalidSignature(address recovered);
    /// @notice A London report before any NAV: there is no anchor to hold it to.
    error NoNav();
    error NoPendingSigner(Role role);
    error SignerTooEarly(uint40 readyAt);

    /// @param usdg The asset values are given in, taken at a dollar: the price router's USDG.
    /// @param token The fund token.
    /// @param admin The owner, who queues and revokes signers.
    /// @param navSigner The NAV's signer (the fund token's manager).
    /// @param londonSigner The London price's signer, another key than the NAV's.
    /// @param rules The rules' values, each within its bound: `NAV_MAX_AGE` from `MIN_NAV_MAX_AGE` to
    ///        `MAX_NAV_MAX_AGE`, `MAX_DAILY_MOVE_BPS` from one to `MAX_DAILY_MOVE_LIMIT_BPS`, `BREAKER_BPS` from one to
    ///        `MAX_DAILY_MOVE_BPS`, `LONDON_DEV_BPS` from `MIN_LONDON_DEV_BPS` to `MAX_LONDON_DEV_BPS`, `REOPEN_SECONDS`
    ///        from `MIN_REOPEN_SECONDS` to `MAX_REOPEN_SECONDS`.
    constructor(
        IERC20Metadata usdg,
        IERC20Metadata token,
        address admin,
        address navSigner,
        address londonSigner,
        Rules memory rules
    ) Ownable(admin) EIP712("gage NAV price source", "1") {
        if (address(usdg).code.length == 0 || address(token).code.length == 0 || address(token) == address(usdg)) {
            revert InvalidConfiguration();
        }
        if (navSigner == address(0) || londonSigner == address(0) || navSigner == londonSigner) {
            revert InvalidConfiguration();
        }
        if (
            rules.navMaxAge < MIN_NAV_MAX_AGE || rules.navMaxAge > MAX_NAV_MAX_AGE || rules.maxDailyMoveBps == 0
                || rules.maxDailyMoveBps > MAX_DAILY_MOVE_LIMIT_BPS || rules.breakerBps == 0
                || rules.breakerBps > rules.maxDailyMoveBps || rules.londonDevBps < MIN_LONDON_DEV_BPS
                || rules.londonDevBps > MAX_LONDON_DEV_BPS || rules.reopenSeconds < MIN_REOPEN_SECONDS
                || rules.reopenSeconds > MAX_REOPEN_SECONDS
        ) revert InvalidConfiguration();
        uint8 usdgDecimals = usdg.decimals();
        uint8 tokenDecimals = token.decimals();
        if (usdgDecimals > MAX_DECIMALS || tokenDecimals > MAX_DECIMALS) revert InvalidConfiguration();
        USDG = address(usdg);
        TOKEN = address(token);
        USDG_DECIMALS = usdgDecimals;
        TOKEN_DECIMALS = tokenDecimals;
        NAV_MAX_AGE = rules.navMaxAge;
        MAX_DAILY_MOVE_BPS = rules.maxDailyMoveBps;
        BREAKER_BPS = rules.breakerBps;
        LONDON_DEV_BPS = rules.londonDevBps;
        REOPEN_SECONDS = rules.reopenSeconds;
        signerOf[Role.Nav] = navSigner;
        signerOf[Role.London] = londonSigner;
        emit RulesSet(rules.navMaxAge, rules.maxDailyMoveBps, rules.breakerBps, rules.londonDevBps, rules.reopenSeconds);
        emit SignerSet(Role.Nav, navSigner);
        emit SignerSet(Role.London, londonSigner);
    }

    // ---------------------------------------------------------------- price source

    /// @inheritdoc IRehypoPriceSource
    /// @dev The token's asset is its own id, the NAV's age limit, no sources, its decimals, never a Stock Token; any
    /// other token has none.
    function assetOf(address token)
        external
        view
        returns (bytes32 assetId, uint32 maxAge, uint8 minSources, uint8 tokenDecimals, bool stockToken)
    {
        if (token != TOKEN) return (bytes32(0), 0, 0, 0, false);
        return (keccak256(abi.encode("NAV/USD", token)), NAV_MAX_AGE, 0, TOKEN_DECIMALS, false);
    }

    /// @notice What `amount` raw units of the fund token are worth in raw units of USDG at the anchor, rounded down,
    /// observed now: the rules are read at the block's time.
    /// @dev Reverts `Shut` with its reasons while any rule shuts the source, so a guarded price source pulls.
    /// @param report Must be empty.
    function valueOf(address token, uint256 amount, bytes calldata report)
        external
        view
        returns (uint256 value, uint256 observedAt)
    {
        if (token != TOKEN) revert NoAsset(token);
        if (report.length != 0) revert ReportNotEmpty();
        uint8 reasons = shutReasons();
        if (reasons != 0) revert Shut(reasons);
        value = Math.mulDiv(
            amount, uint256(anchor) * 10 ** USDG_DECIMALS, 10 ** (uint256(TOKEN_DECIMALS) + PRICE_DECIMALS)
        );
        if (value == 0) revert ZeroValue(token, amount);
        observedAt = block.timestamp;
    }

    /// @notice Why the source is shut now, as bits (`NO_NAV`, `STALE`, `CAPPED`, `BREAKER`, `LONDON`, `NO_SIGNER`);
    /// zero when it is open.
    function shutReasons() public view returns (uint8 reasons) {
        uint256 a = anchor;
        if (a == 0) reasons = NO_NAV;
        else if (block.timestamp > uint256(navTime) + NAV_MAX_AGE) reasons = STALE;
        if (a != nav) reasons |= CAPPED;
        if (breaker) reasons |= BREAKER;
        if (londonShut) reasons |= LONDON;
        if (signerOf[Role.Nav] == address(0) || signerOf[Role.London] == address(0)) reasons |= NO_SIGNER;
    }

    /// @notice The London day `t` falls in: days counted from `DAY_START` UTC.
    function londonDay(uint256 t) public pure returns (uint32) {
        return uint32((t + 1 days - DAY_START) / 1 days);
    }

    // ---------------------------------------------------------------- reports

    /// @notice Post a NAV report `navSigner` signed: the anchor moves to the NAV, at most `MAX_DAILY_MOVE_BPS` from its
    /// value at the start of this London day, and the breaker holds while this day's move is more than `BREAKER_BPS`.
    /// The first NAV sets the anchor. Anyone.
    /// @param nav_ The NAV per whole token, in US dollars with eight decimals.
    /// @param navTime_ Its valuation time: newer than the last NAV's, at most `NAV_MAX_AGE` old, not ahead of the
    ///        block by more than `MAX_FUTURE_SKEW`.
    /// @param signature The NAV signer's EIP-712 signature of `NavReport(token, nav, navTime)`.
    function postNav(uint256 nav_, uint256 navTime_, bytes calldata signature) external {
        if (nav_ == 0 || nav_ > type(uint128).max) revert InvalidPrice(nav_);
        uint256 last = navTime;
        if (navTime_ <= last) revert NotNewer(navTime_, last);
        if (navTime_ > block.timestamp + MAX_FUTURE_SKEW || navTime_ + NAV_MAX_AGE < block.timestamp) {
            revert OutOfDate(navTime_);
        }
        _checkSignature(Role.Nav, keccak256(abi.encode(NAV_TYPEHASH, TOKEN, nav_, navTime_)), signature);
        uint32 today = londonDay(block.timestamp);
        uint256 previous = anchor;
        uint256 next = nav_;
        bool trip;
        if (previous == 0) {
            dayAnchor = uint128(nav_);
        } else {
            uint256 start = dayAnchor;
            if (today != navDay) {
                start = previous;
                dayAnchor = uint128(previous);
            }
            uint256 lo = Math.mulDiv(start, BPS - MAX_DAILY_MOVE_BPS, BPS, Math.Rounding.Ceil);
            uint256 hi = Math.mulDiv(start, BPS + MAX_DAILY_MOVE_BPS, BPS);
            next = Math.min(Math.max(next, lo), hi);
            uint256 move = next > start ? next - start : start - next;
            trip = move * BPS > uint256(BREAKER_BPS) * start;
        }
        nav = uint128(nav_);
        navTime = uint40(navTime_);
        navDay = today;
        breaker = trip;
        anchor = uint128(next);
        // A calm London run is held to the anchor it ran against.
        if (next != previous) calmSince = 0;
        emit NavPosted(nav_, navTime_, next, next != nav_, trip);
    }

    /// @notice Post a London report `londonSigner` signed. Beyond `LONDON_DEV_BPS` from the anchor, and the last report
    /// beyond it too and consecutive, the London brake holds. Within half of it, the report continues a calm run (or
    /// starts one), and a run `REOPEN_SECONDS` long lifts the brake. Anything else ends the run. Anyone.
    /// @param price The London price per whole token, in US dollars with eight decimals.
    /// @param observedAt When it was observed: newer than the last London report's, at most `LONDON_MAX_AGE` old, not
    ///        ahead of the block by more than `MAX_FUTURE_SKEW`.
    /// @param signature The London signer's EIP-712 signature of `LondonReport(token, price, observedAt)`.
    function postLondon(uint256 price, uint256 observedAt, bytes calldata signature) external {
        uint256 a = anchor;
        if (a == 0) revert NoNav();
        if (price == 0 || price > type(uint128).max) revert InvalidPrice(price);
        uint256 last = londonAt;
        if (observedAt <= last) revert NotNewer(observedAt, last);
        if (observedAt > block.timestamp + MAX_FUTURE_SKEW || observedAt + LONDON_MAX_AGE < block.timestamp) {
            revert OutOfDate(observedAt);
        }
        _checkSignature(Role.London, keccak256(abi.encode(LONDON_TYPEHASH, TOKEN, price, observedAt)), signature);
        bool consecutive = last != 0 && observedAt - last <= LONDON_MAX_GAP;
        uint256 deviation = (price > a ? price - a : a - price) * BPS;
        bool shut = londonShut;
        uint256 calm = calmSince;
        bool beyond = deviation > uint256(LONDON_DEV_BPS) * a;
        if (beyond) {
            if (consecutive && londonBeyond) shut = true;
            calm = 0;
        } else if (deviation * 2 <= uint256(LONDON_DEV_BPS) * a) {
            if (!consecutive || calm == 0) calm = observedAt;
            if (shut && observedAt - calm >= REOPEN_SECONDS) shut = false;
        } else {
            calm = 0;
        }
        londonPrice = uint128(price);
        londonAt = uint40(observedAt);
        calmSince = uint40(calm);
        londonBeyond = beyond;
        londonShut = shut;
        emit LondonPosted(price, observedAt, beyond, shut);
    }

    // ---------------------------------------------------------------- owner

    /// @notice Queue `signer` for `role`; anyone applies it `SIGNER_DELAY` later. A new queue replaces the last.
    /// @param role The NAV's or the London price's.
    /// @param signer The new signer: not zero, not the role's signer now.
    function queueSigner(Role role, address signer) external onlyOwner {
        if (signer == address(0) || signer == signerOf[role]) revert InvalidConfiguration();
        uint40 readyAt = uint40(block.timestamp) + SIGNER_DELAY;
        pendingSignerOf[role] = PendingSigner(signer, readyAt);
        emit SignerQueued(role, signer, readyAt);
    }

    /// @notice Drop `role`'s queued signer.
    function cancelSigner(Role role) external onlyOwner {
        address queued = pendingSignerOf[role].signer;
        if (queued == address(0)) revert NoPendingSigner(role);
        delete pendingSignerOf[role];
        emit SignerCancelled(role, queued);
    }

    /// @notice Apply `role`'s queued signer once `SIGNER_DELAY` has run, unless it is the other role's signer: the two
    /// stay independent. A new London signer starts its reports afresh: the last report's time, the calm run and the
    /// last deviation are cleared, and the brake stays as it was. Anyone.
    function applySigner(Role role) external {
        PendingSigner memory p = pendingSignerOf[role];
        if (p.signer == address(0)) revert NoPendingSigner(role);
        if (block.timestamp < p.readyAt) revert SignerTooEarly(p.readyAt);
        if (p.signer == signerOf[role == Role.Nav ? Role.London : Role.Nav]) revert InvalidConfiguration();
        delete pendingSignerOf[role];
        signerOf[role] = p.signer;
        if (role == Role.London) {
            londonAt = 0;
            calmSince = 0;
            londonBeyond = false;
        }
        emit SignerSet(role, p.signer);
    }

    /// @notice Revoke `role`'s signer at once: its reports are refused and the source is shut (`NO_SIGNER`) until a new
    /// signer is applied after `SIGNER_DELAY`. It can only shut the source, never move or open it.
    function revokeSigner(Role role) external onlyOwner {
        if (signerOf[role] == address(0)) revert InvalidConfiguration();
        signerOf[role] = address(0);
        emit SignerSet(role, address(0));
    }

    // ---------------------------------------------------------------- internals

    /// @dev `signature` over `structHash` in this contract's EIP-712 domain recovers to `role`'s signer.
    function _checkSignature(Role role, bytes32 structHash, bytes calldata signature) internal view {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(_hashTypedDataV4(structHash), signature);
        if (err != ECDSA.RecoverError.NoError || recovered != signerOf[role]) revert InvalidSignature(recovered);
    }
}
