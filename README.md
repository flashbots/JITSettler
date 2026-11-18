# JITSettler

A settler for just-in-time (JIT) routes. A block builder posts a route for a swap in a transaction
right before the swap, in the same block. The aggregator's swap then fills through that route, or
falls back to the aggregator's own default route.

The intention is that a builder integrates many routers and, for each swap, posts the best route
any of them provides. The route names its executor, so the settler runs any router's route and
adding a router needs no change to the settler.

Designed by Flashbots in collaboration with [Gattaca](https://github.com/gattaca-com). The design
starts from Gattaca's proof of concept,
[gattaca-com/jit-settler-poc](https://github.com/gattaca-com/jit-settler-poc).

**Status:** not audited and not deployed. The previous version, v1.3.0, is deployed on mainnet at
`0xd43F34Dd4fcEd2829eFfaC16064B436B98d23CF7` and kept under
[`reference/v1.3.0`](reference/v1.3.0) (see [History](#history)).

## How it works

`src/JITSettler.sol` has four functions, one route slot and a sandbox.

| Function | Who calls it | What it does |
|---|---|---|
| `setRoute(executor, data)` | builder | Stores the route for this block. The setter is `msg.sender`. A later post overwrites an earlier one. |
| `peek(tokenIn, amountIn, tokenOut, amountOutMin, recipient, gasLimit)` | caller | Returns the setter of the route that is live in this block, or 0. The arguments are not used on chain; they let a builder read the request when it simulates the swap before any route is posted. |
| `swap(tokenIn, amountIn, tokenOut, amountOutMin, recipient, gasLimit)` | caller | Runs the live route and returns `amountOut`. Reverts if the call has more gas than `gasLimit`, there is no route, the transfer or the executor fails, or the output is too low. A revert means "fall back". |
| `reportDefault(tokenIn, amountIn, tokenOut, amountOutMin, recipient, amountOut)` | caller | Emits `JITDefaultV1` when the caller ran its own default route. Changes no state. |

The six fields `peek` and `swap` take are the request, written `req` below. `gasLimit` is the most
gas the `swap` call may have.

`swap`:

1. Requires that the call arrived with at most `gasLimit` gas, so the caller applied its cap.
2. Requires a route posted in this block, and marks it used before any external call.
3. Transfers `amountIn` of `tokenIn` from `msg.sender` to the route's executor.
4. Calls the executor with the posted data, through the sandbox.
5. Requires that `recipient`'s `tokenOut` balance grew by at least `amountOutMin`.
6. Emits `JITRoutedV1`.

### What a caller can rely on

- The settler makes one transfer of `amountIn` of `tokenIn`, from `msg.sender`. With a token that
  charges fees on transfer, the executor receives less.
- The recipient's `tokenOut` balance grows by at least `amountOutMin`, or the swap reverts.
- The executor is called by the sandbox, not the settler, so a route cannot spend what callers
  approved to the settler, even by naming a token as the executor. Approve the settler, never
  the sandbox.
- A post allows at most one successful swap, and only in the block it was posted. A swap that
  reverts leaves the route live.
- Nobody can post as someone else: the setter is always `msg.sender` of `setRoute`.

Anyone can post a route. A caller that cares who posted it checks the setter that `peek` returns
against its own list. Whether a route beats the caller's default is the setter's promise, unless
the caller compares the two itself.

The executor is whatever code the setter chose, and it runs inside the caller's transaction. The
sandbox keeps it from spending approvals given to the settler, nothing more. It can call back
into the caller's contract, so guard the caller's entry points against re-entry, and it can use
up the gas it is given, which `gasLimit` caps. Both flows below show the guard and the cap.

### Integrating as a caller

The request is fixed when the user signs. The caller may branch on what `peek` returns. Both
flows below take the same fixed calldata: `req`, `trustedSetters` and `defaultRoute`.

**Flow A: efficient.** The caller trusts the setter to post only a route that beats its default.

```
function execute(req, trustedSetters, defaultRoute) nonReentrant:
    s = settler.peek(req)                               // setter, or 0
    if s != 0 and s in trustedSetters:
        try settler.swap{gas: req.gasLimit}(req) -> out:
            return out
        catch:
            // fall through to the default
    out = runDefault(defaultRoute)
    require(out >= userMinOut)
    settler.reportDefault(req, out)        // or emit JITDefaultV1 from the caller's contract
    return out
```

With no route posted, this costs one `peek` and never calls `swap`.

**Flow B: conservative.** When `peek` shows a trusted route, the caller first measures what its
default route would give, and a JIT fill must beat that.

```
function execute(req, trustedSetters, defaultRoute) nonReentrant:
    s = settler.peek(req)
    if s != 0 and s in trustedSetters:
        dOut = trial { runDefault(defaultRoute); measure; revert }   // the default's output now
        try this.jitSwap(req, dOut) -> out:
            return out
        catch:
            // fall through to the default
    out = runDefault(defaultRoute)
    require(out >= userMinOut)
    settler.reportDefault(req, out)
    return out

// External only so that try/catch can undo the swap when it does not beat dOut.
function jitSwap(req, dOut):
    require(msg.sender == address(this))   // nobody else may spend the contract's tokens
    out = settler.swap{gas: req.gasLimit}(req)
    require(out > dOut)
    return out
```

The comparison with `dOut` happens in the caller after `swap`, so the settler's arguments stay
fixed. `jitSwap` is called by `execute` on the same contract, so it does not take the re-entry
guard; its sender check keeps everyone else out. With no route posted, flow B costs one `peek`,
the same as flow A; the trial of the default runs only when a trusted route is live.

### Caller requirements

A builder can only route a caller's swaps if the caller keeps to these.

1. **Static request.** `tokenIn`, `amountIn`, `tokenOut`, `amountOutMin`, `recipient` and
   `gasLimit` are fixed when the user signs. They must not depend on state that the builder's
   post or earlier transactions change (for example "my whole balance"), or a route built for one
   request meets another and reverts.
2. **Visible without a route.** In a simulation with no route posted, the transaction calls `peek`
   or `swap`, or emits `JITDefaultV1`, with the request. That is how a builder finds the order.
3. **Report the default.** Whenever the default route runs, the caller emits `JITDefaultV1`, through
   `reportDefault` or from its own contract. Its `amountOut` is the benchmark a route must beat.
   Report only when the default actually ran, once per request.
4. **One request everywhere.** `peek` and `swap` carry the same request, and the report the same
   first five fields, so the builder can match them.
5. **Measure the default like a fill.** `amountOut` in the report is the growth of `recipient`'s
   `tokenOut` balance, as `swap` measures it, so the two outputs compare.
6. **A JIT revert never fails the order.** Call `swap{gas: gasLimit}` in `try`/`catch` and fall
   back on any revert. A route that was overwritten, went stale or ran out of gas then costs a
   fall-back, not the user's transaction. Choose `gasLimit` to leave enough gas for the default
   route and the report. A call without the cap reverts, so it falls back too.
7. **Funded and approved.** When it calls `swap`, `msg.sender` holds `amountIn` of `tokenIn` and
   has approved the settler for it.
8. **ERC-20 tokens.** The settler moves `tokenIn` with `transferFrom` and measures `tokenOut` with
   `balanceOf`. Wrap or unwrap native ETH outside the JIT path.
9. **Check setters.** Keep a list of setters you trust and compare `peek`'s result against it.
   Without that check, flow A runs anyone's route: whoever sees the transaction, for example in a
   public mempool, can post a route just before it that pays exactly `amountOutMin` and keep the
   difference. Both flows above check the setter.

### Builder behaviour

At a high level, a builder:

1. simulates the order at its position in the block with no route posted, finds the `peek` or
   `swap` call or the `JITDefaultV1` event, and reads the request from it and the default's
   output from `JITDefaultV1`;
2. asks its routers for routes for that request that fit under `gasLimit`, and keeps the best one
   that beats the default after the builder's fee;
3. posts it with `setRoute`, immediately before the order, from a setter the caller trusts;
4. simulates the post and the order together, at the same position and on the same state as in
   step 1, and keeps the post only if the order calls `swap`, the fill succeeds and the recipient
   gets more than the default did in step 1. Otherwise it drops the post and the order runs its
   default.

The post changes only the settler's storage, so steps 1 and 4 see the same venues and the same
prices: the default's output and the route's output are compared on the same state. Nothing
between the post and the order calls `swap`.

### Builders and executors

- **Fees.** The executor pays the recipient and any builder fee from the same route. The builder
  checks the split in its own simulation. The settler enforces no fee rule.
- **Several builders.** Each builder posts in the blocks it builds. The setter tells callers who
  posted.
- **Key rotation.** A builder can post through its own contract. That address stays fixed while
  the keys behind it change, so callers' lists do not need to change.
- **Executors.** Any contract can be an executor, named per route, so a new router needs no
  settler change. `msg.sender == SANDBOX` tells an executor that it runs inside `swap` and that
  `tokenIn` has been delivered. Extra data, for example a signature, can follow the call data.

### Events

```solidity
event JITRoutedV1(address indexed recipient, address indexed tokenIn, address indexed tokenOut,
                  uint256 amountIn, uint256 amountOutMin, uint256 amountOut);   // emitted by swap

event JITDefaultV1(address indexed recipient, address indexed tokenIn, address indexed tokenOut,
                   uint256 amountIn, uint256 amountOutMin, uint256 amountOut,
                   address reporter);                   // emitted by reportDefault
```

`JITRoutedV1` carries only what the fill itself shows. The block's builder stands in for the
setter, and the executor is in the post just before the fill.

Anyone can call `reportDefault`, and anyone can emit `JITDefaultV1`. Trust a `JITDefaultV1` log
only if the settler emitted it and `reporter` is a caller you know, or that caller emitted it
itself. Its amounts are the reporter's claim.

## Design choices

- **One route slot, and the last post wins.** The builder posts right before each order and
  controls the order of its block, so routes need no per-request keys, and one slot is the
  cheapest storage. Every post overwrites the last, so this relies on each post sitting directly
  before its order. A post that lands in between, for example a third party's, makes the order
  see another setter or an overwritten route, and a caller that checks setters falls back.
- **No binding between a route and a request.** A builder posts only when its simulation shows the
  order reading the route and succeeding. Setter checks cover anyone else's post. A route that
  does not fit the request either reverts, so the caller falls back, or still pays the recipient
  at least `amountOutMin`.
- **No owner, no upgrade.** Nobody can change what the settler does with callers' approvals. A new
  router is a new executor named in a route, never a new settler.
- **Fees inside the executor.** Each builder sets its own terms and checks them in its own
  simulation. The settler has no fee logic to keep in step with builders.
- **Opaque route data and any executor.** Any router's format works, so one settler serves many
  routers and many builders.
- **A sandbox, not a fixed function selector.** Calling an arbitrary executor from the contract
  that holds callers' approvals would let a route spend them, for example by naming a token as the
  executor. A fixed function selector would also prevent that, short of a selector collision, but
  would limit executors to one function. The sandbox costs about 3.4k per routed swap
  and lets a route call any function.
- **`gasLimit` in the request.** A route is code the setter chose, and it could use up the gas
  the caller needs for its default. The settler reverts a call that arrives with more than
  `gasLimit`, so a caller cannot forget the cap, and builders see the limit in `peek` before
  they post.
- **Lean events.** `JITRoutedV1` and `JITDefaultV1` carry the same request fields and the output,
  so routed and default outcomes compare directly. Who posted and which router ran are visible in
  the block. `JITDefaultV1` keeps `reporter` because anyone can call `reportDefault`.
- **The floor is `amountOutMin` only.** The settler cannot know what the default would have paid.
  A caller that wants that floor measures it itself (flow B).
- **`peek` takes the request.** In the builder's first simulation no route is posted, so a caller
  that branches on `peek` never calls `swap`. The request has to be visible in the `peek` call.

## Gas

Measured on a mainnet fork at block 26,410,000: 1 WETH to USDC through the Uniswap V3 5 bps pool,
each call in its own transaction. Figures are the gas of the call, without the 21,000 base cost
and calldata. v1.3.0 is the deployed settler and router. The PoC and JITSettler run the same
router logic and compiler settings, adapted to the sandbox and paying the recipient directly,
so the v1.3.0 column compares whole designs, not settler overhead alone. A v1.3.0 post is a
signed update of two words to the `PrioUpdateRegistry`; a JITSettler post stores the executor's
call data.

| Measurement | v1.3.0 | Gattaca PoC | JITSettler |
|---|---|---|---|
| Routed swap | 194,930 | 172,379 | 175,366 |
| Caller side, routed: `peek` + `swap` | 224,270 (`swap` only) | 195,766 | 198,989 |
| Caller side, no route: `peek` only | 10,389 (failed `swap`) | 5,368 | 5,761 |
| Post a route | 44,989 | 57,871 | 57,875 |

- Against the PoC, a routed swap costs about 3.0k more, mostly for the `JITRoutedV1` event, and
  `peek` about 0.4k more for its arguments.
- A post stores the executor's call data as is: 260 bytes, 9 storage slots, in this test. Each
  extra 32 bytes costs about 5.6k to post when the stored word changes.
- The sandbox adds about 3.4k to a routed swap.

## Development

```
git clone --recursive https://github.com/flashbots/JITSettler
forge test
```

## History

This repository carries the settler's history from the Flashbots JIT routing contracts:

| Version | Date | Change |
|---|---|---|
| v1.0.0 | 2026-10-26 | First release: routes in 256 lanes of the `PrioUpdateRegistry`, keyed by request; one router per settler |
| v1.1.0 | 2026-10-27 | Treasury contract for posting charges |
| v1.2.0 | 2026-11-04 | `peek` removed |
| v1.3.0 | 2026-11-10 | `peek` restored |
| JITSettler | 2026-11-18 | Single route slot, any executor, any builder; designed with Gattaca |

The router and its venue adapters are not in this repository.

## License

[MIT](LICENSE)
