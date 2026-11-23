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

`src/JITSettler.sol` has one route slot, a sandbox and these functions.

| Function | Caller | What it does |
|---|---|---|
| `setRoute(executor, data)` | builder | Stores the route for this block. The setter is `msg.sender`. A later post replaces an earlier one. |
| `peek(req)` | aggregator | Returns the setter of this block's route, or 0 if there is none. The settler ignores `req`. It is there so a builder can read the request when it simulates the swap before posting. |
| `swap(req, callback)` | aggregator | Runs the route and returns `amountOut`. With `callback` set, it first asks the caller whether to run the route and for its floor. Reverts if there is no route, the caller declines, the route fails, or the output is too low. A revert means "fall back". |
| `reportDefault(req, amountOut)` | aggregator | Emits `JITDefaultV1` after the aggregator ran its default route. Optional. Changes no state. |
| `currentRoute()` | executor, venue | While a route runs, returns its setter and the caller of the swap; otherwise 0. |

Below, `req` is the request `(tokenIn, tokenOut, amountIn, amountOutMin, recipient)`. The route
gets all the gas the call to `swap` has, so the caller caps its own call (requirement 6).

`swap`:

1. Checks that a route was posted in this block, and marks it used before any external call.
   If there is none, reverts with `NoRoute`.
2. With `callback` set, calls `routeAvailable(setter)` on `msg.sender`. The caller returns its
   floor, or reverts to decline, and `swap` then reverts with `RouteDeclined`. The floor is the
   larger of `req.amountOutMin` and the returned value, so the callback can raise the floor but
   never lower it. Without `callback`, the floor is `req.amountOutMin`.
3. Loads the route's data.
4. Transfers `amountIn` of `tokenIn` from `msg.sender` to the route's executor.
5. Calls the executor with the posted data, through the sandbox.
6. Checks that `recipient`'s `tokenOut` balance grew by at least the floor.
7. Emits `JITRoutedV1`.

### What a caller can rely on

- The settler makes one transfer of `amountIn` of `tokenIn`, from `msg.sender`. If the token takes
  a fee on transfer, the executor receives less.
- The recipient's `tokenOut` balance grows by at least the floor, or the swap reverts. The
  settler measures only the balance change. If `tokenOut` rebases, or a token hook (for example
  ERC-777) lets someone pay the recipient during the swap, that counts as output too.
- The sandbox, not the settler, calls the executor. A route therefore cannot spend approvals given
  to the settler, even if it names a token as its executor. Approve the settler, never the sandbox.
- A post allows at most one successful swap, in the block it was posted. A reverted swap,
  including a declined one, leaves the route live. "In the block" means "at the same `block.timestamp`", which is one block on Ethereum
  mainnet. On a chain where several blocks share a timestamp, a route lives across all of them.
- The setter is always `msg.sender` of `setRoute`, so nobody can post in someone else's name.

Anyone can post a route. Whether it beats the caller's default is up to the setter, unless the
caller checks.

The executor is code the setter chose, running inside the caller's transaction. It can call back
into the caller's contract, so every external function of the caller that changes state or moves
tokens needs a re-entry guard. It can also use all the gas it gets, so the caller caps its call to
the settler. The flows below show the guard.

### Integrating as a caller

The request is fixed when the user signs. Flows A and B branch on what `peek` returns and call
`swap(req, false)`. Flow C calls `swap(req, true)`, which asks the caller instead. All three take
the same calldata: `req`, `trustedSetters` and `defaultRoute`. A caller that cannot add contract code can
still use flow A through generic call actions, if it can catch a revert and fall back.

**Flow A: efficient.** The caller trusts the setter to post only routes that beat its default.

```
function execute(req, trustedSetters, defaultRoute) nonReentrant:
    s = settler.peek(req)                    // setter, or 0
    if s != 0 and s in trustedSetters:
        try settler.swap{gas: cap}(req, false) -> out:  // the caller caps the route's gas
            return out
        catch:
            // fall through to the default
    out = runDefault(defaultRoute)
    require(out >= userMinOut)
    settler.reportDefault(req, out)
    return out
```

With no route posted, this costs one `peek`. The setter check matters: `swap` runs whatever route
is live, from anyone (requirement 9).

