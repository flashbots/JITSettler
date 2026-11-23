// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { JITSettler, IJITEvents, ISettlerCaller, Request } from "../src/JITSettler.sol";
import { MockToken, FeeExecutor, GasBurner } from "./JITSettler.t.sol";

/// A caller that uses `swap(req, true)`. `routeAvailable` checks the settler and the setter,
/// optionally trials its default route through a reverting self-call, approves the settler and
/// returns its floor.
contract CallbackCaller is ISettlerCaller {
    error Measured(uint256 out);

    JITSettler public immutable settler;
    MockToken public immutable tIn;
    MockToken public immutable tOut;
    address public immutable trustedSetter;
    address public immutable recipient;

    uint256 public staticFloor; // req.amountOutMin
    uint256 public callbackFloor; // what routeAvailable returns without a trial
    uint256 public defaultOut; // what the simulated default route pays
    bool public trialDefault;
    uint256 public callbacks;

    constructor(JITSettler s, MockToken i, MockToken o, address setter, address r) {
        (settler, tIn, tOut, trustedSetter, recipient) = (s, i, o, setter, r);
    }

    function configure(uint256 static_, uint256 callback_, uint256 defaultOut_, bool trial_)
        external
    {
        (staticFloor, callbackFloor, defaultOut, trialDefault) =
        (static_, callback_, defaultOut_, trial_);
    }

    function routeAvailable(address setter) external returns (uint256) {
        require(msg.sender == address(settler), "not settler");
        require(setter == trustedSetter, "declined");
        callbacks++;
        uint256 floor = callbackFloor;
        if (trialDefault) {
            try this.runDefaultAndRevert() { }
            catch (bytes memory err) {
                require(bytes4(err) == Measured.selector, "trial failed");
                uint256 dOut;
                assembly {
                    dOut := mload(add(err, 0x24))
                }
                floor = dOut + 1; // must beat the default
            }
        }
        tIn.approve(address(settler), 1e18);
        return floor;
    }

    function runDefaultAndRevert() external {
        require(msg.sender == address(this));
        revert Measured(_runDefault());
    }

    function _runDefault() internal returns (uint256) {
        uint256 before = tOut.balanceOf(recipient);
        tOut.mint(recipient, defaultOut);
        return tOut.balanceOf(recipient) - before;
    }

    function _req() internal view returns (Request memory) {
        return Request(address(tIn), address(tOut), 1e18, staticFloor, recipient);
    }

    /// The caller's whole swap: JIT if it fills, else the default route. `gasCap` caps the call
    /// to the settler; `err` is the settler's revert selector when it did not fill.
    function run(uint256 gasCap) external returns (bool routed, uint256 out, bytes4 err) {
        try settler.swap{ gas: gasCap }(_req(), true) returns (uint256 a) {
            return (true, a, bytes4(0));
        } catch (bytes memory e) {
            err = bytes4(e);
        }
        tIn.approve(address(settler), 0);
        out = _runDefault();
        settler.reportDefault(_req(), out);
    }
}

