// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { JITSettler, Sandbox, IJITEvents } from "../src/JITSettler.sol";

// Gas limit the tests pass to `peek` and `swap`.
uint256 constant G = 1_000_000;

contract MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
        return true;
    }
}

/// A builder's executor: the "venue" is simulated by minting `gross` tokenOut, then the executor
/// pays `toUser` to the recipient and the rest to the builder (its fee). The data may carry
/// trailing bytes (for example a router signature), which it ignores here.
contract FeeExecutor {
    address public immutable SANDBOX;

    constructor(address sandbox) {
        SANDBOX = sandbox;
    }

    function fill(
        MockToken tokenOut,
        uint256 gross,
        address recipient,
        uint256 toUser,
        address builder,
        bytes calldata /* trailing */
    ) external {
        require(msg.sender == SANDBOX, "not sandbox");
        tokenOut.mint(address(this), gross);
        tokenOut.transfer(recipient, toUser);
        tokenOut.transfer(builder, gross - toUser);
    }
}

/// Spends all the gas it is given.
contract GasBurner {
    function burn() external pure {
        while (true) { }
    }
}

/// Flow A caller (efficient): peek(req), trusted setter -> swap; otherwise the default route,
/// which emits JITDefaultV1. The default route is simulated by minting `defaultOut`.
contract FlowACaller is IJITEvents {
    JITSettler public immutable settler;
    mapping(address => bool) public trusted;

    constructor(JITSettler s, address trustedSetter) {
        settler = s;
        trusted[trustedSetter] = true;
    }

    function run(
        MockToken tokenIn,
        uint256 amountIn,
        MockToken tokenOut,
        uint256 minOut,
        address recipient,
        uint256 defaultOut
    ) external returns (uint256 out, bool routed) {
        tokenIn.approve(address(settler), amountIn);
        address s =
            settler.peek(address(tokenIn), amountIn, address(tokenOut), minOut, recipient, G);
        if (s != address(0) && trusted[s]) {
            try settler.swap(
                address(tokenIn), amountIn, address(tokenOut), minOut, recipient, G
            ) returns (
                uint256 o
            ) {
                return (o, true);
            } catch { }
        }
        tokenIn.approve(address(settler), 0);
        uint256 before = tokenOut.balanceOf(recipient);
        tokenOut.mint(recipient, defaultOut); // stands in for the default route
        out = tokenOut.balanceOf(recipient) - before;
        settler.reportDefault(address(tokenIn), amountIn, address(tokenOut), minOut, recipient, out);
    }
}

