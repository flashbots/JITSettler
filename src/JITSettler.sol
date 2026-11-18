// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "./IERC20.sol";

/// @notice Events of the JIT settler standard. The settler emits `JITRoutedV1` on a fill and
///         `JITDefaultV1` when a caller reports its own default route through `reportDefault`.
interface IJITEvents {
    /// @notice Emitted by the settler when a swap fills through a posted route.
    event JITRoutedV1(
        address indexed recipient,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 amountOut
    );

    /// @notice A caller ran its own default route instead of a JIT route. `amountOut` is what the
    ///         recipient received from that route, as the caller reports it.
    event JITDefaultV1(
        address indexed recipient,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 amountOut
    );
}

/// @title JITSettler
/// @notice Based on Gattaca's JIT settler PoC (gattaca-com/jit-settler-poc, commit 8615c54).
///         Changes: `peek` and `swap` take the swap request including a gas limit, the settler
///         emits `JITRoutedV1` on a fill, and `reportDefault` emits `JITDefaultV1` for callers.
contract JITSettler is IJITEvents {
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

    // The route `swap` is running, set only while its executor runs.
    address private transient _currentSetter;
    address private transient _currentCaller;

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
    }

    /// @notice The setter of the route live in this block, or 0 if there is none.
    /// @dev Takes the same request as `swap` so a builder can read the request from the call in
    ///      a simulation where no route is posted yet (and `peek` therefore returns 0). The
    ///      arguments are not used on chain.
    function peek(
        address, /* tokenIn */
        uint256, /* amountIn */
        address, /* tokenOut */
        uint256, /* amountOutMin */
        address, /* recipient */
        uint256 /* gasLimit */
    )
        external
        view
        returns (address setter)
    {
        RouteHeader storage header = _routeHeader;
        if (_isLive(header)) return header.setter;
    }

    /// @param gasLimit The most gas the route's executor gets, so a route cannot use up the gas
    ///        the caller needs for its default route. Builders fit routes under it.
    /// @return amountOut What `recipient` received.
    function swap(
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 amountOutMin,
        address recipient,
        uint256 gasLimit
    ) external returns (uint256 amountOut) {
        RouteHeader storage stored = _routeHeader;
        if (!_isLive(stored)) revert NoRoute();
        // Consume and load before any external call, so a reentrant swap or setRoute can't touch
        // this route.
        stored.timestamp = 0;
        RouteHeader memory header = stored;
        bytes memory data = _loadRouteData(header.dataLength);

        _transferFrom(tokenIn, msg.sender, header.executor, amountIn);
        uint256 balanceBefore = IERC20(tokenOut).balanceOf(recipient);
        // Restore, not clear, so a swap nested inside an executor leaves the outer route visible.
        (address prevSetter, address prevCaller) = (_currentSetter, _currentCaller);
        (_currentSetter, _currentCaller) = (header.setter, msg.sender);
        SANDBOX.run{ gas: gasLimit }(header.executor, data);
        (_currentSetter, _currentCaller) = (prevSetter, prevCaller);
        uint256 balanceAfter = IERC20(tokenOut).balanceOf(recipient);
        amountOut = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
        if (amountOut < amountOutMin) revert InsufficientOutput(amountOut, amountOutMin);

        emit JITRoutedV1(recipient, tokenIn, tokenOut, amountIn, amountOutMin, amountOut);
    }

    /// @notice The route this settler is running: its setter and the caller of `swap`. Both are 0
    ///         unless called while a route's executor runs.
    /// @dev Lets a venue tell flow routed by a builder it trusts from other flow, for example to
    ///      quote a tighter spread. A venue checks `setter` against its own list, and optionally
    ///      `caller` against known aggregators. Only `swap` writes these values.
    function currentRoute() external view returns (address setter, address caller) {
        return (_currentSetter, _currentCaller);
    }

    /// @notice Emits `JITDefaultV1` for a caller that ran its own default route. Changes no state.
    function reportDefault(
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 amountOutMin,
        address recipient,
        uint256 amountOut
    ) external {
        emit JITDefaultV1(recipient, tokenIn, tokenOut, amountIn, amountOutMin, amountOut);
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
    address private immutable SETTLER = msg.sender;

    function run(address executor, bytes calldata data) external {
        // Lets executors rely on msg.sender == SANDBOX meaning "inside swap, tokenIn already
        // delivered".
        if (msg.sender != SETTLER) revert();
        assembly ("memory-safe") {
            let input := mload(0x40)
            calldatacopy(input, data.offset, data.length)
            if iszero(call(gas(), executor, 0, input, data.length, 0, 0)) {
                returndatacopy(input, 0, returndatasize())
                revert(input, returndatasize())
            }
        }
    }
}
