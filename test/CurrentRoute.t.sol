// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { JITSettler, Request } from "../src/JITSettler.sol";
import { MockToken, G } from "./JITSettler.t.sol";

/// A venue that records what `currentRoute` says when it is called, then pays `out` to `to`.
contract RecordingVenue {
    JITSettler public immutable settler;
    address public seenSetter;
    address public seenCaller;

    constructor(JITSettler s) {
        settler = s;
    }

    function fill(MockToken tokenOut, address to, uint256 out) external {
        (seenSetter, seenCaller) = settler.currentRoute();
        tokenOut.mint(to, out);
    }
}

/// An executor that, before calling the venue, runs a second route (posted by itself) through a
/// nested swap. The outer route must still be visible to the venue afterwards.
contract NestingExecutor {
    function run(
        JITSettler settler,
        address innerExecutor,
        bytes calldata innerData,
        MockToken tIn,
        MockToken tOut,
        RecordingVenue venue,
        address recipient,
        uint256 out
    ) external {
        settler.setRoute(innerExecutor, innerData);
        tIn.mint(address(this), 1);
        tIn.approve(address(settler), 1);
        settler.swap{ gas: G }(Request(address(tIn), address(tOut), 1, 0, address(this)), false);
        venue.fill(tOut, recipient, out);
    }
}

contract CurrentRouteTest is Test {
    JITSettler settler;
    MockToken tIn;
    MockToken tOut;
    RecordingVenue venue;
    address builder = makeAddr("builder");
    address aggregator = makeAddr("aggregator");
    address recipient = makeAddr("recipient");

    function setUp() public {
        settler = new JITSettler();
        tIn = new MockToken();
        tOut = new MockToken();
        venue = new RecordingVenue(settler);
        tIn.mint(aggregator, 10e18);
        vm.prank(aggregator);
        tIn.approve(address(settler), type(uint256).max);
    }

    function test_zeroOutsideSwap() public {
        (address s, address c) = settler.currentRoute();
        assertEq(s, address(0));
        assertEq(c, address(0));
    }

    function test_venueSeesSetterAndCaller_thenCleared() public {
        vm.prank(builder);
        settler.setRoute(
            address(venue), abi.encodeCall(RecordingVenue.fill, (tOut, recipient, 5e18))
        );
        vm.prank(aggregator);
        settler.swap{ gas: G }(Request(address(tIn), address(tOut), 1e18, 1, recipient), false);

        assertEq(venue.seenSetter(), builder);
        assertEq(venue.seenCaller(), aggregator);
        (address s, address c) = settler.currentRoute();
        assertEq(s, address(0));
        assertEq(c, address(0));
    }

    function test_nestedSwap_restoresOuterRoute() public {
        NestingExecutor nester = new NestingExecutor();
        RecordingVenue innerVenue = new RecordingVenue(settler);
        bytes memory innerData = abi.encodeCall(RecordingVenue.fill, (tOut, address(nester), 1));
        vm.prank(builder);
        settler.setRoute(
            address(nester),
            abi.encodeCall(
                NestingExecutor.run,
                (settler, address(innerVenue), innerData, tIn, tOut, venue, recipient, 5e18)
            )
        );
        vm.prank(aggregator);
        settler.swap{ gas: G }(Request(address(tIn), address(tOut), 1e18, 1, recipient), false);

        // The inner route was posted by the executor and swapped by it.
        assertEq(innerVenue.seenSetter(), address(nester));
        assertEq(innerVenue.seenCaller(), address(nester));
        // After the nested swap, the outer venue still sees the outer route.
        assertEq(venue.seenSetter(), builder);
        assertEq(venue.seenCaller(), aggregator);
    }
}