**Flow B: conservative.** If `peek` shows a trusted route, the caller first measures what its
default would pay, and the JIT fill must beat it.

```
function execute(req, trustedSetters, defaultRoute) nonReentrant:
    s = settler.peek(req)
    if s != 0 and s in trustedSetters:
        try this.trialDefault(defaultRoute):     // always reverts
        catch (bytes err):
            if err is Measured(dOut):            // the default's output on the current state
                try this.jitSwap{gas: cap}(req, dOut) -> out:
                    return out
                catch:
                    // fall through to the default
    out = runDefault(defaultRoute)
    require(out >= userMinOut)
    settler.reportDefault(req, out)
    return out

// Runs the default and reverts with its output, so it changes no state. Any contract the default
// calls could revert with Measured(0) itself, so a failure of the default becomes another error.
function trialDefault(defaultRoute):
    require(msg.sender == address(this))
    try this.defaultOnce(defaultRoute) -> dOut:
        revert Measured(dOut)
    catch:
        revert DefaultFailed()

function defaultOnce(defaultRoute):
    require(msg.sender == address(this))
    return runDefault(defaultRoute)

// External so that try/catch can undo the swap if it does not beat dOut.
function jitSwap(req, dOut):
    require(msg.sender == address(this))     // nobody else may spend the contract's tokens
    out = settler.swap(req, false)
    require(out > dOut)
    return out
```

The caller compares with `dOut` after `swap`, so the settler's arguments stay fixed. `execute`
calls `trialDefault`, `defaultOnce` and `jitSwap` on the same contract, so they have no re-entry
guard; their sender checks keep everyone else out. With no route posted, flow B also costs one
`peek`. It runs the trial only when a trusted route is live.

**Flow C: callback.** The settler asks the caller. With no route it reverts with `NoRoute`
without a callback. With a live route it calls `routeAvailable(setter)` on the caller, which
returns the floor or reverts to decline. The floor can come from a trial of the default, as in
flow B.

```
function execute(req, trustedSetters, defaultRoute) nonReentrant:
    try settler.swap{gas: cap}(req, true) -> out:
        return out
    catch:
        // no route, declined, or the route failed; fall through to the default
    out = runDefault(defaultRoute)
    require(out >= userMinOut)
    return out

function routeAvailable(setter) -> floor:
    require(msg.sender == settler and inExecute)
    require(setter in trustedSetters)          // a revert declines the route
    approve(settler, req.amountIn)             // approve only when a route exists
    return 0                                   // or dOut + 1 from a trial of the default
```

Set `req.amountOutMin` to the user's minimum. The callback can only raise the floor above it.
The route's data is loaded only after the caller accepts, so declining a large route costs
little. A decline reverts, so the route stays live for later callers. The gas cap on the call has
to cover the callback as well as the route. If the callback posts a route itself, the call counts
as declined. Only set `callback` if your contract implements `routeAvailable`: a caller without
it declines every route. A revert's data may come from the executor, so treat any revert as
"fall back".

### Caller requirements

A builder can only route a caller's swaps if the caller follows these rules.

1. **Static request.** All five request fields are fixed when the user signs. They must not depend on
   state that the post or earlier transactions change, such as "my whole balance". Otherwise a
   route built for one request meets another and reverts.
2. **Visible without a route.** With no route posted, the transaction calls `peek`, `swap` or
   `reportDefault` with the request. This is how a builder finds the order.
3. **Report the default (optional).** When the default route runs, a caller may call
   `reportDefault`, once. Its `amountOut` gives the builder the benchmark a route has to beat.
   Builders count a report only when its `reporter` is the contract that called `peek` or a swap
   function, so another contract in the transaction cannot fake one. Without a report, the builder
   traces the default's transfers.
4. **Same request everywhere.** `peek`, `swap` and `reportDefault` get the same request, so the
   builder can match them.
5. **Measure the default like a fill.** Report the growth of `recipient`'s `tokenOut` balance, as
   `swap` measures it, so the two outputs compare.
