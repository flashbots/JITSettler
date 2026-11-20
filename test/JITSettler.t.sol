// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { JITSettler, Sandbox, IJITEvents, Request } from "../src/JITSettler.sol";

// Gas limit the tests pass in requests.
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

/// Reverts with `size` bytes of revert data.
contract BigReverter {
    function boom(uint256 size) external pure {
        assembly {
            revert(0, size)
        }
    }
}

/// Flow A caller: peek(req), trusted setter -> swap; otherwise the default route, which reports
/// JITDefaultV1. The default route is simulated by minting `defaultOut`.
contract FlowACaller {
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
        Request memory req =
            Request(address(tokenIn), address(tokenOut), amountIn, minOut, recipient, G);
        address s = settler.peek(req);
        if (s != address(0) && trusted[s]) {
            try settler.swap(req) returns (uint256 o) {
                return (o, true);
            } catch { }
        }
        tokenIn.approve(address(settler), 0);
        uint256 before = tokenOut.balanceOf(recipient);
        tokenOut.mint(recipient, defaultOut); // stands in for the default route
        out = tokenOut.balanceOf(recipient) - before;
        settler.reportDefault(req, out);
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

    function _req(uint256 minOut, uint256 gasLimit) internal view returns (Request memory) {
        return Request(address(tIn), address(tOut), 1e18, minOut, recipient, gasLimit);
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

    /// v1.3.0 callers keep their selectors.
    function test_selectors_matchV130() public pure {
        assertEq(JITSettler.swap.selector, bytes4(0x56e87df9));
        assertEq(JITSettler.peek.selector, bytes4(0x7c1c62dd));
    }

    function test_noRoute_peekZero_swapReverts() public {
        assertEq(settler.peek(_req(1, G)), address(0));
        vm.prank(user);
        vm.expectRevert(JITSettler.NoRoute.selector);
        settler.swap(_req(1, G));
    }

    /// The settler does not enforce gasLimit: the caller caps its own call. A route that burns all
    /// its gas then reverts the swap, the caller keeps the rest, and the route stays live.
    function test_swap_callerCapsItsOwnCall() public {
        GasBurner burner = new GasBurner();
        vm.prank(builder);
        settler.setRoute(address(burner), abi.encodeCall(GasBurner.burn, ()));
        uint256 before = gasleft();
        vm.prank(user);
        try settler.swap{ gas: 200_000 }(_req(1, 100_000)) {
            fail();
        } catch { }
        assertLt(before - gasleft(), 250_000);
        assertEq(settler.peek(_req(1, G)), builder);
    }

    /// gasLimit is not enforced: a route that needs more than it still fills.
    function test_swap_gasLimitNotEnforced() public {
        _post(110e18, 105e18);
        vm.prank(user);
        assertEq(settler.swap(_req(100e18, 1)), 105e18);
    }

    function test_routedFill_paysBuilderFee_emits() public {
        _post(110e18, 105e18);
        assertEq(settler.peek(_req(100e18, G)), builder);

        vm.expectEmit(true, true, true, true, address(settler));
        emit JITRoutedV1(
            user,
            builder,
            address(exec),
            address(tIn),
            address(tOut),
            recipient,
            1e18,
            100e18,
            105e18
        );
        vm.prank(user);
        uint256 out = settler.swap(_req(100e18, G));

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
        settler.swap(_req(100e18, G));
        // The revert undid the consumption.
        assertEq(settler.peek(_req(100e18, G)), builder);
    }

    function test_routeIsSingleUse() public {
        _post(110e18, 105e18);
        vm.prank(user);
        settler.swap(_req(100e18, G));
        assertEq(settler.peek(_req(100e18, G)), address(0));
        vm.prank(user);
        vm.expectRevert(JITSettler.NoRoute.selector);
        settler.swap(_req(100e18, G));
    }

    function test_routeExpiresNextBlock() public {
        _post(110e18, 105e18);
        vm.warp(block.timestamp + 12);
        assertEq(settler.peek(_req(100e18, G)), address(0));
    }

    function test_laterPostOverwrites_setterChanges() public {
        _post(110e18, 105e18);
        address other = makeAddr("other");
        vm.prank(other);
        settler.setRoute(address(exec), _data(110e18, 105e18, ""));
        assertEq(settler.peek(_req(100e18, G)), other);
    }

    function test_trailingSignatureBytes_passThrough() public {
        bytes memory sig = new bytes(65);
        sig[0] = 0xab;
        vm.prank(builder);
        settler.setRoute(address(exec), _data(110e18, 105e18, sig));
        vm.prank(user);
        assertEq(settler.swap(_req(100e18, G)), 105e18);
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
        settler.swap(_req(0, G));
        assertEq(tIn.balanceOf(victim), 50e18);
    }

    function test_sandbox_onlySettler() public {
        Sandbox sb = settler.SANDBOX();
        vm.expectRevert();
        sb.run(address(exec), "");
    }

    /// A route to an address without code reverts instead of "succeeding" with no output.
    function test_noCodeExecutor_reverts() public {
        vm.prank(builder);
        settler.setRoute(makeAddr("eoa"), hex"12345678");
        vm.prank(user);
        vm.expectRevert();
        settler.swap(_req(0, G));
        assertEq(tIn.balanceOf(user), 1000e18);
    }

    /// Executor revert data is cut to 260 bytes, so copying it back outside gasLimit is cheap.
    function test_executorRevertData_isCut() public {
        BigReverter big = new BigReverter();
        vm.prank(builder);
        settler.setRoute(address(big), abi.encodeCall(BigReverter.boom, (200_000)));
        vm.prank(user);
        try settler.swap(_req(0, 5_000_000)) {
            fail();
        } catch (bytes memory err) {
            assertEq(err.length, 0x104);
        }
    }

    function test_reportDefault_emitsReporter() public {
        vm.expectEmit(true, true, true, true, address(settler));
        emit JITDefaultV1(user, address(tIn), address(tOut), recipient, 1e18, 100e18, 101e18);
        vm.prank(user);
        settler.reportDefault(_req(100e18, G), 101e18);
    }

    function test_flowA_trustedRoute_and_default() public {
        FlowACaller agg = new FlowACaller(settler, builder);
        tIn.mint(address(agg), 2e18);

        // No route: the default runs and JITDefaultV1 reports its output.
        vm.expectEmit(true, true, true, true, address(settler));
        emit JITDefaultV1(
            address(agg), address(tIn), address(tOut), recipient, 1e18, 100e18, 101e18
        );
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
        assertEq(settler.peek(_req(100e18, G)), other);
    }
}
