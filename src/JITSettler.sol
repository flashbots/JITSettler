// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "./IERC20.sol";

/// @notice A swap request. Same field order and types as JITSettler v1.3.0, so `swap(Request)`
///         keeps its selector.
struct Request {
    address tokenIn;
    address tokenOut;
    uint256 amountIn;
    uint256 amountOutMin;
    address recipient;
    /// @dev The most gas the caller gives the route, for builders to read. The settler does not
    ///      enforce it; the caller caps its own call.
    uint256 gasLimit;
}

/// @notice Events of the JIT settler standard. Both swap paths emit `JITRoutedV1` on a fill.
///         `reportDefault` emits `JITDefaultV1` for a caller that ran its own default route.
interface IJITEvents {
    /// @notice A swap filled through a posted route. `caller` called the settler, `setter`
    ///         posted the route, `executor` ran it.
    event JITRoutedV1(
        address indexed caller,
        address indexed setter,
        address indexed executor,
        address tokenIn,
        address tokenOut,
        address recipient,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 amountOut
    );

    /// @notice `reporter` ran its own default route. `amountOut` is what the recipient received
    ///         from it, as the reporter says. Builders count a report only when `reporter` is the
    ///         contract that called `peek` or a swap function.
    event JITDefaultV1(
        address indexed reporter,
        address indexed tokenIn,
        address indexed tokenOut,
        address recipient,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 amountOut
    );
}

/// @notice Implemented by callers of `swapWithCallback`.
interface ISettlerCaller {
    /// @notice Called by `swapWithCallback` when a route is live. Return the least `recipient`
    ///         must receive to run it, or revert to decline it.
    function routeAvailable(address setter) external returns (uint256 amountOutMin);
}