contract JITSettlerTest is Test, IJITEvents {
    JITSettler settler;
    MockToken tIn;
    MockToken tOut;
    FeeExecutor exec;
    address builder = makeAddr("builder");
    address user = makeAddr("user");
    address recipient = makeAddr("recipient");

    function setUp() public {
        settler = new JITSettler();
        tIn = new MockToken();
        tOut = new MockToken();
        exec = new FeeExecutor(address(settler.SANDBOX()));
        tIn.mint(user, 1000e18);
        vm.prank(user);
        tIn.approve(address(settler), type(uint256).max);
    }

    function _data(uint256 gross, uint256 toUser, bytes memory trailing)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeCall(FeeExecutor.fill, (tOut, gross, recipient, toUser, builder, trailing));
    }

    function _post(uint256 gross, uint256 toUser) internal {
        vm.prank(builder);
        settler.setRoute(address(exec), _data(gross, toUser, ""));
    }

    function test_noRoute_peekZero_swapReverts() public {
        assertEq(settler.peek(address(tIn), 1e18, address(tOut), 1, recipient, G), address(0));
        vm.prank(user);
        vm.expectRevert(JITSettler.NoRoute.selector);
        settler.swap(address(tIn), 1e18, address(tOut), 1, recipient, G);
    }

    /// An executor gets at most `gasLimit`: one that burns all its gas reverts the swap, and the
    /// caller keeps the rest of its gas. The route stays live.
    function test_swap_capsExecutorGas() public {
        GasBurner burner = new GasBurner();
        vm.prank(builder);
        settler.setRoute(address(burner), abi.encodeCall(GasBurner.burn, ()));
        uint256 before = gasleft();
        vm.prank(user);
        try settler.swap(address(tIn), 1e18, address(tOut), 1, recipient, 100_000) {
            fail();
        } catch { }
        assertLt(before - gasleft(), 250_000);
        assertEq(settler.peek(address(tIn), 1e18, address(tOut), 1, recipient, G), builder);
    }

    /// A call with more gas than `gasLimit` is fine.
    function test_swap_moreGasThanLimit_fills() public {
        _post(110e18, 105e18);
        vm.prank(user);
        uint256 out = settler.swap{ gas: 5_000_000 }(
            address(tIn), 1e18, address(tOut), 100e18, recipient, 500_000
        );
        assertEq(out, 105e18);
    }

    function test_routedFill_paysBuilderFee_emits() public {
        _post(110e18, 105e18);
        assertEq(settler.peek(address(tIn), 1e18, address(tOut), 100e18, recipient, G), builder);

        vm.expectEmit(true, true, true, true, address(settler));
        emit JITRoutedV1(recipient, address(tIn), address(tOut), 1e18, 100e18, 105e18);
        vm.prank(user);
        uint256 out = settler.swap(address(tIn), 1e18, address(tOut), 100e18, recipient, G);

        assertEq(out, 105e18);
        assertEq(tOut.balanceOf(builder), 5e18); // the builder's cut, taken in the executor
        assertEq(tIn.balanceOf(address(exec)), 1e18);
    }

    function test_belowMinOut_reverts_andRouteStaysLive() public {
        _post(110e18, 99e18);
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(JITSettler.InsufficientOutput.selector, 99e18, 100e18)
        );
        settler.swap(address(tIn), 1e18, address(tOut), 100e18, recipient, G);
        // The revert undid the consumption.
        assertEq(settler.peek(address(tIn), 1e18, address(tOut), 100e18, recipient, G), builder);
    }

    function test_routeIsSingleUse() public {
        _post(110e18, 105e18);
        vm.prank(user);
        settler.swap(address(tIn), 1e18, address(tOut), 100e18, recipient, G);
        assertEq(settler.peek(address(tIn), 1e18, address(tOut), 100e18, recipient, G), address(0));
        vm.prank(user);
        vm.expectRevert(JITSettler.NoRoute.selector);
        settler.swap(address(tIn), 1e18, address(tOut), 100e18, recipient, G);
    }

    function test_routeExpiresNextBlock() public {
        _post(110e18, 105e18);
        vm.warp(block.timestamp + 12);
        assertEq(settler.peek(address(tIn), 1e18, address(tOut), 100e18, recipient, G), address(0));
    }

    function test_laterPostOverwrites_setterChanges() public {
        _post(110e18, 105e18);
        address other = makeAddr("other");
        vm.prank(other);
        settler.setRoute(address(exec), _data(110e18, 105e18, ""));
        assertEq(settler.peek(address(tIn), 1e18, address(tOut), 100e18, recipient, G), other);
    }

    function test_trailingSignatureBytes_passThrough() public {
        bytes memory sig = new bytes(65);
        sig[0] = 0xab;
        vm.prank(builder);
        settler.setRoute(address(exec), _data(110e18, 105e18, sig));
        vm.prank(user);
        uint256 out = settler.swap(address(tIn), 1e18, address(tOut), 100e18, recipient, G);
        assertEq(out, 105e18);
    }

    /// An "executor" that is the token itself cannot spend allowances given to the settler: the
    /// sandbox, not the settler, makes the call, and the sandbox has no allowances.
    function test_sandbox_cannotSpendSettlerAllowances() public {
        address victim = makeAddr("victim");
        tIn.mint(victim, 50e18);
        vm.prank(victim);
        tIn.approve(address(settler), type(uint256).max);

        vm.prank(builder);
        settler.setRoute(
            address(tIn), abi.encodeCall(MockToken.transferFrom, (victim, builder, 50e18))
        );
        vm.prank(user);
        vm.expectRevert(); // allowance[victim][sandbox] == 0
        settler.swap(address(tIn), 1e18, address(tOut), 0, recipient, G);
        assertEq(tIn.balanceOf(victim), 50e18);
    }

    function test_sandbox_onlySettler() public {
        Sandbox sb = settler.SANDBOX();
        vm.expectRevert();
        sb.run(address(exec), "");
    }

    function test_flowA_trustedRoute_and_default() public {
        FlowACaller agg = new FlowACaller(settler, builder);
        tIn.mint(address(agg), 2e18);

        // No route: the default runs and JITDefaultV1 reports its output.
        vm.expectEmit(true, true, true, true, address(settler));
        emit JITDefaultV1(recipient, address(tIn), address(tOut), 1e18, 100e18, 101e18);
        (uint256 out, bool routed) = agg.run(tIn, 1e18, tOut, 100e18, recipient, 101e18);
        assertEq(out, 101e18);
        assertFalse(routed);

        // Trusted route posted: the JIT swap fills.
        _post(110e18, 105e18);
        (out, routed) = agg.run(tIn, 1e18, tOut, 100e18, recipient, 101e18);
        assertEq(out, 105e18);
        assertTrue(routed);
    }

    function test_flowA_untrustedSetter_fallsBack() public {
        FlowACaller agg = new FlowACaller(settler, builder);
        tIn.mint(address(agg), 1e18);
        address other = makeAddr("other");
        vm.prank(other);
        settler.setRoute(address(exec), _data(110e18, 100e18, ""));
        (uint256 out, bool routed) = agg.run(tIn, 1e18, tOut, 100e18, recipient, 101e18);
        assertEq(out, 101e18);
        assertFalse(routed);
        assertEq(settler.peek(address(tIn), 1e18, address(tOut), 100e18, recipient, G), other);
    }
}
