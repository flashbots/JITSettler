// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IJITSettler } from "./interfaces/IJITSettler.sol";
import { IPrioUpdateRegistry } from "./interfaces/IPrioUpdateRegistry.sol";
import { IRouter } from "./interfaces/IRouter.sol";
import { RouteCodec } from "./libraries/RouteCodec.sol";
import { SafeERC20Min } from "./libraries/SafeERC20Min.sol";

/// @title JITSettler (RFC 2026-10-15)
/// @notice What callers integrate. `swap(req)` executes the route posted to this block's PUR
///         lane for `req`, sends `postingChargeOut + feeOut` to `JITSettlerTreasury` and the rest
///         to the recipient, requires the recipient's share and its MEASURED balance change
///         (`routedOut`) to be at least `max(minOut, simOriginalOut)`, and emits `Settled`.
///         No gas is measured or priced here: the route's gas delta is the builder's sim 2 gate.
///
///         Fully immutable: its `Router`, PUR, treasury, `FEE_BPS` and updater are constructor
///         arguments, with no owner, pin, timelock or pause. An upgrade is a new `JITSettler` +
///         `Router` pair that integrators repoint to. The kill switch is the builder: with no
///         lane posted, `swap` reverts `NoRoute`, and the caller falls back.
///
///         Fund flow: `tokenIn` goes from `msg.sender` straight to the `Router` (one
///         `transferFrom`); the `Router` pays its output here (`routedGrossOut`, measured); this
///         contract splits it between the treasury and the recipient. Nothing is held between
///         calls.
contract JITSettler is IJITSettler {
    using SafeERC20Min for address;

    uint256 internal constant BPS = 10_000;

    IPrioUpdateRegistry public immutable PUR;
    address public immutable ROUTER;
    /// @notice `JITSettlerTreasury`, the one mutable party (hotkey-owned in v1). Receives
    ///         `postingChargeOut + feeOut`.
    address public immutable TREASURY;
    /// @notice Fee on `routedGrossOut - postingChargeOut - simOriginalOut`, in bps, fixed at
    ///         construction: 0 in v1. Not posted per route, so no key can raise it; a change is a
    ///         new pair.
    uint16 public immutable FEE_BPS;
    /// @notice The one key whose signed lanes PUR accepts for this contract (PUR emits
    ///         `UpdaterAdded(this, UPDATER)` at construction). Never added to or removed.
    address public immutable UPDATER;

    // hex of "JITSettlerLock": the transient lock slot is named by its contract
    uint256 private constant _LOCK_SLOT = 0x4a4954536574746c65724c6f636b;

    modifier nonReentrant() {
        uint256 lock;
        assembly ("memory-safe") {
            lock := tload(_LOCK_SLOT)
        }
        require(lock == 0, "reentrancy");
        assembly ("memory-safe") {
            tstore(_LOCK_SLOT, 1)
        }
        _;
        assembly ("memory-safe") {
            tstore(_LOCK_SLOT, 0)
        }
    }

    /// @param updater The key that signs lanes: the existing updater (production
    ///        `0x7BC9141D498e1506B2C5d4C9A661bF7EB28d4B88`; staging its own), held by the
    ///        builder. The builder's relay EOA posts each signed lane in its own update tx,
    ///        immediately before the routed order it serves, as a one-entry PUR
    ///        `batchUpdateStateWithSignature`, and needs no registration. PUR scopes updaters to
    ///        the target, so only this contract can register it, and it does so here, once: no
    ///        add, no remove; a leaked key means a new pair. Other builders' keys are v2.
    constructor(address pur, address router_, address treasury, uint16 feeBps, address updater) {
        require(
            pur != address(0) && router_ != address(0) && treasury != address(0)
                && updater != address(0)
        );
        require(feeBps <= BPS);
        // The pair is deployed Router first, at this contract's predicted address (Q20).
        if (IRouter(router_).SETTLER() != address(this)) revert RouterNotPaired();
        PUR = IPrioUpdateRegistry(pur);
        ROUTER = router_;
        TREASURY = treasury;
        FEE_BPS = feeBps;
        UPDATER = updater;
        IPrioUpdateRegistry(pur).addUpdater(updater);
    }

    // ── Integration surface ──────────────────────────────────────────────────

    /// @inheritdoc IJITSettler
    function laneFor(address caller, Request calldata req) external pure returns (uint256 lane) {
        return RouteCodec.laneIndex(_key(caller, req));
    }

    /// @inheritdoc IJITSettler
    /// @dev RFC "Floor and charge". No gas is read here: an integrator caps what `swap` burns
    ///      with `swap{gas: maxGas}(req)` from its own contract.
    function swap(Request calldata req) external nonReentrant returns (uint256 routedOut) {
        if (
            req.recipient == address(0) || req.recipient == address(this) || req.recipient == ROUTER
        ) revert BadRecipient();
        (bool ok, RouteCodec.Header memory h, uint256[] memory slots) = _lookup(msg.sender, req);
        if (!ok) revert NoRoute();

        // 1. Refuse a route jit-router says will not fit, before any token moves. The only use
        //    of `routedEstGas` here besides `Settled`.
        if (req.maxGas != 0 && h.routedEstGas > req.maxGas) revert GasCapExceeded(req.maxGas);

        // 2. Execute the route; `routedGrossOut` is this contract's measured balance change.
        req.tokenIn.safeTransferFrom(msg.sender, ROUTER, req.amountIn);
        uint256 balanceBefore = req.tokenOut.balanceOf(address(this));
        IRouter(ROUTER)
            .execute(
                IRouter.Endpoints(req.tokenIn, req.tokenOut, req.amountIn, req.recipient), slots
            );
        uint256 routedGrossOut = req.tokenOut.balanceOf(address(this)) - balanceBefore;

        // 3. feeOut = max(0, routedGrossOut - postingChargeOut - simOriginalOut) * FEE_BPS / 1e4
        //    (0 in v1), so the fee alone never takes the recipient below `simOriginalOut`.
        uint256 feeOut = routedGrossOut > h.postingChargeOut + h.simOriginalOut
            ? (routedGrossOut - h.postingChargeOut - h.simOriginalOut) * FEE_BPS / BPS
            : 0;

        // 4. routedGrossOut - postingChargeOut - feeOut >= max(minOut, simOriginalOut), else
        //    revert (the caller falls back).
        uint256 floor = req.minOut > h.simOriginalOut ? req.minOut : h.simOriginalOut;
        if (routedGrossOut < h.postingChargeOut + feeOut) revert BelowFloor(0, floor);
        if (routedGrossOut - h.postingChargeOut - feeOut < floor) {
            revert BelowFloor(routedGrossOut - h.postingChargeOut - feeOut, floor);
        }

        // 5. postingChargeOut + feeOut to the treasury, the rest to `recipient` (the caller's
        //    choice; for 0x and Kyber usually the calling contract), then re-check the
        //    recipient's MEASURED change, `routedOut`, against the same floor (fee-on-transfer,
        //    rebasing).
        uint256 recipientBefore = req.tokenOut.balanceOf(req.recipient);
        if (h.postingChargeOut + feeOut != 0) {
            req.tokenOut.safeTransfer(TREASURY, h.postingChargeOut + feeOut);
        }
        req.tokenOut.safeTransfer(req.recipient, routedGrossOut - h.postingChargeOut - feeOut);
        uint256 recipientAfter = req.tokenOut.balanceOf(req.recipient);
        routedOut = recipientAfter > recipientBefore ? recipientAfter - recipientBefore : 0;
        if (routedOut < floor) revert BelowFloor(routedOut, floor);

        // 6. jit-router's estimates as posted, next to the realized `routedOut`.
        emit Settled(
            msg.sender,
            req.recipient,
            req.tokenIn,
            req.tokenOut,
            req.amountIn,
            h.routedEstOut,
            routedOut,
            h.simOriginalOut,
            h.routedEstGas,
            h.postingChargeOut,
            feeOut
        );
    }

    // ── Internals ────────────────────────────────────────────────────────────

    function _key(address caller, Request calldata req) private pure returns (bytes32) {
        return RouteCodec.laneKey(
            caller, req.tokenIn, req.tokenOut, req.amountIn, req.minOut, req.recipient
        );
    }

    /// @dev A route is read from `req`'s lane only if it was posted for the current block (PUR
    ///      window min = max = block.timestamp). No fingerprint: lanes collide (key % 256), and
    ///      the builder keeps every `swap` in its block off lanes not posted for it (an order
    ///      on a lane already posted this block gets its own update tx right before it). Never
    ///      reverts.
    function _lookup(address caller, Request calldata req)
        private
        view
        returns (bool ok, RouteCodec.Header memory h, uint256[] memory slots)
    {
        bytes32 key = _key(caller, req);
        try PUR.getState(
            RouteCodec.laneIndex(key), uint32(block.timestamp), uint32(block.timestamp)
        ) returns (
            uint32, uint256[] memory s
        ) {
            slots = s;
        } catch {
            return (false, h, slots);
        }
        (ok, h) = RouteCodec.tryDecodeHeader(slots);
        if (!ok) return (false, h, slots);
        if (h.routedEstOut == 0) return (false, h, slots);
        return (true, h, slots);
    }
}
