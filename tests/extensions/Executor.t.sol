// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import 'forge-std/Test.sol';
import {Executor} from '../../src/contracts/extensions/v3-config-engine/Executor.sol';
import {Victim, GrabAdminPayload, NoopPayload, NaivePayloadWithStorage, CounterPayload, SlotWriterPayload, ForgeQueueEntryPayload, SelfCallSetDelayPayload, SelfCallTransferOwnershipPayload, HijackOwnerPayload, TransientRestorePayload, RevertingPayload, CustomErrorPayload} from './mocks/ExecutorMocks.sol';

contract ExecutorTest is Test {
  // mirrors of Executor events
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
  event CancelTransactionByHash(bytes32 indexed txHash);
  event ObservedOwner(address owner);

  uint256 constant DELAY = 2 days;
  address constant ALICE = address(0xA11CE);
  address constant BOB = address(0xB0B);

  Executor ex;
  uint256 GOV_SLOTS;

  function setUp() public {
    ex = new Executor(address(this), DELAY);
    GOV_SLOTS = ex.GOVERNANCE_SLOT_COUNT();
  }

  // ===========================================================================================
  // helpers
  // ===========================================================================================

  function _queue(address target) internal returns (uint256 eta) {
    (, eta) = ex.queueTransaction(target, '');
  }

  function _queueSelf(bytes memory data) internal returns (uint256 eta) {
    (, eta) = ex.queueTransaction(address(ex), data);
  }

  function _runSelf(bytes memory data) internal {
    uint256 eta = _queueSelf(data);
    vm.warp(eta);
    ex.execute(address(ex), data, eta);
  }

  function _enableEmergency() internal {
    _runSelf(abi.encodeCall(Executor.setEmergencyEnabled, (true)));
    assertTrue(ex.emergencyEnabled());
  }

  function _load(uint256 slot) internal view returns (bytes32) {
    return vm.load(address(ex), bytes32(slot));
  }

  function _queueNoops(uint256 n) internal returns (address[] memory targets, uint256 eta) {
    targets = new address[](n);
    for (uint256 i = 0; i < n; i++) {
      targets[i] = address(new NoopPayload());
      eta = _queue(targets[i]);
    }
  }

  // ===========================================================================================
  // construction and storage layout
  // ===========================================================================================

  function test_constructor_initialState_emergencyOff() public {
    vm.expectEmit(true, true, true, true);
    emit OwnershipTransferred(address(0), ALICE);
    vm.expectEmit(true, true, true, true);
    emit NewDelay(0, 1 days);
    Executor e = new Executor(ALICE, 1 days);
    assertEq(e.owner(), ALICE);
    assertEq(e.pendingOwner(), address(0));
    assertEq(e.delay(), 1 days);
    assertFalse(e.emergencyEnabled());
    assertEq(e.queuedCount(), 0);
  }

  function test_constructor_rejectsInvalidParams() public {
    vm.expectRevert(abi.encodeWithSelector(Executor.InvalidDelay.selector, 1 days - 1));
    new Executor(ALICE, 1 days - 1);
    vm.expectRevert(abi.encodeWithSelector(Executor.InvalidDelay.selector, 30 days + 1));
    new Executor(ALICE, 30 days + 1);
    vm.expectRevert(Executor.InvalidOwner.selector);
    new Executor(address(0), 1 days);
  }

  /// The guard hashes slots [0, GOVERNANCE_SLOT_COUNT). Pin every variable inside that range.
  function test_storageLayout_isInsideGuardedRange() public {
    assertEq(GOV_SLOTS, 5 + 2 * ex.MAX_QUEUED());
    assertEq(_load(0), bytes32(uint256(uint160(address(this)))), 'slot 0 owner');
    assertEq(_load(2), bytes32(DELAY), 'slot 2 delay');

    _runSelf(abi.encodeCall(Executor.transferOwnership, (ALICE)));
    assertEq(_load(1), bytes32(uint256(uint160(ALICE))), 'slot 1 pendingOwner');
    _enableEmergency();
    assertEq(_load(3), bytes32(uint256(1)), 'slot 3 emergencyEnabled');

    // fill the queue: the last entry must occupy the last two guarded slots
    uint256 max = ex.MAX_QUEUED();
    (address[] memory targets, uint256 eta) = _queueNoops(max);
    assertEq(_load(4), bytes32(max), 'slot 4 queue length');
    assertEq(_load(5), ex.getTransactionHash(targets[0], '', eta), 'slot 5 entry[0].txHash');
    assertEq(_load(6), targets[0].codehash, 'slot 6 entry[0].codehash');
    assertEq(_load(GOV_SLOTS - 2), ex.getTransactionHash(targets[max - 1], '', eta));
    assertEq(_load(GOV_SLOTS - 1), targets[max - 1].codehash);
    assertEq(_load(GOV_SLOTS), bytes32(0), 'nothing stored past the guarded range');
  }

  // ===========================================================================================
  // access control
  // ===========================================================================================

  function test_ownerOnly_entryPoints() public {
    address p = address(new NoopPayload());
    vm.startPrank(ALICE);
    vm.expectRevert(Executor.NotOwner.selector);
    ex.queueTransaction(p, '');
    vm.expectRevert(Executor.NotOwner.selector);
    ex.cancelTransaction(p, '', block.timestamp + DELAY);
    vm.expectRevert(Executor.NotOwner.selector);
    ex.execute(p, '', block.timestamp + DELAY);
    vm.expectRevert(Executor.NotOwner.selector);
    ex.emergencyExecute(p);
    vm.expectRevert(Executor.NotOwner.selector);
    ex.disableEmergency();
    vm.stopPrank();
  }

  /// setDelay / transferOwnership / setEmergencyEnabled: never callable directly, even by the owner.
  function test_selfGovernance_directCallsRevert() public {
    address[2] memory callers = [address(this), ALICE];
    for (uint256 i = 0; i < callers.length; i++) {
      vm.startPrank(callers[i]);
      vm.expectRevert(Executor.NotSelf.selector);
      ex.setDelay(3 days);
      vm.expectRevert(Executor.NotSelf.selector);
      ex.transferOwnership(ALICE);
      vm.expectRevert(Executor.NotSelf.selector);
      ex.setEmergencyEnabled(true);
      vm.stopPrank();
    }
    assertEq(ex.delay(), DELAY);
    assertEq(ex.pendingOwner(), address(0));
    assertFalse(ex.emergencyEnabled());
  }

  // ===========================================================================================
  // queue validation and commitment
  // ===========================================================================================

  function test_queue_emitsAndCommitsToCodehash() public {
    NoopPayload p = new NoopPayload();
    uint256 eta = block.timestamp + DELAY;
    bytes32 txHash = ex.getTransactionHash(address(p), '', eta);
    vm.expectEmit(true, true, true, true, address(ex));
    emit QueueTransaction(txHash, address(p), address(p).codehash, '', eta);
    (bytes32 h, uint256 e) = ex.queueTransaction(address(p), '');
    assertEq(h, txHash);
    assertEq(e, eta);
    assertTrue(ex.isQueued(txHash));
    (bytes32 storedHash, bytes32 storedCodehash) = ex.queuedTransactionAt(0);
    assertEq(storedHash, txHash);
    assertEq(storedCodehash, address(p).codehash);
  }

  function test_queue_rejectsCodelessTarget() public {
    vm.expectRevert(abi.encodeWithSelector(Executor.InvalidTarget.selector, address(0)));
    ex.queueTransaction(address(0), '');
    vm.expectRevert(abi.encodeWithSelector(Executor.InvalidTarget.selector, ALICE));
    ex.queueTransaction(ALICE, '');
  }

  function test_queue_rejectsPayloadCalldata() public {
    address p = address(new NoopPayload());
    vm.expectRevert(Executor.PayloadDataNotEmpty.selector);
    ex.queueTransaction(p, abi.encodeWithSignature('execute()'));
  }

  function test_queue_selfCall_onlyAllowlistedSelectors() public {
    bytes[] memory bad = new bytes[](13);
    bad[0] = '';
    bad[1] = hex'aabbcc';
    bad[2] = abi.encodeCall(Executor.acceptOwnership, ());
    bad[3] = abi.encodeCall(Executor.disableEmergency, ());
    bad[4] = abi.encodeCall(Executor.queueTransaction, (address(ex), ''));
    bad[5] = abi.encodeCall(Executor.execute, (address(ex), '', 0));
    bad[6] = abi.encodeCall(Executor.emergencyExecute, (address(ex)));
    // an allowed selector with a 36-byte body that is not one of the three
    bad[7] = abi.encodeCall(Executor.cancelTransactionByHash, (bytes32(0)));
    // allowed selectors with the wrong length (trailing or missing bytes)
    bad[8] = abi.encodePacked(abi.encodeCall(Executor.setDelay, (3 days)), hex'00');
    bad[9] = abi.encodePacked(Executor.setEmergencyEnabled.selector, bytes31(0));
    bad[10] = abi.encodePacked(Executor.transferOwnership.selector);
    // dirty argument words
    bad[11] = abi.encodePacked(Executor.transferOwnership.selector, uint256(1) << 160);
    bad[12] = abi.encodePacked(Executor.setEmergencyEnabled.selector, uint256(2));
    for (uint256 i = 0; i < bad.length; i++) {
      vm.expectRevert(Executor.InvalidSelfCall.selector);
      ex.queueTransaction(address(ex), bad[i]);
    }
    _queueSelf(abi.encodeCall(Executor.setDelay, (3 days)));
    _queueSelf(abi.encodeCall(Executor.transferOwnership, (ALICE)));
    _queueSelf(abi.encodeCall(Executor.setEmergencyEnabled, (true)));
    assertEq(ex.queuedCount(), 3);
  }

  function test_queue_selfCall_argumentsValidatedAtQueueTime() public {
    vm.expectRevert(abi.encodeWithSelector(Executor.InvalidDelay.selector, 1 days - 1));
    ex.queueTransaction(address(ex), abi.encodeCall(Executor.setDelay, (1 days - 1)));
    vm.expectRevert(abi.encodeWithSelector(Executor.InvalidDelay.selector, 30 days + 1));
    ex.queueTransaction(address(ex), abi.encodeCall(Executor.setDelay, (30 days + 1)));
    vm.expectRevert(Executor.InvalidOwner.selector);
    ex.queueTransaction(address(ex), abi.encodeCall(Executor.transferOwnership, (address(ex))));
    assertEq(ex.queuedCount(), 0);
    // bounds are inclusive
    _queueSelf(abi.encodeCall(Executor.setDelay, (1 days)));
    _queueSelf(abi.encodeCall(Executor.setDelay, (30 days)));
    _queueSelf(abi.encodeCall(Executor.setEmergencyEnabled, (false)));
    _queueSelf(abi.encodeCall(Executor.transferOwnership, (address(0))));
    assertEq(ex.queuedCount(), 4);
  }

  function test_queue_duplicateInSameBlock_reverts() public {
    address p = address(new NoopPayload());
    uint256 eta = _queue(p);
    vm.expectRevert(
      abi.encodeWithSelector(Executor.AlreadyQueued.selector, ex.getTransactionHash(p, '', eta))
    );
    ex.queueTransaction(p, '');
  }

  function test_queue_boundedAndCancelFreesSlot() public {
    uint256 max = ex.MAX_QUEUED();
    (address[] memory targets, uint256 eta) = _queueNoops(max);
    address extra = address(new NoopPayload());
    vm.expectRevert(Executor.QueueFull.selector);
    ex.queueTransaction(extra, '');
    ex.cancelTransaction(targets[3], '', eta);
    _queue(extra);
    assertEq(ex.queuedCount(), max);
  }

  function test_cancelByHash_emitsAndRemoves() public {
    (address[] memory targets, uint256 eta) = _queueNoops(3);
    bytes32 txHash = ex.getTransactionHash(targets[1], '', eta);
    vm.expectEmit(true, true, true, true, address(ex));
    emit CancelTransactionByHash(txHash);
    ex.cancelTransactionByHash(txHash);
    assertFalse(ex.isQueued(txHash));
    assertEq(ex.queuedCount(), 2);
    vm.warp(eta);
    vm.expectRevert(abi.encodeWithSelector(Executor.NotQueued.selector, txHash));
    ex.execute(targets[1], '', eta);
    vm.expectRevert(abi.encodeWithSelector(Executor.NotQueued.selector, txHash));
    ex.cancelTransactionByHash(txHash);
    bytes32 other = ex.getTransactionHash(targets[0], '', eta);
    vm.prank(ALICE);
    vm.expectRevert(Executor.NotOwner.selector);
    ex.cancelTransactionByHash(other);
    assertTrue(ex.isQueued(other));
  }

  /// A full queue of expired entries is freed knowing only the hashes from `queuedTransactionAt`.
  function test_cancelByHash_freesFullQueueOfExpiredEntries() public {
    uint256 max = ex.MAX_QUEUED();
    (address[] memory targets, uint256 eta) = _queueNoops(max);
    vm.warp(eta + ex.GRACE_PERIOD() + 1);
    vm.expectRevert(abi.encodeWithSelector(Executor.Expired.selector, eta));
    ex.execute(targets[0], '', eta);
    address fresh = address(new NoopPayload());
    vm.expectRevert(Executor.QueueFull.selector);
    ex.queueTransaction(fresh, '');
    while (ex.queuedCount() > 0) {
      (bytes32 txHash, ) = ex.queuedTransactionAt(0);
      ex.cancelTransactionByHash(txHash);
    }
    _queue(fresh);
    assertEq(ex.queuedCount(), 1);
  }

  // ===========================================================================================
  // codehash re-check and EIP-7702 delegation designators
  // ===========================================================================================

  function _designator(address delegate) internal pure returns (bytes memory) {
    return abi.encodePacked(hex'ef0100', delegate);
  }

  function test_queue_rejectsDelegationDesignator() public {
    address eoa = makeAddr('delegated-eoa');
    // delegate to an address with no code yet: code could be deployed there after the delay
    vm.etch(eoa, _designator(address(0xDE1E6A7E)));
    assertEq(eoa.code.length, 23);
    vm.expectRevert(abi.encodeWithSelector(Executor.DelegatedTarget.selector, eoa));
    ex.queueTransaction(eoa, '');
    // also when delegating to an existing contract
    vm.etch(eoa, _designator(address(new NoopPayload())));
    vm.expectRevert(abi.encodeWithSelector(Executor.DelegatedTarget.selector, eoa));
    ex.queueTransaction(eoa, '');
    assertEq(ex.queuedCount(), 0);
  }

  function test_emergency_rejectsDelegationDesignator() public {
    _enableEmergency();
    address eoa = makeAddr('delegated-eoa');
    vm.etch(eoa, _designator(address(new NoopPayload())));
    vm.expectRevert(abi.encodeWithSelector(Executor.DelegatedTarget.selector, eoa));
    ex.emergencyExecute(eoa);
  }

  /// A queued contract target that later becomes a delegated account cannot be executed.
  function test_execute_rejectsTargetThatBecameDelegationDesignator() public {
    NoopPayload p = new NoopPayload();
    uint256 eta = _queue(address(p));
    vm.etch(address(p), _designator(address(new CounterPayload())));
    vm.warp(eta);
    vm.expectRevert(abi.encodeWithSelector(Executor.DelegatedTarget.selector, address(p)));
    ex.execute(address(p), '', eta);
  }

  /// The check is on the 0xef0100 prefix, not on the code size alone. (Other 0xef01 versions cannot
  /// be etched: revm rejects them as unsupported EIP-7702 bytecode.)
  function test_queue_accepts23ByteNonDesignatorCode() public {
    address c = makeAddr('23-byte-contract');
    vm.etch(c, abi.encodePacked(hex'00', bytes22(0)));
    assertEq(c.code.length, 23);
    ex.queueTransaction(c, '');
    assertEq(ex.queuedCount(), 1);
  }

  function test_execute_revertsWhenTargetCodeChanged() public {
    NoopPayload p = new NoopPayload();
    uint256 eta = _queue(address(p));
    bytes32 queued = address(p).codehash;
    vm.etch(address(p), address(new CounterPayload()).code);
    vm.warp(eta);
    vm.expectRevert(
      abi.encodeWithSelector(Executor.CodehashMismatch.selector, queued, address(p).codehash)
    );
    ex.execute(address(p), '', eta);
  }

  /// Execute-time half of the review PoC `test_execute_codelessTarget_silentSuccess`.
  function test_execute_revertsWhenTargetCodeRemoved() public {
    NoopPayload p = new NoopPayload();
    uint256 eta = _queue(address(p));
    bytes32 queued = address(p).codehash;
    vm.etch(address(p), '');
    vm.warp(eta);
    vm.expectRevert(
      abi.encodeWithSelector(Executor.CodehashMismatch.selector, queued, address(p).codehash)
    );
    ex.execute(address(p), '', eta);
  }

  // ===========================================================================================
  // execution, cancel and races
  // ===========================================================================================

  function test_execute_payloadRunsWithExecutorAuthority() public {
    Victim v = new Victim(address(ex));
    GrabAdminPayload p = new GrabAdminPayload(address(v), BOB);
    uint256 eta = _queue(address(p));
    bytes32 txHash = ex.getTransactionHash(address(p), '', eta);
    vm.warp(eta);
    vm.expectEmit(true, true, true, true, address(ex));
    emit ExecuteTransaction(txHash, address(p), address(p).codehash, '', eta);
    ex.execute(address(p), '', eta);
    assertEq(v.admin(), BOB);
    assertFalse(ex.isQueued(txHash));
    assertEq(ex.queuedCount(), 0);
  }

  function test_execute_beforeEta_reverts() public {
    address p = address(new NoopPayload());
    uint256 eta = _queue(p);
    vm.warp(eta - 1);
    vm.expectRevert(abi.encodeWithSelector(Executor.NotReady.selector, eta));
    ex.execute(p, '', eta);
  }

  function test_execute_gracePeriodBoundary() public {
    address p1 = address(new NoopPayload());
    address p2 = address(new NoopPayload());
    uint256 eta = _queue(p1);
    _queue(p2);
    vm.warp(eta + ex.GRACE_PERIOD());
    ex.execute(p1, '', eta); // last valid second
    vm.warp(eta + ex.GRACE_PERIOD() + 1);
    vm.expectRevert(abi.encodeWithSelector(Executor.Expired.selector, eta));
    ex.execute(p2, '', eta);
    // an expired entry can still be cancelled to free its slot
    ex.cancelTransaction(p2, '', eta);
    assertEq(ex.queuedCount(), 0);
  }

  function test_execute_cancelledEntry_reverts() public {
    address p = address(new NoopPayload());
    uint256 eta = _queue(p);
    bytes32 txHash = ex.getTransactionHash(p, '', eta);
    vm.expectEmit(true, true, true, true, address(ex));
    emit CancelTransaction(txHash, p, '', eta);
    ex.cancelTransaction(p, '', eta);
    vm.warp(eta);
    vm.expectRevert(abi.encodeWithSelector(Executor.NotQueued.selector, txHash));
    ex.execute(p, '', eta);
  }

  function test_execute_twice_reverts() public {
    address p = address(new NoopPayload());
    uint256 eta = _queue(p);
    vm.warp(eta);
    ex.execute(p, '', eta);
    bytes32 txHash = ex.getTransactionHash(p, '', eta);
    vm.expectRevert(abi.encodeWithSelector(Executor.NotQueued.selector, txHash));
    ex.execute(p, '', eta);
    vm.expectRevert(abi.encodeWithSelector(Executor.NotQueued.selector, txHash));
    ex.cancelTransaction(p, '', eta);
  }

  function test_execute_wrongEtaOrData_reverts() public {
    address p = address(new NoopPayload());
    uint256 eta = _queue(p);
    vm.warp(eta + 1);
    vm.expectRevert(
      abi.encodeWithSelector(Executor.NotQueued.selector, ex.getTransactionHash(p, '', eta + 1))
    );
    ex.execute(p, '', eta + 1);
    vm.expectRevert(
      abi.encodeWithSelector(Executor.NotQueued.selector, ex.getTransactionHash(p, hex'00', eta))
    );
    ex.execute(p, hex'00', eta);
  }

  function test_execute_onlyRemovesExecutedEntry() public {
    (address[] memory targets, uint256 eta) = _queueNoops(4);
    vm.warp(eta);
    ex.execute(targets[1], '', eta);
    assertEq(ex.queuedCount(), 3);
    assertFalse(ex.isQueued(ex.getTransactionHash(targets[1], '', eta)));
    assertTrue(ex.isQueued(ex.getTransactionHash(targets[0], '', eta)));
    assertTrue(ex.isQueued(ex.getTransactionHash(targets[2], '', eta)));
    assertTrue(ex.isQueued(ex.getTransactionHash(targets[3], '', eta)));
    ex.execute(targets[3], '', eta);
    ex.execute(targets[0], '', eta);
    ex.execute(targets[2], '', eta);
    assertEq(ex.queuedCount(), 0);
  }

  // ===========================================================================================
  // revert data bubbling (CORE-07)
  // ===========================================================================================

  function test_execute_bubblesRevertString() public {
    address p = address(new RevertingPayload());
    uint256 eta = _queue(p);
    vm.warp(eta);
    vm.expectRevert(bytes('99'));
    ex.execute(p, '', eta);
    assertTrue(ex.isQueued(ex.getTransactionHash(p, '', eta)), 'failed execution keeps entry');
  }

  function test_execute_bubblesCustomError() public {
    address p = address(new CustomErrorPayload());
    uint256 eta = _queue(p);
    vm.warp(eta);
    vm.expectRevert(abi.encodeWithSelector(CustomErrorPayload.PayloadFailed.selector, 42));
    ex.execute(p, '', eta);
  }

  /// Allowed self-calls are validated at queue time, so force the inner call to fail with a mock.
  function test_selfCall_bubblesRevert() public {
    bytes memory data = abi.encodeCall(Executor.setDelay, (3 days));
    uint256 eta = _queueSelf(data);
    vm.warp(eta);
    bytes memory reason = abi.encodeWithSelector(Executor.InvalidDelay.selector, 12345);
    vm.mockCallRevert(address(ex), data, reason);
    vm.expectRevert(reason);
    ex.execute(address(ex), data, eta);
    assertEq(ex.delay(), DELAY);
  }

  /// The self-governance functions keep their own checks (exercised as the Executor itself).
  function test_selfGovernance_functionLevelChecks() public {
    vm.startPrank(address(ex));
    vm.expectRevert(abi.encodeWithSelector(Executor.InvalidDelay.selector, 31 days));
    ex.setDelay(31 days);
    vm.expectRevert(Executor.InvalidOwner.selector);
    ex.transferOwnership(address(ex));
    vm.stopPrank();
  }

  // ===========================================================================================
  // self-governance through the queue
  // ===========================================================================================

  function test_setDelay_throughQueue_succeedsAndEmits() public {
    bytes memory data = abi.encodeCall(Executor.setDelay, (3 days));
    uint256 eta = _queueSelf(data);
    bytes32 txHash = ex.getTransactionHash(address(ex), data, eta);
    vm.warp(eta);
    vm.expectEmit(true, true, true, true, address(ex));
    emit NewDelay(DELAY, 3 days);
    vm.expectEmit(true, true, true, true, address(ex));
    emit ExecuteTransaction(txHash, address(ex), address(ex).codehash, data, eta);
    ex.execute(address(ex), data, eta);
    assertEq(ex.delay(), 3 days);
    // the new delay applies to later queue entries
    (, uint256 nextEta) = ex.queueTransaction(address(new NoopPayload()), '');
    assertEq(nextEta, block.timestamp + 3 days);
  }

  function test_setDelay_cannotBeInstant() public {
    bytes memory data = abi.encodeCall(Executor.setDelay, (1 days));
    uint256 eta = _queueSelf(data);
    vm.expectRevert(abi.encodeWithSelector(Executor.NotReady.selector, eta));
    ex.execute(address(ex), data, eta);
    assertEq(ex.delay(), DELAY);
  }

  function test_ownership_twoStep_throughQueue() public {
    bytes memory data = abi.encodeCall(Executor.transferOwnership, (ALICE));
    uint256 eta = _queueSelf(data);
    vm.warp(eta);
    vm.expectEmit(true, true, true, true, address(ex));
    emit OwnershipTransferStarted(address(this), ALICE);
    ex.execute(address(ex), data, eta);
    assertEq(ex.pendingOwner(), ALICE);
    assertEq(ex.owner(), address(this), 'owner unchanged until accepted');

    // only the pending owner can accept
    vm.prank(BOB);
    vm.expectRevert(Executor.NotPendingOwner.selector);
    ex.acceptOwnership();
    vm.expectRevert(Executor.NotPendingOwner.selector);
    ex.acceptOwnership();

    vm.expectEmit(true, true, true, true, address(ex));
    emit OwnershipTransferred(address(this), ALICE);
    vm.prank(ALICE);
    ex.acceptOwnership();
    assertEq(ex.owner(), ALICE);
    assertEq(ex.pendingOwner(), address(0));

    // old owner is out, new owner is in
    address p = address(new NoopPayload());
    vm.expectRevert(Executor.NotOwner.selector);
    ex.queueTransaction(p, '');
    vm.prank(ALICE);
    ex.queueTransaction(p, '');
    // acceptance cannot be replayed
    vm.prank(ALICE);
    vm.expectRevert(Executor.NotPendingOwner.selector);
    ex.acceptOwnership();
  }

  function test_ownership_pendingCanBeReplacedOrCleared() public {
    _runSelf(abi.encodeCall(Executor.transferOwnership, (ALICE)));
    _runSelf(abi.encodeCall(Executor.transferOwnership, (address(0))));
    assertEq(ex.pendingOwner(), address(0));
    vm.prank(ALICE);
    vm.expectRevert(Executor.NotPendingOwner.selector);
    ex.acceptOwnership();
    assertEq(ex.owner(), address(this));
  }

  function test_ownership_selfAsOwner_rejected() public {
    bytes memory data = abi.encodeCall(Executor.transferOwnership, (address(ex)));
    vm.expectRevert(Executor.InvalidOwner.selector);
    ex.queueTransaction(address(ex), data);
  }

  function test_emergency_enabledOnlyThroughQueue_thenOwnerCanDisable() public {
    Victim v = new Victim(address(ex));
    GrabAdminPayload p = new GrabAdminPayload(address(v), BOB);
    vm.expectRevert(Executor.EmergencyDisabled.selector);
    ex.emergencyExecute(address(p));

    bytes memory data = abi.encodeCall(Executor.setEmergencyEnabled, (true));
    uint256 eta = _queueSelf(data);
    vm.warp(eta);
    vm.expectEmit(true, true, true, true, address(ex));
    emit EmergencyStatusChanged(true);
    ex.execute(address(ex), data, eta);
    assertTrue(ex.emergencyEnabled());

    vm.expectEmit(true, true, true, true, address(ex));
    emit EmergencyExecuted(address(p), address(p).codehash);
    ex.emergencyExecute(address(p));
    assertEq(v.admin(), BOB);

    vm.expectEmit(true, true, true, true, address(ex));
    emit EmergencyStatusChanged(false);
    ex.disableEmergency();
    assertFalse(ex.emergencyEnabled());
    vm.expectRevert(Executor.EmergencyDisabled.selector);
    ex.emergencyExecute(address(p));
  }

  function test_emergency_rejectsSelfAndCodelessTargets() public {
    _enableEmergency();
    vm.expectRevert(abi.encodeWithSelector(Executor.InvalidTarget.selector, address(ex)));
    ex.emergencyExecute(address(ex));
    vm.expectRevert(abi.encodeWithSelector(Executor.InvalidTarget.selector, ALICE));
    ex.emergencyExecute(ALICE);
  }

  // ===========================================================================================
  // storage-integrity guard (R2-3)
  // ===========================================================================================

  function _assertQueuedBlocked(address p) internal {
    uint256 eta = _queue(p);
    vm.warp(eta);
    vm.expectRevert(Executor.GovernanceStateModified.selector);
    ex.execute(p, '', eta);
    assertTrue(ex.isQueued(ex.getTransactionHash(p, '', eta)), 'revert keeps the entry');
  }

  function test_guard_statefulPayloadWritingSlot0_reverts() public {
    _assertQueuedBlocked(address(new CounterPayload()));
    _assertQueuedBlocked(address(new NaivePayloadWithStorage()));
    assertEq(ex.owner(), address(this));

    _enableEmergency();
    address counter = address(new CounterPayload());
    vm.expectRevert(Executor.GovernanceStateModified.selector);
    ex.emergencyExecute(counter);
    assertEq(ex.owner(), address(this));
  }

  function test_guard_ownerPendingDelayFlagLength_revert() public {
    bytes32[5] memory values = [
      bytes32(uint256(uint160(ALICE))), // owner
      bytes32(uint256(uint160(ALICE))), // pending owner
      bytes32(0), // delay = 0
      bytes32(uint256(1)), // emergency flag on
      bytes32(uint256(0)) // queue length (2 other entries queued) -> 0
    ];
    _queueNoops(2);
    for (uint256 slot = 0; slot < values.length; slot++) {
      _assertQueuedBlocked(address(new SlotWriterPayload(slot, values[slot])));
    }
    // a write to an unused high byte of the owner slot is caught too
    _assertQueuedBlocked(address(new SlotWriterPayload(0, _load(0) | bytes32(uint256(1) << 255))));
    assertEq(ex.owner(), address(this));
    assertEq(ex.pendingOwner(), address(0));
    assertEq(ex.delay(), DELAY);
    assertFalse(ex.emergencyEnabled());
  }

  function test_guard_delayAndFlagWrites_onEmergencyPath_revert() public {
    _enableEmergency();
    address zeroDelay = address(new SlotWriterPayload(2, bytes32(0)));
    address flagOff = address(new SlotWriterPayload(3, bytes32(0)));
    vm.expectRevert(Executor.GovernanceStateModified.selector);
    ex.emergencyExecute(zeroDelay);
    vm.expectRevert(Executor.GovernanceStateModified.selector);
    ex.emergencyExecute(flagOff);
    assertEq(ex.delay(), DELAY);
    assertTrue(ex.emergencyEnabled());
  }

  function test_guard_writeOtherQueueEntry_reverts() public {
    (address[] memory others, uint256 otherEta) = _queueNoops(3);
    bytes32 victimHash = ex.getTransactionHash(others[1], '', otherEta);
    // entry[1] sits at slots 7 (txHash) and 8 (codehash); the payload is queued last, so removing
    // it before the snapshot does not move entry[1]
    _assertQueuedBlocked(address(new SlotWriterPayload(7, bytes32(0)))); // delete entry[1]
    _assertQueuedBlocked(address(new SlotWriterPayload(7, keccak256('retarget')))); // swap action
    _assertQueuedBlocked(address(new SlotWriterPayload(8, keccak256('other code')))); // re-commit code
    assertTrue(ex.isQueued(victimHash));
    (bytes32 h, bytes32 c) = ex.queuedTransactionAt(1);
    assertEq(h, victimHash);
    assertEq(c, others[1].codehash);
  }

  function test_guard_forgedQueueEntry_reverts() public {
    // forge an instantly-executable setDelay(1 days) entry with an eta in the past
    bytes memory data = abi.encodeCall(Executor.setDelay, (1 days));
    bytes32 forged = ex.getTransactionHash(address(ex), data, block.timestamp);
    ForgeQueueEntryPayload p = new ForgeQueueEntryPayload(0, forged, address(ex).codehash);
    _assertQueuedBlocked(address(p));
    assertFalse(ex.isQueued(forged));
  }

  function test_guard_writeInactiveQueueSlot_reverts() public {
    _assertQueuedBlocked(address(new SlotWriterPayload(GOV_SLOTS - 1, keccak256('dormant'))));
    _assertQueuedBlocked(address(new SlotWriterPayload(GOV_SLOTS - 2, keccak256('dormant'))));
  }

  /// Governance functions called from inside a payload are rejected; queue them as self-calls.
  function test_guard_selfGovernanceFromInsidePayload_reverts() public {
    _assertQueuedBlocked(address(new SelfCallSetDelayPayload(3 days)));
    _assertQueuedBlocked(address(new SelfCallTransferOwnershipPayload(ALICE)));
    assertEq(ex.delay(), DELAY);
    assertEq(ex.pendingOwner(), address(0));
  }

  function test_guard_hijackOwnerToRunOtherEntry_reverts() public {
    Victim v = new Victim(address(ex));
    address other = address(new GrabAdminPayload(address(v), BOB));
    uint256 otherEta = _queue(other);
    HijackOwnerPayload p = new HijackOwnerPayload(address(this), other, otherEta);
    _assertQueuedBlocked(address(p));
    assertEq(v.admin(), address(ex));
    assertTrue(ex.isQueued(ex.getTransactionHash(other, '', otherEta)));
  }

  /// The guard compares the state before and after the call: a change that is live during the
  /// call (the payload reads owner() == 0xdead back through the Executor) but undone before it
  /// returns passes. Payload review must reject payloads that call back into the Executor.
  function test_guard_restoredWithinCall_passes() public {
    address p = address(new TransientRestorePayload());
    uint256 eta = _queue(p);
    vm.warp(eta);
    vm.expectEmit(true, true, true, true, address(ex));
    emit ObservedOwner(address(0xdead));
    ex.execute(p, '', eta);
    assertEq(ex.owner(), address(this));
  }

  function test_guard_nonGovernanceSlotWrite_allowed() public {
    uint256 slot = GOV_SLOTS; // first slot past the guarded range: never read by the Executor
    address p = address(new SlotWriterPayload(slot, keccak256('scratch')));
    uint256 eta = _queue(p);
    vm.warp(eta);
    ex.execute(p, '', eta);
    assertEq(_load(slot), keccak256('scratch'));
    assertEq(ex.owner(), address(this));
    assertEq(ex.queuedCount(), 0);
  }

  /// Any change to any guarded slot through the emergency path reverts.
  function testFuzz_guard_emergencyPath_anyGuardedSlot(uint256 slotSeed, bytes32 value) public {
    _enableEmergency();
    _queueNoops(3);
    uint256 slot = bound(slotSeed, 0, GOV_SLOTS - 1);
    vm.assume(_load(slot) != value);
    address p = address(new SlotWriterPayload(slot, value));
    vm.expectRevert(Executor.GovernanceStateModified.selector);
    ex.emergencyExecute(p);
  }

  /// Any change to any guarded slot through a queued payload reverts. The payload is queued last;
  /// its own entry is removed before the snapshot, which moves the length and clears its slots.
  function testFuzz_guard_queuedPath_anyGuardedSlot(
    uint256 slotSeed,
    bytes32 value,
    uint8 othersSeed
  ) public {
    uint256 others = bound(othersSeed, 0, ex.MAX_QUEUED() - 1);
    _queueNoops(others);
    uint256 slot = bound(slotSeed, 0, GOV_SLOTS - 1);
    bytes32 atSnapshot;
    if (slot == 4) atSnapshot = bytes32(others);
    else if (slot == 5 + 2 * others || slot == 6 + 2 * others) atSnapshot = bytes32(0);
    else atSnapshot = _load(slot);
    vm.assume(value != atSnapshot);
    _assertQueuedBlocked(address(new SlotWriterPayload(slot, value)));
  }

  function testFuzz_guard_outsideGuardedRange_allowed(uint256 slot, bytes32 value) public {
    vm.assume(slot >= GOV_SLOTS);
    _enableEmergency();
    ex.emergencyExecute(address(new SlotWriterPayload(slot, value)));
    assertEq(_load(slot), value);
    assertEq(ex.owner(), address(this));
    assertEq(ex.delay(), DELAY);
  }
}
