// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title Executor
 * @notice Timelocked governance executor. The owner (a Safe) queues actions; each action can be
 * executed by the owner after `delay` has elapsed and within `GRACE_PERIOD`.
 *
 * Two kinds of action can be queued:
 *  - Payload: `target` is a contract whose `execute()` is DELEGATECALLed in the Executor's context
 *    (Aave config-engine payload model). `data` must be empty. The queue entry commits to
 *    `(target, extcodehash(target), eta)`; execution reverts if the target's code changed.
 *  - Self-governance call: `target == address(this)` and `data` is a call to `setDelay`,
 *    `transferOwnership` or `setEmergencyEnabled`. It is executed with a plain CALL from the
 *    Executor to itself, so no foreign code runs in the Executor's storage context. These three
 *    functions can only be called by the Executor itself, i.e. only through the queue.
 *
 * Storage-integrity guard: a payload runs with full write access to this contract's storage. Every
 * DELEGATECALL (`execute` of a payload and `emergencyExecute`) is wrapped by a guard that hashes
 * every storage slot this contract uses before the call and reverts with `GovernanceStateModified`
 * if any of them differs afterwards. The guarded range covers owner, pending owner, delay, the
 * emergency flag, the queue length and every slot of the bounded queue (active or not). The queue
 * is a fixed-size array (MAX_QUEUED entries) rather than a mapping, so the guarded range is
 * bounded, and the Executor reads no storage outside that range. The pre-call hash lives on the
 * stack of the outer call frame, which the payload cannot read or write; to pass the check the
 * payload would have to leave every guarded slot exactly as it found it (no net change) or find a
 * keccak256 second preimage. Governance changes from inside a payload, whether raw SSTOREs or calls
 * to the self-governance functions, are therefore rejected; they must be queued as their own
 * self-governance action. The entry being executed is removed before the snapshot, so the guard
 * protects every other queue entry.
 *
 * Storage layout (do not reorder or insert variables; `GOVERNANCE_SLOT_COUNT` must cover all of it):
 *   slot 0              _owner
 *   slot 1              _pendingOwner
 *   slot 2              _delay
 *   slot 3              _emergencyEnabled
 *   slot 4              _queueLength
 *   slots 5 .. 5+2N-1   _queue[N] (txHash, codehash), N = MAX_QUEUED
 */
