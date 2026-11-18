// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice The subset of `PrioUpdateRegistry` (vendored under `vendor/priority-update-registry`)
///         that `JITSettler` calls; the signatures are the real ones. Updaters are scoped to the
///         TARGET (`isUpdater[target][updater]`), so only `JITSettler` can register its updater,
///         which it does once, in its constructor.
interface IPrioUpdateRegistry {
    /// @dev Reverts `StaleUpdate` when the stored timestamp is outside `[min, max]`. A lane never
    ///      written has timestamp 0. Slot 0's top 40 bits (timestamp 32 | count 8) are the
    ///      registry's; `slots[0]` comes back as the low 216 bits.
    function getState(uint256 laneIndex, uint32 minTimestamp, uint32 maxTimestamp)
        external
        view
        returns (uint32 updateTimestamp, uint256[] memory slots);

    function addUpdater(address updater) external;

    /// @dev How lanes are posted (not called by `JITSettler`): the updater signs each
    ///      EIP-712 `UpdateState(target, laneIndex, updateTimestamp, slots)`; anyone relays.
    struct SignedUpdate {
        address target;
        address signer;
        uint256 laneIndex;
        uint32 updateTimestamp;
        uint256[] slots;
        bytes signature;
    }

    function batchUpdateStateWithSignature(SignedUpdate[] calldata updates) external;

    function isUpdater(address target, address updater) external view returns (bool);
}
