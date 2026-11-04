// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice What callers integrate (RFC "JITSettler").
interface IJITSettler {
    /// @dev RFC: `req` = (tokenIn, tokenOut, amountIn, minOut, recipient, maxGas). `maxGas` is
    ///      not in the lane key; `maxGas == 0` means no cap. `maxGas` caps the posted
    ///      `routedEstGas` only; to cap the gas `swap` burns, call `swap{gas: maxGas}(req)`.
    struct Request {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 minOut;
        address recipient;
        uint256 maxGas;
    }

    /// @dev Indexed on caller, recipient, tokenOut; 8 data words. `routedOut` is the recipient's
    ///      measured balance change; `routedEstOut` and `routedEstGas` are jit-router's
    ///      estimates as posted (never rewritten after sim 2), so its accuracy is readable from
    ///      logs; `simOriginalOut` is the builder's sim 1 of the order without our route. The
    ///      treasury received `postingChargeOut + feeOut`. Realized gas is the receipt's.
    event Settled(
        address indexed caller,
        address indexed recipient,
        address tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 routedEstOut,
        uint256 routedOut,
        uint256 simOriginalOut,
        uint256 routedEstGas,
        uint256 postingChargeOut,
        uint256 feeOut
    );

    error NoRoute();
    error GasCapExceeded(uint256 maxGas);
    error BelowFloor(uint256 recipientOut, uint256 floor);
    error BadRecipient();
    /// @dev The constructor's `router` does not name this contract as its `SETTLER`.
    error RouterNotPaired();

    /// @notice Posting aid: the lane a route for `req` sent by `caller` goes to.
    function laneFor(address caller, Request calldata req) external pure returns (uint256 lane);

    function swap(Request calldata req) external returns (uint256 routedOut);
}
