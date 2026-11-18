# JITSettler

A settler for just-in-time (JIT) routes. A block builder posts a route for a swap in the
transaction just before that swap. The aggregator's swap then fills through the route, or falls
back to the aggregator's own default route.

We expect a builder to work with many routers and post, for each swap, the best route any of them
offers. Each route names its own executor, so adding a router needs no change to the settler.

Designed by Flashbots in collaboration with [Gattaca](https://github.com/gattaca-com), starting
from Gattaca's proof of concept,
[gattaca-com/jit-settler-poc](https://github.com/gattaca-com/jit-settler-poc).

**Status:** not audited and not deployed. The previous version, v1.3.0, is deployed on mainnet at
`0xd43F34Dd4fcEd2829eFfaC16064B436B98d23CF7`. Its source is in
[`reference/v1.3.0`](reference/v1.3.0) (see [History](#history)).

## How it works

`src/JITSettler.sol` has four functions, one route slot and a sandbox.

| Function | Caller | What it does |
|---|---|---|
| `setRoute(executor, data)` | builder | Stores the route for this block. The setter is `msg.sender`. A later post replaces an earlier one. |
| `peek(tokenIn, amountIn, tokenOut, amountOutMin, recipient, gasLimit)` | aggregator | Returns the setter of this block's route, or 0 if there is none. The settler ignores the arguments. They are there so a builder can read the request when it simulates the swap before posting. |
| `swap(tokenIn, amountIn, tokenOut, amountOutMin, recipient, gasLimit)` | aggregator | Runs the route and returns `amountOut`. Reverts if there is no route, the transfer or the executor fails, or the output is too low. A revert means "fall back". |
| `reportDefault(tokenIn, amountIn, tokenOut, amountOutMin, recipient, amountOut)` | aggregator | Emits `JITDefaultV1` after the aggregator ran its default route. Changes no state. |

Below, `req` is the six arguments of `peek` and `swap`. `gasLimit` is the most gas the route's
executor may use. It gets less if `swap` itself runs short of gas.

`swap`:

1. Checks that a route was posted in this block, and marks it used before any external call.
2. Transfers `amountIn` of `tokenIn` from `msg.sender` to the route's executor.
3. Calls the executor with the posted data, through the sandbox, with at most `gasLimit` gas.
4. Checks that `recipient`'s `tokenOut` balance grew by at least `amountOutMin`.
5. Emits `JITRoutedV1`.

### What a caller can rely on

- The settler makes one transfer of `amountIn` of `tokenIn`, from `msg.sender`. If the token takes
  a fee on transfer, the executor receives less.
- The recipient's `tokenOut` balance grows by at least `amountOutMin`, or the swap reverts.
- The sandbox, not the settler, calls the executor. A route therefore cannot spend approvals given
  to the settler, even if it names a token as its executor. Approve the settler, never the sandbox.
- A post allows at most one successful swap, in the block it was posted. A reverted swap leaves the
  route live.
- The setter is always `msg.sender` of `setRoute`, so nobody can post in someone else's name.

Anyone can post a route. Whether it beats the caller's default is up to the setter, unless the
caller checks.

The executor is code the setter chose, running inside the caller's transaction. It can call back
into the caller's contract, so every external function of the caller that changes state or moves
tokens needs a re-entry guard. It can also use all the gas it gets, which `gasLimit` bounds. Both
flows below show the guard.

### Integrating as a caller

The request is fixed when the user signs. The caller may branch on what `peek` returns. Both flows
take the same calldata: `req`, `trustedSetters` and `defaultRoute`.

**Flow A: efficient.** The caller trusts the setter to post only routes that beat its default.

```
function execute(req, trustedSetters, defaultRoute) nonReentrant:
    s = settler.peek(req)                    // setter, or 0
    if s != 0 and s in trustedSetters:
        try settler.swap(req) -> out:
            return out
        catch:
            // fall through to the default
    out = runDefault(defaultRoute)
    require(out >= userMinOut)
    settler.reportDefault(req, out)
    return out
```

With no route posted, this costs one `peek`.

**Flow B: conservative.** If `peek` shows a trusted route, the caller first measures what its
default would pay, and the JIT fill must beat it.

```
function execute(req, trustedSetters, defaultRoute) nonReentrant:
    s = settler.peek(req)
    if s != 0 and s in trustedSetters:
        try this.trialDefault(defaultRoute):     // always reverts
        catch (bytes err):
            if err is Measured(dOut):            // the default's output on the current state
                try this.jitSwap(req, dOut) -> out:
                    return out
                catch:
                    // fall through to the default
    out = runDefault(defaultRoute)
    require(out >= userMinOut)
    settler.reportDefault(req, out)
    return out

// Runs the default and reverts with its output, so it changes no state.
function trialDefault(defaultRoute):
    require(msg.sender == address(this))
    revert Measured(runDefault(defaultRoute))

// External so that try/catch can undo the swap if it does not beat dOut.
function jitSwap(req, dOut):
    require(msg.sender == address(this))     // nobody else may spend the contract's tokens
    out = settler.swap(req)
    require(out > dOut)
    return out
```

The caller compares with `dOut` after `swap`, so the settler's arguments stay fixed. `execute`
calls `trialDefault` and `jitSwap` on the same contract, so they have no re-entry guard; their
sender checks keep everyone else out. With no route posted, flow B also costs one `peek`. It runs the trial only when
a trusted route is live.

### Caller requirements

A builder can only route a caller's swaps if the caller follows these rules.

1. **Static request.** All six request fields are fixed when the user signs. They must not depend on
   state that the post or earlier transactions change, such as "my whole balance". Otherwise a
   route built for one request meets another and reverts.
2. **Visible without a route.** With no route posted, the transaction calls `peek`, `swap` or
   `reportDefault` with the request. This is how a builder finds the order.
3. **Report the default.** Whenever the default route runs, call `reportDefault`, once. Its
   `amountOut` is the benchmark a route has to beat. Builders read `JITDefaultV1` only from the
   settler, so emitting it from another contract does not count.
4. **Same request everywhere.** `peek` and `swap` get the same request, and `reportDefault` the
   same first five fields, so the builder can match them.
5. **Measure the default like a fill.** Report the growth of `recipient`'s `tokenOut` balance, as
   `swap` measures it, so the two outputs compare.
6. **Never fail the order on a JIT revert.** Call `swap` in `try`/`catch` and fall back on any
   revert. A route that was replaced, went stale or ran out of gas then costs a fall-back, not the
   user's transaction. `gasLimit` is an upper bound: if `swap` gets too little gas, the executor
   gets less than `gasLimit` and the route may fail. Before calling `swap`, make sure the
   transaction has gas for `gasLimit`, the settler's transfer and checks, the default route and
   the report. If it does not, skip the JIT attempt. Loading the route's data is outside
   `gasLimit` and costs about 2.1k gas per 32 bytes; the setter decides its size, which is one
   more reason to check setters.
7. **Funded and approved.** When it calls `swap`, `msg.sender` holds `amountIn` of `tokenIn` and
   has approved the settler for it.
8. **ERC-20 tokens only.** The settler uses `transferFrom` and `balanceOf`. Wrap or unwrap native
   ETH outside the JIT path.
9. **Check setters.** Keep a list of setters you trust and compare `peek`'s result with it. Without
   the check, flow A runs anyone's route. Whoever sees the transaction, for example in a public
   mempool, can post a route just before it that pays exactly `amountOutMin`, and keep the rest.

### What a builder does

1. Simulate the order at its place in the block, with no route posted. Read the request from the
   `peek`, `swap` or `reportDefault` call, and the default's output from `JITDefaultV1`.
2. Ask the routers for routes for that request that fit in `gasLimit`. Keep the best one that
   beats the default after the builder's fee.
3. Post it with `setRoute` directly before the order, from a setter the caller trusts.
4. Simulate the post and the order together, at the same place and on the same state as in step 1.
   Keep the post only if the order calls `swap`, the fill succeeds and the recipient gets more than
   the default paid in step 1. Otherwise drop the post, and the order runs its default.

The post only writes to the settler's storage. Steps 1 and 4 therefore see the same venues and
prices, so the default and the route are compared on the same state. Nothing between the post and
the order may call `swap`.

### Builders and executors

- **Fees.** The executor pays the recipient and the builder's fee out of the same route. The
  builder checks the split in its own simulation. The settler has no fee rule.
- **Several builders.** Each builder posts in the blocks it builds. The setter tells callers who
  posted.
- **Key rotation.** A builder can post through its own contract. The contract's address stays the
  same while the keys behind it change, so callers keep their lists.
- **Executors.** Any contract can be an executor, named per route, so a new router needs no
  settler change. `msg.sender == SANDBOX` tells an executor that it runs inside `swap` and has
  received `tokenIn`. Extra data, such as a signature, can follow the call data.
- **Venues.** While a route runs, `currentRoute()` returns its setter and the caller of `swap`
  (both 0 at any other time). A venue that wants to quote differently for JIT flow checks the
  setter against builders it trusts, and optionally the caller against known aggregators. The
  router's address alone does not show this, because anyone can post a route through any router.

### Events

```solidity
event JITRoutedV1(address indexed recipient, address indexed tokenIn, address indexed tokenOut,
                  uint256 amountIn, uint256 amountOutMin, uint256 amountOut);   // from swap

event JITDefaultV1(address indexed recipient, address indexed tokenIn, address indexed tokenOut,
                   uint256 amountIn, uint256 amountOutMin, uint256 amountOut);  // from reportDefault
```

Read both events from the settler's address only. Anyone can call `reportDefault`, so a
`JITDefaultV1` amount is the caller's claim. `JITRoutedV1` has no setter or executor: the block's
builder is a good proxy for the setter, and the executor is in the post just before the fill.

## Design choices

- **One route slot, last post wins.** The builder posts directly before each order and controls the
  order of its block, so routes need no per-request keys. One slot is also the cheapest storage.
  This relies on each post sitting directly before its order. If another post lands in between,
  the order reads that route. From a different setter, a caller that checks setters falls back.
  From the same setter, the replacement still has to pay at least `amountOutMin`, and in flow B
  beat the default.
- **No link between a route and a request.** A builder posts only when its simulation shows the
  order reading the route and succeeding. Setter checks cover anyone else's post. A route that does
  not fit the request either reverts, so the caller falls back, or still pays at least
  `amountOutMin`.
- **No owner, no upgrade.** Nobody can change what the settler does with callers' approvals. A new
  router is a new executor in a route, never a new settler.
- **Fees inside the executor.** Each builder sets its own terms and checks them in simulation. The
  settler has no fee logic to keep in step with builders.
- **Opaque route data, any executor.** Any router's format works, so one settler serves many routers
  and many builders.
- **A sandbox, not a fixed function selector.** If the contract holding callers' approvals called
  an arbitrary executor, a route could spend those approvals, for example by naming a token as the
  executor. A fixed selector would also stop that, barring a selector collision, but would limit
  executors to one function. The sandbox costs about 3.4k gas per routed swap.
- **`gasLimit` in the request.** The route's code could use up the gas the caller needs for its
  default. The settler gives the executor at most `gasLimit`, so the route's code cannot take more
  without the caller capping the call itself. Requirement 6 covers the rest of a JIT attempt's
  gas. Builders see the limit in `peek` before they post.
- **Small events.** `JITRoutedV1` and `JITDefaultV1` have the same fields, so routed and default
  outcomes compare directly.
- **The floor is `amountOutMin` only.** The settler cannot know what the default would have paid.
  A caller that wants that floor measures it (flow B).
- **`peek` takes the request.** In the builder's first simulation there is no route, so a caller
  that branches on `peek` never calls `swap`. The request has to be in the `peek` call.

## Gas

Measured on a mainnet fork at block 26,410,000: 1 WETH to USDC through the Uniswap V3 5 bps pool,
each call in its own transaction. Figures are the gas of the call, without the 21,000 base cost
and calldata. The v1.3.0 column uses the deployed settler and router. The PoC and JITSettler use
the same router logic and compiler settings, adapted to the sandbox and paying the recipient
directly. The v1.3.0 column therefore compares whole designs, not just settler overhead. A v1.3.0
post is a signed two-word update to the `PrioUpdateRegistry`; a JITSettler post stores the
executor's call data.

| Measurement | v1.3.0 | Gattaca PoC | JITSettler |
|---|---|---|---|
| Routed swap | 194,930 | 172,379 | 175,353 |
| Caller side, routed: `peek` + `swap` | 224,270 (`swap` only) | 195,766 | 198,976 |
| Caller side, no route: `peek` only | 10,389 (failed `swap`) | 5,368 | 5,761 |
| Post a route | 44,989 | 57,871 | 57,875 |

- Compared with the PoC, a routed swap costs about 3.0k more, mostly for `JITRoutedV1`, and `peek`
  about 0.4k more for its arguments.
- A post stores the executor's call data as is: 260 bytes, or 9 storage slots, in this test. Each
  extra 32 bytes costs about 5.6k to post when the stored word changes.
- The sandbox adds about 3.4k to a routed swap.
- `currentRoute` bookkeeping adds about 1.3k to a routed swap (measured after the table above).

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
