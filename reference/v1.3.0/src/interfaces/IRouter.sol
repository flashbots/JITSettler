// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice The executor `JITSettler` holds as an immutable (RFC "Router").
interface IRouter {
    /// @dev The route's endpoints, and the recipient of any leftovers. The codec omits them from
    ///      the hops (the first hop's input is index 0, the last hop's output is implicit), so
    ///      they travel next to the words.
    struct Endpoints {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        address recipient;
    }

    /// @notice The only caller of `execute`: this pair's `JITSettler` (Q20).
    function SETTLER() external view returns (address);

    /// @notice RFC: `execute(endpoints, route)`. `route` is the lane exactly as PUR returned it
    ///         (header included; the `Router` skips the fixed-width header). `amountIn` of
    ///         `tokenIn` is already held by the `Router`. Pays its whole `tokenOut` balance to
    ///         `msg.sender` and returns nothing: `JITSettler` measures its own balance change
    ///         (`routedGrossOut`).
    function execute(Endpoints calldata endpoints, uint256[] calldata route) external;
}