contract CallbackTest is Test, IJITEvents {
    JITSettler settler;
    MockToken tIn;
    MockToken tOut;
    FeeExecutor exec;
    CallbackCaller caller;
    address builder = makeAddr("builder");
    address recipient = makeAddr("recipient");
    uint256 constant CAP = 1_000_000;

    function setUp() public {
        settler = new JITSettler();
        tIn = new MockToken();
        tOut = new MockToken();
        exec = new FeeExecutor(address(settler.SANDBOX()));
        caller = new CallbackCaller(settler, tIn, tOut, builder, recipient);
        tIn.mint(address(caller), 10e18);
    }

    function _post(address setter, uint256 gross, uint256 toUser) internal {
        vm.prank(setter);
        settler.setRoute(
            address(exec),
            abi.encodeCall(FeeExecutor.fill, (tOut, gross, recipient, toUser, builder, ""))
        );
    }

    function _req() internal view returns (Request memory) {
        return Request(address(tIn), address(tOut), 1e18, 0, recipient);
    }

    function _peek() internal view returns (address) {
        return settler.peek(_req());
    }

    function test_noRoute_revertsNoRoute_noCallback() public {
        caller.configure(100e18, 100e18, 101e18, false);
        (bool routed, uint256 out, bytes4 err) = caller.run(CAP);
        assertFalse(routed);
        assertEq(err, JITSettler.NoRoute.selector);
        assertEq(out, 101e18);
        assertEq(caller.callbacks(), 0);
    }

    function test_betterRoute_executes_emits() public {
        caller.configure(0, 100e18, 101e18, false);
        _post(builder, 110e18, 105e18);
        vm.expectEmit(true, true, true, true, address(settler));
        emit JITRoutedV1(
            address(caller),
            builder,
            address(exec),
            address(tIn),
            address(tOut),
            recipient,
            1e18,
            100e18,
            105e18
        );
        (bool routed, uint256 out,) = caller.run(CAP);
        assertTrue(routed);
        assertEq(out, 105e18);
        assertEq(tOut.balanceOf(recipient), 105e18);
        assertEq(_peek(), address(0)); // used
    }

    /// The floor is the larger of req.amountOutMin and the callback's value: a callback that
    /// returns less than the request's minimum cannot lower it.
    function test_callbackCannotLowerRequestFloor() public {
        caller.configure(106e18, 1, 107e18, false);
        _post(builder, 110e18, 105e18);
        (bool routed, uint256 out, bytes4 err) = caller.run(CAP);
        assertFalse(routed);
        assertEq(err, JITSettler.InsufficientOutput.selector);
        assertEq(out, 107e18);
    }

    /// The callback can raise the floor above req.amountOutMin.
    function test_callbackRaisesFloor() public {
        caller.configure(100e18, 106e18, 107e18, false);
        _post(builder, 110e18, 105e18);
        (bool routed,, bytes4 err) = caller.run(CAP);
        assertFalse(routed);
        assertEq(err, JITSettler.InsufficientOutput.selector);
    }

    /// The trial of the default inside the callback sets the floor above the default's output,
    /// and changes no state.
    function test_trialFloor_betterRoute_executes() public {
        caller.configure(0, 0, 104e18, true);
        _post(builder, 110e18, 105e18);
        (bool routed, uint256 out,) = caller.run(CAP);
        assertTrue(routed);
        assertEq(out, 105e18);
        assertEq(tOut.balanceOf(recipient), 105e18); // the trial's mint was reverted
    }

    function test_trialFloor_worseRoute_revertsAndFallsBack() public {
        caller.configure(0, 0, 106e18, true);
        _post(builder, 110e18, 105e18);
        (bool routed, uint256 out, bytes4 err) = caller.run(CAP);
        assertFalse(routed);
        assertEq(err, JITSettler.InsufficientOutput.selector);
        assertEq(out, 106e18);
        assertEq(tOut.balanceOf(recipient), 106e18);
        assertEq(tIn.balanceOf(address(caller)), 10e18);
        assertEq(_peek(), builder); // the revert undid the consumption
    }

    /// A decline reverts with RouteDeclined, so the route stays live.
    function test_untrustedSetter_declined_routeStaysLive() public {
        address other = makeAddr("other");
        caller.configure(100e18, 100e18, 101e18, false);
        _post(other, 110e18, 105e18);
        (bool routed, uint256 out, bytes4 err) = caller.run(CAP);
        assertFalse(routed);
        assertEq(err, JITSettler.RouteDeclined.selector);
        assertEq(out, 101e18);
        assertEq(_peek(), other);
        assertEq(tIn.balanceOf(address(caller)), 10e18);
    }

    /// A caller without code, or without routeAvailable, declines.
    function test_eoaCaller_declines() public {
        _post(builder, 110e18, 105e18);
        vm.prank(makeAddr("eoa"));
        vm.expectRevert(JITSettler.RouteDeclined.selector);
        settler.swap(_req(), true);
    }

    function test_contractWithoutCallback_declines() public {
        _post(builder, 110e18, 105e18);
        vm.prank(address(tIn)); // a contract with no routeAvailable and no fallback
        vm.expectRevert(JITSettler.RouteDeclined.selector);
        settler.swap(_req(), true);
    }

    /// The settler gives the route all the gas the call has; a caller that caps its own call
    /// keeps the rest when a burner route reverts the call after the callback.
    function test_callerCapsItsOwnCall() public {
        caller.configure(1, 1, 101e18, false);
        GasBurner burner = new GasBurner();
        vm.prank(builder);
        settler.setRoute(address(burner), abi.encodeCall(GasBurner.burn, ()));
        uint256 before = gasleft();
        (bool routed, uint256 out,) = caller.run(250_000);
        assertFalse(routed);
        assertEq(out, 101e18);
        assertLt(before - gasleft(), 500_000);
        assertEq(caller.callbacks(), 0); // the counted callback was reverted with the rest
    }

    /// A callback that posts a route could overwrite the data of the route being run, which is
    /// loaded only after the callback, so the call is declined and nothing runs.
    function test_routePostedInCallback_declines() public {
        ReentrantCaller rc = new ReentrantCaller(settler, tIn, tOut, recipient, address(exec));
        tIn.mint(address(rc), 1e18);
        _post(builder, 110e18, 105e18);
        vm.expectRevert(JITSettler.RouteDeclined.selector);
        rc.run();
        assertEq(tOut.balanceOf(recipient), 0);
        assertEq(tIn.balanceOf(address(rc)), 1e18);
        assertEq(_peek(), builder); // the revert undid the callback's post too
    }

    /// Declining a large route from an untrusted setter does not load its data.
    function test_largeUntrustedRoute_declinedCheaply() public {
        caller.configure(100e18, 100e18, 101e18, false);
        vm.prank(makeAddr("other"));
        settler.setRoute(address(exec), new bytes(32 * 1024));
        uint256 before = gasleft();
        vm.prank(address(caller));
        try settler.swap(_req(), true) {
            fail();
        } catch (bytes memory e) {
            assertEq(bytes4(e), JITSettler.RouteDeclined.selector);
        }
        assertLt(before - gasleft(), 60_000); // loading 1,024 words would cost about 2.1M
    }
}

/// Posts a different route from inside routeAvailable.
contract ReentrantCaller is ISettlerCaller {
    JITSettler immutable settler;
    MockToken immutable tIn;
    MockToken immutable tOut;
    address immutable recipient;
    address immutable exec;

    constructor(JITSettler s, MockToken i, MockToken o, address r, address e) {
        (settler, tIn, tOut, recipient, exec) = (s, i, o, r, e);
    }

    function routeAvailable(address) external returns (uint256) {
        settler.setRoute(
            exec, abi.encodeCall(FeeExecutor.fill, (tOut, 1, recipient, 0, address(this), ""))
        );
        tIn.approve(address(settler), 1e18);
        return 100e18;
    }

    function run() external returns (uint256) {
        return settler.swap(Request(address(tIn), address(tOut), 1e18, 0, recipient), true);
    }
}