6. **Never fail the order on a JIT revert.** Call `swap` in `try`/`catch` and fall back on any
   revert. A route that was replaced, went stale or ran out of gas then costs a fall-back, not the
   user's transaction. The route gets all the gas the call has, so cap your own call, for example
   `settler.swap{gas: cap}(req, false)`. The cap bounds everything the route can cost you:
   loading its data (about 2.1k gas per 32 bytes, size chosen by the setter), the transfer of
   `tokenIn` (including any token hooks) and the executor. Builders read the gas your call gets
   in simulation and treat it as the route's budget, so a cap also tells them which routes fit.
   A caller that does not check setters must cap. Before the call, make sure the transaction has
   gas for the cap, the default route and the report. If it does not, skip the JIT attempt.
7. **Funded and approved.** When it calls `swap`, `msg.sender` holds `amountIn` of `tokenIn` and
   has approved the settler for it.
8. **ERC-20 tokens only.** The settler uses `transferFrom` and `balanceOf`. Wrap or unwrap native
   ETH outside the JIT path.
9. **Check setters.** Keep a list of setters you trust and compare `peek`'s result with it. Without
   the check, flow A runs anyone's route. Whoever sees the transaction, for example in a public
   mempool, can post a route just before it that pays exactly `amountOutMin`, and keep the rest.

### What a builder does

1. Simulate the order at its place in the block, with no route posted. Read the request from the
   `peek`, `swap` or `reportDefault` call, and the default's output from
   `JITDefaultV1` or from a trace of the default's transfers.
2. Ask the routers for routes for that request that fit in the gas the caller's `swap` call
   gets. Keep the best one that beats the default after the builder's fee.
3. Post it with `setRoute` directly before the order, from a setter the caller trusts.
4. Simulate the post and the order together, at the same place and on the same state as in step 1.
   Keep the post only if the order calls `swap`, the fill succeeds, the whole transaction
   succeeds and the recipient gets more than the default paid in step 1. Otherwise drop the post, and the order runs its default.

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
  settler change. `msg.sender == SANDBOX` only tells an executor that some swap is running:
  anyone can post a route that names any executor with any data, and then swap with any token
  and `amountIn = 0`. An executor that holds funds or acts on signed data checks
  `currentRoute().setter` against the setters it serves, and checks the `tokenIn` it actually
  received. Extra data, such as a signature, can follow the call data.
- **Venues.** While a route runs, `currentRoute()` returns its setter and the caller of the swap
  (both 0 at any other time). Any contract the executor calls sees the same values, so the setter
  vouches for every call its route makes. A venue that wants to quote differently for JIT flow checks the
  setter against builders it trusts, and optionally the caller against known aggregators. The
  router's address alone does not show this, because anyone can post a route through any router.

### Events

```solidity
// From swap.
event JITRoutedV1(address indexed caller, address indexed setter, address indexed executor,
                  address tokenIn, address tokenOut, address recipient,
                  uint256 amountIn, uint256 amountOutMin, uint256 amountOut);

// From reportDefault.
event JITDefaultV1(address indexed reporter, address indexed tokenIn, address indexed tokenOut,
                   address recipient, uint256 amountIn, uint256 amountOutMin, uint256 amountOut);
```

Read both events from the settler's address only. A `JITDefaultV1` amount is the reporter's claim.
In `JITRoutedV1`, `amountOutMin` is the floor that applied: the larger of `req.amountOutMin` and
the callback's value.

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
- **No gas limit in the request.** The route's data and code could use up the gas the caller
  needs for its default. A cap on the caller's own call bounds all of it and is visible to
  builders in simulation, so the request carries no separate gas field.
- **Matching events.** `JITRoutedV1` and `JITDefaultV1` share the request fields, so routed and
  default outcomes compare directly. `JITRoutedV1` also names the caller, setter and executor.
- **The floor is the caller's.** The settler cannot know what the default would have paid. A
  caller that wants that floor measures it (flow B, or flow C's callback). The callback can
  raise `req.amountOutMin` but not lower it, so no argument is silently ignored.
- **One `swap`, optional callback.** Without the callback, `swap` works for callers that can only
  make generic calls and catch a revert. With it, callers that can add a callback set their floor
  in the transaction. One entry point gives builders one call to trace. Every failure reverts,
  as a DEX swap does.
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