contract Executor {
  struct QueuedTransaction {
    bytes32 txHash;
    bytes32 codehash;
  }

  uint256 public constant MINIMUM_DELAY = 1 days;
  uint256 public constant MAXIMUM_DELAY = 30 days;
  uint256 public constant GRACE_PERIOD = 14 days;
  /// @notice Maximum number of simultaneously queued actions (bounds the integrity guard).
  uint256 public constant MAX_QUEUED = 16;
  /// @notice Number of storage slots (starting at slot 0) hashed by the integrity guard.
  uint256 public constant GOVERNANCE_SLOT_COUNT = 5 + 2 * MAX_QUEUED;

  uint256 private constant NOT_FOUND = type(uint256).max;

  address private _owner; // slot 0
  address private _pendingOwner; // slot 1
  uint256 private _delay; // slot 2
  bool private _emergencyEnabled; // slot 3
  uint256 private _queueLength; // slot 4
  QueuedTransaction[MAX_QUEUED] private _queue; // slots 5 .. 5 + 2 * MAX_QUEUED - 1

  event QueueTransaction(
    bytes32 indexed txHash,
    address indexed target,
    bytes32 codehash,
    bytes data,
    uint256 eta
  );
  event CancelTransaction(bytes32 indexed txHash, address indexed target, bytes data, uint256 eta);
  event ExecuteTransaction(
    bytes32 indexed txHash,
    address indexed target,
    bytes32 codehash,
    bytes data,
    uint256 eta
  );
  event EmergencyExecuted(address indexed target, bytes32 codehash);
  event NewDelay(uint256 oldDelay, uint256 newDelay);
  event EmergencyStatusChanged(bool enabled);
  event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
  event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

  error NotOwner();
  error NotSelf();
  error NotPendingOwner();
  error InvalidOwner();
  error InvalidDelay(uint256 delay);
  error InvalidTarget(address target);
  error InvalidSelfCall();
  error PayloadDataNotEmpty();
  error AlreadyQueued(bytes32 txHash);
  error NotQueued(bytes32 txHash);
  error QueueFull();
  error NotReady(uint256 eta);
  error Expired(uint256 eta);
  error CodehashMismatch(bytes32 queued, bytes32 current);
  error EmergencyDisabled();
  error GovernanceStateModified();

  modifier onlyOwner() {
    if (msg.sender != _owner) revert NotOwner();
    _;
  }

  /// @dev Only the Executor itself, i.e. a queued self-governance action.
  modifier onlySelf() {
    if (msg.sender != address(this)) revert NotSelf();
    _;
  }

  /// @dev The emergency path starts disabled; it can only be enabled through the queue.
  constructor(address initialOwner, uint256 initialDelay) {
    if (initialOwner == address(0) || initialOwner == address(this)) revert InvalidOwner();
    _validateDelay(initialDelay);
    _owner = initialOwner;
    _delay = initialDelay;
    emit OwnershipTransferred(address(0), initialOwner);
    emit NewDelay(0, initialDelay);
  }

  // ---------------------------------------------------------------------------------------------
  // Views
  // ---------------------------------------------------------------------------------------------

  function owner() external view returns (address) {
    return _owner;
  }

  function pendingOwner() external view returns (address) {
    return _pendingOwner;
  }

  function delay() external view returns (uint256) {
    return _delay;
  }

  function emergencyEnabled() external view returns (bool) {
    return _emergencyEnabled;
  }

  function queuedCount() external view returns (uint256) {
    return _queueLength;
  }

  function queuedTransactionAt(
    uint256 index
  ) external view returns (bytes32 txHash, bytes32 codehash) {
    require(index < _queueLength, 'index out of bounds');
    QueuedTransaction storage entry = _queue[index];
    return (entry.txHash, entry.codehash);
  }

  function isQueued(bytes32 txHash) external view returns (bool) {
    return _indexOf(txHash) != NOT_FOUND;
  }

  function getTransactionHash(
    address target,
    bytes calldata data,
    uint256 eta
  ) public pure returns (bytes32) {
    return keccak256(abi.encode(target, data, eta));
  }

  // ---------------------------------------------------------------------------------------------
  // Queue
  // ---------------------------------------------------------------------------------------------

  /**
   * @notice Queue an action with `eta = block.timestamp + delay`.
   * @param target a payload contract (its `execute()` is delegatecalled), or `address(this)` for a
   * self-governance call
   * @param data empty for a payload; the self-governance calldata when `target == address(this)`
   */
  function queueTransaction(
    address target,
    bytes calldata data
  ) external onlyOwner returns (bytes32 txHash, uint256 eta) {
    _validateAction(target, data);
    bytes32 codehash = target.codehash;
    eta = block.timestamp + _delay;
    txHash = getTransactionHash(target, data, eta);
    if (_indexOf(txHash) != NOT_FOUND) revert AlreadyQueued(txHash);
    uint256 length = _queueLength;
    if (length >= MAX_QUEUED) revert QueueFull();

    _queue[length] = QueuedTransaction({txHash: txHash, codehash: codehash});
    _queueLength = length + 1;
    emit QueueTransaction(txHash, target, codehash, data, eta);
  }

  function cancelTransaction(address target, bytes calldata data, uint256 eta) external onlyOwner {
    bytes32 txHash = getTransactionHash(target, data, eta);
    uint256 index = _indexOf(txHash);
    if (index == NOT_FOUND) revert NotQueued(txHash);
    _remove(index);
    emit CancelTransaction(txHash, target, data, eta);
  }

  function execute(address target, bytes calldata data, uint256 eta) external onlyOwner {
    bytes32 txHash = getTransactionHash(target, data, eta);
    uint256 index = _indexOf(txHash);
    if (index == NOT_FOUND) revert NotQueued(txHash);
    if (block.timestamp < eta) revert NotReady(eta);
    if (block.timestamp > eta + GRACE_PERIOD) revert Expired(eta);
    bytes32 codehash = _queue[index].codehash;
    if (target.codehash != codehash) revert CodehashMismatch(codehash, target.codehash);

    // Effects before interactions; the guard snapshot below excludes this entry.
    _remove(index);

    if (target == address(this)) {
      // Self-governance call: only the Executor's own code runs (allow-listed at queue time).
      (bool success, bytes memory returnData) = address(this).call(data);
      if (!success) _bubbleRevert(returnData);
    } else {
      _guardedDelegatecall(target);
    }

    emit ExecuteTransaction(txHash, target, codehash, data, eta);
  }

  // ---------------------------------------------------------------------------------------------
  // Emergency path (disabled until enabled through the queue)
  // ---------------------------------------------------------------------------------------------

  /// @notice Delegatecall `target.execute()` without delay. Only while enabled through the queue.
  function emergencyExecute(address target) external onlyOwner {
    if (!_emergencyEnabled) revert EmergencyDisabled();
    if (target == address(this) || target.code.length == 0) revert InvalidTarget(target);
    bytes32 codehash = target.codehash;
    _guardedDelegatecall(target);
    emit EmergencyExecuted(target, codehash);
  }

  /// @notice The owner can switch the emergency path off at once; switching it on needs the queue.
  function disableEmergency() external onlyOwner {
    if (_emergencyEnabled) {
      _emergencyEnabled = false;
      emit EmergencyStatusChanged(false);
    }
  }

  // ---------------------------------------------------------------------------------------------
  // Self-governance (callable only by the Executor itself, i.e. through the queue)
  // ---------------------------------------------------------------------------------------------

  function setDelay(uint256 newDelay) external onlySelf {
    _validateDelay(newDelay);
    uint256 oldDelay = _delay;
    _delay = newDelay;
    emit NewDelay(oldDelay, newDelay);
  }

  /// @notice Step 1 of 2: propose `newOwner`. `address(0)` clears a pending proposal.
  function transferOwnership(address newOwner) external onlySelf {
    if (newOwner == address(this)) revert InvalidOwner();
    _pendingOwner = newOwner;
    emit OwnershipTransferStarted(_owner, newOwner);
  }

  function setEmergencyEnabled(bool enabled) external onlySelf {
    _emergencyEnabled = enabled;
    emit EmergencyStatusChanged(enabled);
  }

  /// @notice Step 2 of 2: the pending owner accepts.
  function acceptOwnership() external {
    address newOwner = _pendingOwner;
    if (msg.sender != newOwner) revert NotPendingOwner();
    address oldOwner = _owner;
    _owner = newOwner;
    _pendingOwner = address(0);
    emit OwnershipTransferred(oldOwner, newOwner);
  }

  // ---------------------------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------------------------

  function _validateDelay(uint256 newDelay) private pure {
    if (newDelay < MINIMUM_DELAY || newDelay > MAXIMUM_DELAY) revert InvalidDelay(newDelay);
  }

  function _validateAction(address target, bytes calldata data) private view {
    if (target == address(this)) {
      if (data.length < 4) revert InvalidSelfCall();
      bytes4 selector = bytes4(data[:4]);
      if (
        selector != this.setDelay.selector &&
        selector != this.transferOwnership.selector &&
        selector != this.setEmergencyEnabled.selector
      ) revert InvalidSelfCall();
    } else {
      if (data.length != 0) revert PayloadDataNotEmpty();
      if (target.code.length == 0) revert InvalidTarget(target);
    }
  }

  /**
   * @dev Delegatecalls `target.execute()` and reverts if any guarded storage slot changed.
   * `stateBefore` lives on this frame's stack, out of the payload's reach.
   */
  function _guardedDelegatecall(address target) private {
    bytes32 stateBefore = _governanceStateHash();
    (bool success, bytes memory returnData) = target.delegatecall(
      abi.encodeWithSignature('execute()')
    );
    if (!success) _bubbleRevert(returnData);
    if (_governanceStateHash() != stateBefore) revert GovernanceStateModified();
  }

  /// @dev keccak256 over the raw words of slots [0, GOVERNANCE_SLOT_COUNT): every slot this
  /// contract uses, including unused bytes and inactive queue entries.
  function _governanceStateHash() private view returns (bytes32 stateHash) {
    uint256 slotCount = GOVERNANCE_SLOT_COUNT;
    assembly ('memory-safe') {
      let ptr := mload(0x40)
      for {
        let i := 0
      } lt(i, slotCount) {
        i := add(i, 1)
      } {
        mstore(add(ptr, shl(5, i)), sload(i))
      }
      stateHash := keccak256(ptr, shl(5, slotCount))
    }
  }

  function _indexOf(bytes32 txHash) private view returns (uint256) {
    uint256 length = _queueLength;
    for (uint256 i = 0; i < length; i++) {
      if (_queue[i].txHash == txHash) return i;
    }
    return NOT_FOUND;
  }

  function _remove(uint256 index) private {
    uint256 last = _queueLength - 1;
    if (index != last) _queue[index] = _queue[last];
    delete _queue[last];
    _queueLength = last;
  }

  function _bubbleRevert(bytes memory returnData) private pure {
    assembly ('memory-safe') {
      revert(add(returnData, 0x20), mload(returnData))
    }
  }
}
