// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { SafeERC20Min } from "./libraries/SafeERC20Min.sol";

/// @title JITSettlerTreasury (RFC 2026-10-15)
/// @notice Where `JITSettler` sends each swap's `postingChargeOut` (the posted price of the
///         order's own update tx, in `tokenOut`) plus `feeOut` (0 in v1). `JITSettler` holds this
///         address as an immutable and never calls it; it only receives ERC-20 transfers.
///
///         The one mutable party. Owned by a hotkey (an EOA) in v1, which sweeps the balances.
///         Rotating the hotkey, or handing the treasury to a Safe once fees are on, is
///         `transferOwnership`; the settler is untouched.
contract JITSettlerTreasury {
    using SafeERC20Min for address;

    address public owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor(address owner_) {
        require(owner_ != address(0));
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
    }

    receive() external payable { }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0));
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Sends `amount` of `token` to `to`; `token == address(0)` sends ETH.
    function withdraw(address token, address to, uint256 amount) external onlyOwner {
        if (token == address(0)) {
            (bool ok,) = to.call{ value: amount }("");
            require(ok, "eth transfer");
        } else {
            token.safeTransfer(to, amount);
        }
        emit Withdrawn(token, to, amount);
    }
}
