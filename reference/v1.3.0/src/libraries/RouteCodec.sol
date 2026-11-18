// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice The route encoding, version 5 (RFC "Lane key and encoding"): one big-endian bit stream
///         over the lane's words, fixed-width fields, no ABI. Bit 0 is the MSB of `slots[0]`;
///         the stream starts at bit 40 because PUR keeps the top 40 bits of slot 0 (timestamp 32,
///         slot count 8) and returns `slots[0]` with them zeroed. 1 word holds 216 bits, 2 hold
///         472, 3 hold 728.
///
///         Header (156 bits, fits word 0):
///           version 8 | hopCount 4 | routedEstOut 40 | simOriginalOut 40 | postingChargeOut 40 |
///           routedEstGas 24
///         Amounts are 40-bit floats (`decodeAmount`): mantissa 32 | exponent 8, value =
///         mantissa << exponent. jit-router rounds `simOriginalOut` up (the floor only tightens),
///         `postingChargeOut` down (the treasury only gets less) and `routedEstOut` down (the
///         estimate never overstates). `routedEstOut` feeds `peek`, the no-route check (0 = no route)
///         and `Settled`; `routedEstGas` feeds `peek`, the `maxGas` refusal and `Settled`. Neither
///         feeds the floor or the treasury's share. Nothing price-like is posted.
///         No `feeBps` field: `JITSettler`'s `FEE_BPS` is a constructor-fixed immutable (0 in v1).
///         No `Router` field: `JITSettler`'s `Router` is immutable and PUR lanes are per target.
///         No fingerprint: a request reads whatever route its lane holds this block.
///         The hops follow the header, in the `Router`'s own format.
///         The writer is jit-router (`crates/jit-router`), header included; the fixtures in
///         `test/fixtures/routes_v5.json` pin the writer.
library RouteCodec {
    /// @dev The format version in the header's first 8 bits; any other value is "no route".
    uint8 internal constant VERSION = 5;

    uint256 internal constant STREAM_START = 40;
    uint256 internal constant HEADER_BITS = 156;
    uint256 internal constant HOPS_START = STREAM_START + HEADER_BITS; // 196
    /// @dev Words the header needs: ceil(196 / 256).
    uint256 internal constant HEADER_WORDS = 1;

    /// @dev A 40-bit float: mantissa 32 | exponent 8. Exponents above 224 would overflow 256 bits
    ///      and make the header invalid.
    uint256 internal constant AMOUNT_BITS = 40;
    uint256 internal constant MAX_EXPONENT = 224;

    uint256 internal constant TOKEN_INDEX_BITS = 16;
    uint256 internal constant TOKEN_ESCAPE = 0xFFFF;

    uint256 internal constant LANES = 256;

    struct Header {
        uint8 version;
        uint8 hopCount;
        /// @dev Decoded from 40-bit floats to full width.
        /// @dev jit-router's estimate of `routedOut`, net of `postingChargeOut` and `feeOut`.
        ///      0 = no route. Never rewritten after sim 2.
        uint256 routedEstOut;
        /// @dev Builder sim 1: tokenOut `Transfer` logs into `recipient` in the order's tx.
        uint256 simOriginalOut;
        /// @dev postingGas * basefee * outPerEth / 1e18, computed off chain by jit-router: the
        ///      order's own update tx, priced at basefee, in tokenOut.
        uint256 postingChargeOut;
        /// @dev jit-router's estimate of the gas `swap` spends with the route.
        uint24 routedEstGas;
    }

    // ── Lane key ─────────────────────────────────────────────────────────────

    /// @notice RFC: key = keccak(msg.sender, tokenIn, tokenOut, amountIn, minOut, recipient).
    ///         `maxGas` is deliberately not in it: jit-router fits the route under `maxGas`.
    function laneKey(
        address caller,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        address recipient
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(caller, tokenIn, tokenOut, amountIn, minOut, recipient));
    }

    /// @notice Lane = key % 256.
    function laneIndex(bytes32 key) internal pure returns (uint256) {
        return uint256(key) % LANES;
    }

    // ── Bit reader ───────────────────────────────────────────────────────────

    /// @notice `n` bits (1..256) at stream position `p`, as an integer. Reverts (array index)
    ///         past the last word, which in `execute` is a failed route.
    function read(uint256[] memory slots, uint256 p, uint256 n) internal pure returns (uint256) {
        uint256 w = p >> 8;
        uint256 off = p & 255;
        uint256 hi = slots[w] << off;
        if (off + n > 256) hi |= slots[w + 1] >> (256 - off);
        return hi >> (256 - n);
    }

    // ── Amounts ──────────────────────────────────────────────────────────────

    /// @notice A 40-bit float `mantissa 32 | exponent 8` as `mantissa << exponent`, or
    ///         `ok == false` when the exponent exceeds `MAX_EXPONENT`. Exact: the rounding is the
    ///         encoder's (jit-router), with the smallest exponent whose mantissa fits 32 bits, per
    ///         field: `simOriginalOut` up, `routedEstOut` and `postingChargeOut` down.
    function decodeAmount(uint256 raw) internal pure returns (bool ok, uint256 value) {
        uint256 e = raw & 0xFF;
        if (e > MAX_EXPONENT) return (false, 0);
        return (true, (raw >> 8) << e);
    }

    // ── Header ───────────────────────────────────────────────────────────────

    /// @notice Header fields, or `ok == false` when the lane is too short, not this version, or
    ///         an amount's exponent exceeds `MAX_EXPONENT`.
    ///         Never reverts: a lane that does not decode is "no route" (`NoRoute`), not a panic.
    function tryDecodeHeader(uint256[] memory slots)
        internal
        pure
        returns (bool ok, Header memory h)
    {
        if (slots.length < HEADER_WORDS) return (false, h);
        uint256 p = STREAM_START;
        h.version = uint8(read(slots, p, 8));
        p += 8;
        if (h.version != VERSION) return (false, h);
        h.hopCount = uint8(read(slots, p, 4));
        p += 4;
        bool okEst;
        bool okOriginal;
        bool okPosting;
        (okEst, h.routedEstOut) = decodeAmount(read(slots, p, AMOUNT_BITS));
        p += AMOUNT_BITS;
        (okOriginal, h.simOriginalOut) = decodeAmount(read(slots, p, AMOUNT_BITS));
        p += AMOUNT_BITS;
        (okPosting, h.postingChargeOut) = decodeAmount(read(slots, p, AMOUNT_BITS));
        p += AMOUNT_BITS;
        h.routedEstGas = uint24(read(slots, p, 24));
        ok = h.hopCount != 0 && okEst && okOriginal && okPosting;
    }
}
