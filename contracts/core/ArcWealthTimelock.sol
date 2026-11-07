// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title ARCWEALTH governance timelock
/// @dev OZ TimelockController necessarily inherits payable execution entrypoints and receive().
/// This artifact-only wrapper retains that required upstream ABI; it is not an investor vault.
contract ArcWealthTimelock is TimelockController {
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    error DelayBelowFloor();
    error InvalidTarget();
    error NativeValueUnsupported();

    /// @notice Initializes governance with a minimum delay of at least 600 seconds.
    constructor(uint256 minDelay, address[] memory proposers, address[] memory executors, address admin)
        TimelockController(minDelay, proposers, executors, admin)
    {
        if (minDelay < 600) revert DelayBelowFloor();
    }

    /// @notice Updates the delay by timelocked self-call, retaining the 600-second floor.
    function updateDelay(uint256 newDelay) public override {
        if (newDelay < 600) revert DelayBelowFloor();
        super.updateDelay(newDelay);
    }

    function _execute(address target, uint256 value, bytes calldata data) internal override {
        if (target == address(0)) revert InvalidTarget();
        if (value != 0) revert NativeValueUnsupported();
        super._execute(target, value, data);
    }
}
