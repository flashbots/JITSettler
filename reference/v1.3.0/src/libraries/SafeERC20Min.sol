// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Minimal ERC20 surface for `SafeERC20Min`: empty returndata is success (USDT), a
///         returned word is the bool it claims.
interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function transferFrom(address, address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

library SafeERC20Min {
    function safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        _call(token, abi.encodeWithSelector(IERC20Min.transferFrom.selector, from, to, amount));
    }

    function safeTransfer(address token, address to, uint256 amount) internal {
        _call(token, abi.encodeWithSelector(IERC20Min.transfer.selector, to, amount));
    }

    function balanceOf(address token, address who) internal view returns (uint256) {
        return IERC20Min(token).balanceOf(who);
    }

    function _call(address token, bytes memory data) private {
        (bool ok, bytes memory ret) = token.call(data);
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "erc20 call failed");
    }
}