/// @title JITSettler
/// @notice Based on Gattaca's JIT settler PoC (gattaca-com/jit-settler-poc). Two ways to call it:
///         `peek` + `swap` (the caller passes its floor and reverts on no route), or
///         `swapWithCallback` (the settler asks the caller for its floor and returns the outcome).
contract JITSettler is IJITEvents {
    enum Outcome {
        NO_ROUTE,
        ROUTE_DECLINED,
        EXECUTED
    }

    struct RouteHeader {
        address setter;
        uint64 timestamp;
        uint32 dataLength;
        address executor;
    }

    // Words past dataLength are stale but ignored, and rewriting non-zero slots is cheap.
    uint256 private constant _ROUTE_DATA_SLOT = uint256(keccak256("Settler.route.data"));

    Sandbox public immutable SANDBOX = new Sandbox();

    RouteHeader private _routeHeader;

    // The route the settler is running, set only while its executor runs.
    address private transient _currentSetter;
    address private transient _currentCaller;

    // Counts `setRoute` calls in this transaction, so `swapWithCallback` can tell whether its
    // callback overwrote the route data it has not loaded yet.
    uint256 private transient _routeWrites;

    error NoRoute();
    error TransferFailed();
    error InsufficientOutput(uint256 amountOut, uint256 amountOutMin);

    /// @notice Posts the route for this block. The setter is msg.sender. A builder can post
    ///         through its own contract, so it can rotate keys without callers changing the
    ///         setters they trust.
    function setRoute(address executor, bytes calldata data) external {
        _routeHeader =
            RouteHeader(msg.sender, uint64(block.timestamp), uint32(data.length), executor);
        _storeRouteData(data);
        unchecked {
            _routeWrites++;
        }
    }

    /// @notice The setter of the route live in this block, or 0 if there is none.
    /// @dev Takes the request so a builder can read it from the call in a simulation where no
    ///      route is posted yet. The request is not used on chain.
    function peek(Request calldata) external view returns (address setter) {
        RouteHeader storage header = _routeHeader;
        if (_isLive(header)) return header.setter;
    }

    /// @notice Runs the live route for `req`. Reverts if there is none, if the route fails, or if
    ///         `recipient` receives less than `req.amountOutMin`. Call it in try/catch with a gas
    ///         cap, and fall back on any revert; revert data may come from the executor. The
    ///         settler does not enforce `req.gasLimit`: the route gets all the gas the call has.
    /// @return amountOut What `recipient` received.
    function swap(Request calldata req) external returns (uint256 amountOut) {
        (bool live, RouteHeader memory header) = _consumeRoute();
        if (!live) revert NoRoute();
        // Loaded before any external call, so a reentrant setRoute can't change it.
        bytes memory data = _loadRouteData(header.dataLength);
        return _execute(
            header, data, req.tokenIn, req.tokenOut, req.amountIn, req.amountOutMin, req.recipient
        );
    }

    /// @notice Runs the live route if the caller accepts it. The settler calls
    ///         `routeAvailable(setter)` on msg.sender, which returns its floor or reverts to
    ///         decline. A declined route stays used, and its data is never loaded, so declining a
    ///         large route costs little. If the callback posts a route, the call counts as
    ///         declined. After the caller accepts, it reverts if the route fails: the transfer of
    ///         tokenIn fails, the executor reverts or has no code, or `recipient` gets less than
    ///         the floor. Treat any revert as a failed route; its data may come from the executor.
    ///         The last argument is the request's gas limit, for builders to read. The settler
    ///         does not enforce it: cap your own call.
    /// @return outcome Whether the route ran. Unless `EXECUTED`, run your default route.
    /// @return amountOut What `recipient` received if `EXECUTED`, else 0.
    function swapWithCallback(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address recipient,
        uint256 /* gasLimit */
    ) external returns (Outcome outcome, uint256 amountOut) {
        (bool live, RouteHeader memory header) = _consumeRoute();
        if (!live) return (Outcome.NO_ROUTE, 0);
        uint256 writes = _routeWrites;
        (bool accepted, uint256 amountOutMin) = _askCaller(header.setter);
        if (!accepted || _routeWrites != writes) return (Outcome.ROUTE_DECLINED, 0);
        bytes memory data = _loadRouteData(header.dataLength);
        amountOut = _execute(header, data, tokenIn, tokenOut, amountIn, amountOutMin, recipient);
        return (Outcome.EXECUTED, amountOut);
    }

    /// @notice Emits `JITDefaultV1` for a caller that ran its own default route. Optional for
    ///         callers. Changes no state.
    /// @param amountOut What `req.recipient` received from the default route.
    function reportDefault(Request calldata req, uint256 amountOut) external {
        emit JITDefaultV1(
            msg.sender,
            req.tokenIn,
            req.tokenOut,
            req.recipient,
            req.amountIn,
            req.amountOutMin,
            amountOut
        );
    }

    /// @notice The route this settler is running: its setter and the caller of the swap. Both
    ///         are 0 unless called while a route's executor runs.
    /// @dev Lets a venue tell flow routed by a builder it trusts from other flow, for example to
    ///      quote a tighter spread, and lets an executor check who posted its route. A venue checks
    ///      `setter` against its own list, and optionally `caller` against known aggregators.
    ///      Only the swap functions write these values.
    function currentRoute() external view returns (address setter, address caller) {
        return (_currentSetter, _currentCaller);
    }

    // Marks the live route used and reads its header, before any external call, so a reentrant
    // swap can't run it again.
    function _consumeRoute() private returns (bool live, RouteHeader memory header) {
        RouteHeader storage stored = _routeHeader;
        if (!_isLive(stored)) return (false, header);
        stored.timestamp = 0;
        header = stored;
        live = true;
    }

    // Calls routeAvailable(setter) on msg.sender. Any failure, including a caller without code or
    // a short return, counts as a decline. Return data past the first word is not copied.
    function _askCaller(address setter) private returns (bool accepted, uint256 amountOutMin) {
        bytes4 selector = ISettlerCaller.routeAvailable.selector;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, selector)
            mstore(add(ptr, 0x04), setter)
            let ok := call(gas(), caller(), 0, ptr, 0x24, ptr, 0x20)
            accepted := and(ok, gt(returndatasize(), 0x1f))
            if accepted { amountOutMin := mload(ptr) }
        }
    }

    function _execute(
        RouteHeader memory header,
        bytes memory data,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient
    ) private returns (uint256 amountOut) {
        _transferFrom(tokenIn, msg.sender, header.executor, amountIn);
        uint256 balanceBefore = IERC20(tokenOut).balanceOf(recipient);
        // Restore, not clear, so a swap nested inside an executor leaves the outer route visible.
        (address prevSetter, address prevCaller) = (_currentSetter, _currentCaller);
        (_currentSetter, _currentCaller) = (header.setter, msg.sender);
        SANDBOX.run(header.executor, data);
        (_currentSetter, _currentCaller) = (prevSetter, prevCaller);
        uint256 balanceAfter = IERC20(tokenOut).balanceOf(recipient);
        amountOut = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
        if (amountOut < amountOutMin) revert InsufficientOutput(amountOut, amountOutMin);

        emit JITRoutedV1(
            msg.sender,
            header.setter,
            header.executor,
            tokenIn,
            tokenOut,
            recipient,
            amountIn,
            amountOutMin,
            amountOut
        );
    }

    function _isLive(RouteHeader storage header) private view returns (bool) {
        return header.timestamp == block.timestamp;
    }

    function _storeRouteData(bytes calldata data) private {
        uint256 slot = _ROUTE_DATA_SLOT;
        assembly ("memory-safe") {
            for { let offset := 0 } lt(offset, data.length) { offset := add(offset, 0x20) } {
                sstore(add(slot, shr(5, offset)), calldataload(add(data.offset, offset)))
            }
        }
    }

    function _loadRouteData(uint256 length) private view returns (bytes memory data) {
        uint256 slot = _ROUTE_DATA_SLOT;
        assembly ("memory-safe") {
            data := mload(0x40)
            mstore(data, length)
            let start := add(data, 0x20)
            for { let offset := 0 } lt(offset, length) { offset := add(offset, 0x20) } {
                mstore(add(start, offset), sload(add(slot, shr(5, offset))))
            }
            mstore(0x40, add(start, and(add(length, 31), not(31))))
        }
    }

    // Empty returndata counts as success (USDT-style), but only if the token has code.
    function _transferFrom(address token, address from, address to, uint256 amount) private {
        (bool success, bytes memory returnData) =
            token.call(abi.encodeCall(IERC20.transferFrom, (from, to, amount)));
        if (
            !success
                || (returnData.length == 0
                        ? token.code.length == 0
                        : !abi.decode(returnData, (bool)))
        ) {
            revert TransferFailed();
        }
    }
}

// Calls the executor. It holds no approvals, so setting executor = erc20 can't spend what other
// callers approved.
contract Sandbox {
    // Revert data longer than this is cut, so copying it back costs the caller little gas.
    uint256 private constant _MAX_REVERT_DATA = 0x104;

    address private immutable SETTLER = msg.sender;

    function run(address executor, bytes calldata data) external {
        // msg.sender == SANDBOX only tells an executor that some swap is running: anyone can post a
        // route naming any executor. Executors check JITSettler.currentRoute().setter and measure
        // the tokenIn they received.
        if (msg.sender != SETTLER) revert();
        assembly ("memory-safe") {
            // A route to an address without code would "succeed" without paying anything.
            if iszero(extcodesize(executor)) { revert(0, 0) }
            let input := mload(0x40)
            calldatacopy(input, data.offset, data.length)
            if iszero(call(gas(), executor, 0, input, data.length, 0, 0)) {
                let size := returndatasize()
                if gt(size, _MAX_REVERT_DATA) { size := _MAX_REVERT_DATA }
                returndatacopy(input, 0, size)
                revert(input, size)
            }
        }
    }
}
