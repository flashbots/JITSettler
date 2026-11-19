// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { JITSettler, IJITEvents, ISettlerCaller, Request } from "../src/JITSettler.sol";
import { MockToken, FeeExecutor, GasBurner } from "./JITSettler.t.sol";

/// A callback caller. `routeAvailable` checks the settler and the setter, optionally trials its
/// default route through a reverting self-call, approves the settler and returns its floor.
contract CallbackCaller is ISettlerCaller {
    error Measured(uint256 out);

    JITSettler public immutable settler;
    MockToken public immutable tIn;
    MockToken public immutable tOut;
    address public immutable trustedSetter;
    address public immutable recipient;

    uint256 public staticFloor;
    uint256 public defaultOut; // what the simulated default route pays
    bool public trialDefault;
    bool public declineAll;
    uint256 public callbacks;

    constructor(JITSettler s, MockToken i, MockToken o, address setter, address r) {
        settler = s;
        tIn = i;
        tOut = o;
        trustedSetter = setter;
        recipient = r;
    }

    function configure(uint256 floor_, uint256 defaultOut_, bool trial_, bool decline_) external {
        (staticFloor, defaultOut, trialDefault, declineAll) =
        (floor_, defaultOut_, trial_, decline_);
    }

    function routeAvailable(address setter) external returns (uint256) {
        require(msg.sender == address(settler), "not settler");
        require(setter == trustedSetter && !declineAll, "declined");
        callbacks++;
        uint256 floor = staticFloor;
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

    /// The caller's whole swap: JIT if executed, else the default route.
    function run(uint256 gasLimit) external returns (JITSettler.Outcome outcome, uint256 out) {
        (outcome, out) =
            settler.swapWithCallback(address(tIn), address(tOut), 1e18, recipient, gasLimit);
        if (outcome != JITSettler.Outcome.EXECUTED) {
            tIn.approve(address(settler), 0);
            out = _runDefault();
            settler.reportDefault(
                Request(address(tIn), address(tOut), 1e18, staticFloor, recipient, gasLimit), out
            );
        }
    }

    /// Like `run`, but catches a revert from the settler (route paid too little) and falls back.
    function runCatching(uint256 gasLimit)
        external
        returns (JITSettler.Outcome outcome, uint256 out, bool reverted)
    {
        try settler.swapWithCallback(
            address(tIn), address(tOut), 1e18, recipient, gasLimit
        ) returns (
            JITSettler.Outcome o, uint256 a
        ) {
            (outcome, out) = (o, a);
        } catch {
            reverted = true;
        }
        if (outcome != JITSettler.Outcome.EXECUTED) out = _runDefault();
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

    function _peek() internal view returns (address) {
        return settler.peek(Request(address(tIn), address(tOut), 1e18, 0, recipient, 0));
    }

    function test_noRoute_returnsNoRoute_noCallback() public {
        caller.configure(100e18, 101e18, false, false);
        (JITSettler.Outcome o, uint256 out) = caller.run(1_000_000);
        assertEq(uint8(o), uint8(JITSettler.Outcome.NO_ROUTE));
        assertEq(out, 101e18);
        assertEq(caller.callbacks(), 0);
    }

    function test_betterRoute_executes_emits() public {
        caller.configure(100e18, 101e18, false, false);
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
        (JITSettler.Outcome o, uint256 out) = caller.run(1_000_000);
        assertEq(uint8(o), uint8(JITSettler.Outcome.EXECUTED));
        assertEq(out, 105e18);
        assertEq(tOut.balanceOf(recipient), 105e18);
        assertEq(_peek(), address(0)); // used
    }

    /// The trial of the default inside the callback sets the floor above the default's output,
    /// and changes no state.
    function test_trialFloor_betterRoute_executes() public {
        caller.configure(0, 104e18, true, false);
        _post(builder, 110e18, 105e18);
        (JITSettler.Outcome o, uint256 out) = caller.run(1_000_000);
        assertEq(uint8(o), uint8(JITSettler.Outcome.EXECUTED));
        assertEq(out, 105e18);
        assertEq(tOut.balanceOf(recipient), 105e18); // the trial's mint was reverted
    }

    function test_trialFloor_worseRoute_revertsAndFallsBack() public {
        caller.configure(0, 106e18, true, false);
        _post(builder, 110e18, 105e18);
        (JITSettler.Outcome o, uint256 out, bool reverted) = caller.runCatching(1_000_000);
        assertTrue(reverted);
        assertEq(uint8(o), uint8(JITSettler.Outcome.NO_ROUTE)); // default value: not executed
        assertEq(out, 106e18);
        assertEq(tOut.balanceOf(recipient), 106e18);
        assertEq(tIn.balanceOf(address(caller)), 10e18);
        assertEq(_peek(), builder); // the revert undid the consumption
    }

    function test_untrustedSetter_declined_routeUsed() public {
        caller.configure(100e18, 101e18, false, false);
        _post(makeAddr("other"), 110e18, 105e18);
        (JITSettler.Outcome o, uint256 out) = caller.run(1_000_000);
        assertEq(uint8(o), uint8(JITSettler.Outcome.ROUTE_DECLINED));
        assertEq(out, 101e18);
        assertEq(_peek(), address(0)); // a declined route stays used
        assertEq(tIn.balanceOf(address(caller)), 10e18);
    }

    /// A caller without code, or without routeAvailable, declines instead of reverting.
    function test_eoaCaller_declines() public {
        address eoa = makeAddr("eoa");
        _post(builder, 110e18, 105e18);
        vm.prank(eoa);
        (JITSettler.Outcome o,) =
            settler.swapWithCallback(address(tIn), address(tOut), 1e18, recipient, 0);
        assertEq(uint8(o), uint8(JITSettler.Outcome.ROUTE_DECLINED));
    }

    function test_contractWithoutCallback_declines() public {
        _post(builder, 110e18, 105e18);
        vm.prank(address(tIn)); // a contract with no routeAvailable and no fallback
        (JITSettler.Outcome o,) =
            settler.swapWithCallback(address(tIn), address(tOut), 1e18, recipient, 0);
        assertEq(uint8(o), uint8(JITSettler.Outcome.ROUTE_DECLINED));
    }

    /// The gas limit applies to the executor after the callback; a burner route reverts the call
    /// without eating the caller's gas.
    function test_gasLimit_capsExecutor_afterCallback() public {
        caller.configure(1, 101e18, false, false);
        GasBurner burner = new GasBurner();
        vm.prank(builder);
        settler.setRoute(address(burner), abi.encodeCall(GasBurner.burn, ()));
        uint256 before = gasleft();
        (,, bool reverted) = caller.runCatching(100_000);
        assertTrue(reverted);
        assertLt(before - gasleft(), 300_000);
        assertEq(caller.callbacks(), 0); // the counted callback was reverted with the rest
    }

    /// A route posted from inside the callback does not replace the one being run, and
    /// `currentRoute` is 0 during the callback.
    /// A callback that posts a route could overwrite the data of the route being run, which is
    /// loaded only after the callback, so the call counts as declined and nothing runs.
    function test_routePostedInCallback_declines() public {
        ReentrantCaller rc = new ReentrantCaller(settler, tIn, tOut, recipient, address(exec));
        tIn.mint(address(rc), 1e18);
        _post(builder, 110e18, 105e18);
        (JITSettler.Outcome o, uint256 out) = rc.run();
        assertEq(uint8(o), uint8(JITSettler.Outcome.ROUTE_DECLINED));
        assertEq(out, 0);
        assertEq(rc.seenSetter(), address(0));
        assertEq(tOut.balanceOf(recipient), 0);
        assertEq(tIn.balanceOf(address(rc)), 1e18);
        // The route posted inside the callback is live, with rc as its setter.
        assertEq(_peek(), address(rc));
    }

    /// Declining a large route from an untrusted setter does not load its data.
    function test_largeUntrustedRoute_declinedCheaply() public {
        caller.configure(100e18, 101e18, false, false);
        vm.prank(makeAddr("other"));
        settler.setRoute(address(exec), new bytes(32 * 1024));
        uint256 before = gasleft();
        vm.prank(address(caller));
        (JITSettler.Outcome o,) =
            settler.swapWithCallback(address(tIn), address(tOut), 1e18, recipient, 0);
        uint256 used = before - gasleft();
        assertEq(uint8(o), uint8(JITSettler.Outcome.ROUTE_DECLINED));
        assertLt(used, 60_000); // about 39k; loading 1,024 words would cost about 2.1M
    }
}

/// Posts a different route from inside routeAvailable and records currentRoute.
contract ReentrantCaller is ISettlerCaller {
    JITSettler immutable settler;
    MockToken immutable tIn;
    MockToken immutable tOut;
    address immutable recipient;
    address immutable exec;
    address public seenSetter = address(1);

    constructor(JITSettler s, MockToken i, MockToken o, address r, address e) {
        (settler, tIn, tOut, recipient, exec) = (s, i, o, r, e);
    }

    function routeAvailable(address) external returns (uint256) {
        (seenSetter,) = settler.currentRoute();
        settler.setRoute(
            exec, abi.encodeCall(FeeExecutor.fill, (tOut, 1, recipient, 0, address(this), ""))
        );
        tIn.approve(address(settler), 1e18);
        return 100e18;
    }

    function run() external returns (JITSettler.Outcome, uint256) {
        return settler.swapWithCallback(address(tIn), address(tOut), 1e18, recipient, 0);
    }
}
