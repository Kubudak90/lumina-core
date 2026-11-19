// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Ported review PoCs (review/poc/core/ExecutorPoC.t.sol, CORE-01/03/07 + R2-3). The previous commit
// ran them unchanged against the original Executor, where every attack succeeded. Each test below
// keeps the PoC's name and scenario and asserts that the attack is now blocked.
//
// Not ported: `test_uiPoolDataProvider_addressOne_aggregatorReverts` (CORE-08, UiPoolDataProvider
// wiring). It does not involve the Executor and is out of scope for S4a.

import 'forge-std/Test.sol';
import {Executor} from '../../src/contracts/extensions/v3-config-engine/Executor.sol';
import {Victim, GrabAdminPayload, NoopPayload, StorageRewritePayload, LayoutAwareRewritePayload, NaivePayloadWithStorage, CounterPayload, RevertingPayload, Create2Deployer} from './mocks/ExecutorMocks.sol';

contract ExecutorPoC is Test {
  Executor ex;

  function setUp() public {
    ex = new Executor(address(this), 2 days);
  }

  /// CORE-01: `emergencyExecute` was on by default and skipped the timelock.
  function test_emergencyExecute_bypassesTimelock_byDefault() public {
    Victim v = new Victim(address(ex));
    GrabAdminPayload p = new GrabAdminPayload(address(v), address(0xBEEF));
    assertFalse(ex.emergencyEnabled());
    vm.expectRevert(Executor.EmergencyDisabled.selector);
    ex.emergencyExecute(address(p)); // same block, no queue
    assertEq(v.admin(), address(ex));
  }

  /// CORE-03: a queued payload zeroed the delay, re-enabled the emergency path and replaced the owner.
  function test_disableEmergency_isNotPermanent_and_delayCanBeZeroed() public {
    ex.disableEmergency();
    assertFalse(ex.emergencyEnabled());

    // the review payload verbatim (written for the original slot layout)
    _assertQueuedPayloadBlocked(address(new StorageRewritePayload(address(0xA11CE))));
    // the same attack against the hardened layout
    _assertQueuedPayloadBlocked(address(new LayoutAwareRewritePayload(address(0xA11CE))));

    assertFalse(ex.emergencyEnabled(), 'emergency re-enabled');
    assertEq(ex.delay(), 2 days, 'delay changed');
    assertEq(ex.owner(), address(this), 'owner replaced');
    address noop = address(new NoopPayload());
    vm.prank(address(0xA11CE));
    vm.expectRevert(Executor.NotOwner.selector);
    ex.emergencyExecute(noop);
  }

  /// CORE-03: a payload with a state variable clobbered `_owner` (slot 0).
  function test_naivePayloadStorage_clobbersOwner() public {
    NaivePayloadWithStorage p = new NaivePayloadWithStorage();
    vm.expectRevert(Executor.EmergencyDisabled.selector);
    ex.emergencyExecute(address(p));

    _assertQueuedPayloadBlocked(address(p));

    // also blocked on the emergency path once it is enabled through the queue
    _enableEmergency();
    vm.expectRevert(Executor.GovernanceStateModified.selector);
    ex.emergencyExecute(address(p));
    assertEq(ex.owner(), address(this));
  }

  /// CORE-03: an empty CREATE2 address could be queued and its code chosen after the delay.
  function test_queueCodelessAddress_thenDeployLater() public {
    Create2Deployer d = new Create2Deployer();
    bytes memory code = type(NoopPayload).creationCode;
    address predicted = vm.computeCreate2Address(bytes32(0), keccak256(code), address(d));
    assertEq(predicted.code.length, 0);
    vm.expectRevert(abi.encodeWithSelector(Executor.InvalidTarget.selector, predicted));
    ex.queueTransaction(predicted, ''); // nothing to review -> rejected
    assertEq(ex.queuedCount(), 0);
  }

  /// CORE-03: executing a codeless target silently succeeded.
  function test_execute_codelessTarget_silentSuccess() public {
    vm.expectRevert(abi.encodeWithSelector(Executor.InvalidTarget.selector, address(0xC0FFEE)));
    ex.queueTransaction(address(0xC0FFEE), '');
  }

  /// CORE-07: the revert reason came back as a 100-byte ABI blob instead of '99'.
  function test_revertReason_isMangled() public {
    RevertingPayload p = new RevertingPayload();
    (, uint256 eta) = ex.queueTransaction(address(p), '');
    vm.warp(eta);
    try ex.execute(address(p), '', eta) {
      fail();
    } catch Error(string memory reason) {
      assertEq(reason, '99');
    }
    assertTrue(ex.isQueued(ex.getTransactionHash(address(p), '', eta)), 'entry kept on failure');
  }

  /// CORE-07: the owner could shorten the delay instantly.
  function test_setDelay_notTimelocked() public {
    vm.expectRevert(Executor.NotSelf.selector);
    ex.setDelay(1 days);
    assertEq(ex.delay(), 2 days);
  }

  /// R2-3: a legitimate-looking stateful payload (`executions++`) overwrote the owner.
  function test_queuedStatefulPayload_clobbersOwner() public {
    CounterPayload p = new CounterPayload();
    _assertQueuedPayloadBlocked(address(p));
    assertEq(ex.owner(), address(this));
  }

  /// CORE-03: the code at the queued address was swapped after the delay and then executed.
  function test_targetCodeSwappedAfterQueue_executesNewCode() public {
    NoopPayload p = new NoopPayload();
    (, uint256 eta) = ex.queueTransaction(address(p), '');
    bytes32 queued = address(p).codehash;
    vm.warp(eta);
    vm.etch(address(p), address(new StorageRewritePayload(address(0xA11CE))).code);
    vm.expectRevert(
      abi.encodeWithSelector(Executor.CodehashMismatch.selector, queued, address(p).codehash)
    );
    ex.execute(address(p), '', eta);
    assertEq(ex.owner(), address(this));
  }

  function _assertQueuedPayloadBlocked(address p) internal {
    (, uint256 eta) = ex.queueTransaction(p, '');
    vm.warp(eta);
    vm.expectRevert(Executor.GovernanceStateModified.selector);
    ex.execute(p, '', eta);
  }

  function _enableEmergency() internal {
    bytes memory data = abi.encodeCall(Executor.setEmergencyEnabled, (true));
    (, uint256 eta) = ex.queueTransaction(address(ex), data);
    vm.warp(eta);
    ex.execute(address(ex), data, eta);
    assertTrue(ex.emergencyEnabled());
  }
}
