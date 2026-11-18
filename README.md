# JITSettler

A settler for just-in-time (JIT) routes. A block builder posts a route for a swap in a transaction
right before the swap, in the same block. The aggregator's swap then fills through that route, or
falls back to the aggregator's own default route.

Designed by Flashbots in collaboration with [Gattaca](https://github.com/gattaca-com). The design
starts from Gattaca's proof of concept,
[gattaca-com/jit-settler-poc](https://github.com/gattaca-com/jit-settler-poc).

**Status:** not audited and not deployed. The settler in use today is v1.3.0, kept under
[`reference/v1.3.0`](reference/v1.3.0) (see [History](#history)).

## How it works

`src/JITSettler.sol` has four functions, one route slot and a sandbox.

| Function | Who calls it | What it does |
|---|---|---|
| `setRoute(executor, data)` | builder | Stores the route for this block. The setter is `msg.sender`. A later post overwrites an earlier one. |
| `peek(tokenIn, amountIn, tokenOut, amountOutMin, recipient)` | caller | Returns the setter of the route that is live in this block, or 0. The arguments are not used on chain; they let a builder read the request when it simulates the swap before any route is posted. |
| `swap(tokenIn, amountIn, tokenOut, amountOutMin, recipient)` | caller | Runs the live route and returns `amountOut`. Reverts if there is no route or the output is too low. A revert means "fall back". |
| `reportDefault(tokenIn, amountIn, tokenOut, amountOutMin, recipient, amountOut)` | caller | Emits `JITDefaultV1` when the caller ran its own default route. Changes no state. |

`swap`:

1. Requires a route posted in this block, and marks it used before any external call.
2. Pulls exactly `amountIn` of `tokenIn` from `msg.sender` to the route's executor.
3. Calls the executor with the posted data, through the sandbox.
4. Requires that `recipient`'s `tokenOut` balance grew by at least `amountOutMin`.
5. Emits `JITRoutedV1`.

### What a caller can rely on

- The settler moves only `amountIn` of `tokenIn`, and only from `msg.sender`.
- The recipient gets at least `amountOutMin`, or the swap reverts.
- The executor is called by the sandbox, which holds no approvals. An executor set to a token
  contract cannot spend what callers approved to the settler.
- A route is used once, and only in the block it was posted.
- Nobody can post as someone else: the setter is always `msg.sender` of `setRoute`.

Anyone can post a route. A caller that cares who posted it checks the setter that `peek` returns
against its own list. Whether a route beats the caller's default is the setter's promise, unless
the caller compares the two itself.

### Integrating as a caller

The swap parameters are fixed when the user signs. The caller may branch on what `peek` returns.

```
s = settler.peek(req)                       // setter, or 0
if s != 0 and s in trustedSetters:
    try settler.swap(req) -> out:
        done
    catch:
        // fall through to the default
out = runDefault(defaultRoute)
require(out >= userMinOut)
settler.reportDefault(req, out)            // or emit JITDefaultV1 from the caller's contract
```

With no route posted, this costs one `peek` and never calls `swap`.

A more conservative caller can run both paths as trials, revert them, and take the better one.

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
                  uint256 amountIn, uint256 amountOutMin, uint256 amountOut,
                  address setter, address executor);   // emitted by swap

event JITDefaultV1(address indexed recipient, address indexed tokenIn, address indexed tokenOut,
                   uint256 amountIn, uint256 amountOutMin, uint256 amountOut,
                   address reporter);                   // emitted by reportDefault
```

Anyone can call `reportDefault`, and anyone can emit `JITDefaultV1`. Trust a `JITDefaultV1` log
only if the settler emitted it and `reporter` is a caller you know, or that caller emitted it
itself. Its amounts are the reporter's claim.

## Gas

Measured on a mainnet fork at block 26,410,000: 1 WETH to USDC through the Uniswap V3 5 bps pool,
the same executor code and compiler settings for each settler, each call in its own transaction.
Figures are the gas of the call, without the 21,000 base cost and calldata.

| Measurement | v1.3.0 | Gattaca PoC | JITSettler |
|---|---|---|---|
| Routed swap | 194,930 | 172,379 | 175,726 |
| Caller side, routed: `peek` + `swap` | 224,270 (`swap` only) | 195,766 | 199,508 |
| Caller side, no route: `peek` only | 10,389 (failed `swap`) | 5,368 | 5,778 |
| Post a route | 44,989 | 57,871 | 57,901 |

- Against the PoC, a routed swap costs about 3.3k more for the `JITRoutedV1` event, and `peek`
  about 0.4k more for its arguments.
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
