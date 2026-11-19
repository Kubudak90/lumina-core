// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Executor} from '../../../src/contracts/extensions/v3-config-engine/Executor.sol';

/// @dev Test fixtures for tests/extensions/Executor*.t.sol. Every payload's `execute()` runs via
/// DELEGATECALL in the Executor's storage context; immutables live in code, not storage.

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

/// @dev Uses the Executor's authority on an external contract (the legitimate payload use case).
contract GrabAdminPayload {
  address public immutable VICTIM;
  address public immutable NEW_ADMIN;

  constructor(address victim, address newAdmin) {
    VICTIM = victim;
    NEW_ADMIN = newAdmin;
  }

  function execute() external {
    Victim(VICTIM).setAdmin(NEW_ADMIN);
  }
}

contract NoopPayload {
  function execute() external {}
}

/// @dev Review PoC payload, written for the ORIGINAL layout (0 owner, 1 delay, 3 emergencyDisabled).
contract StorageRewritePayload {
  address immutable NEW_OWNER;

  constructor(address o) {
    NEW_OWNER = o;
  }

  function execute() external {
    assembly {
      sstore(1, 0)
      sstore(3, 0)
    }
    address o = NEW_OWNER;
    assembly {
      sstore(0, o)
    }
  }
}

/// @dev Same intent against the hardened layout: delay = 0, emergency on, owner replaced.
contract LayoutAwareRewritePayload {
  address immutable NEW_OWNER;

  constructor(address o) {
    NEW_OWNER = o;
  }

  function execute() external {
    address o = NEW_OWNER;
    assembly {
      sstore(2, 0) // _delay = 0
      sstore(3, 1) // _emergencyEnabled = true
      sstore(0, o) // _owner = NEW_OWNER
    }
  }
}

/// @dev Careless payload with a state variable: slot 0 collides with the Executor's owner.
contract NaivePayloadWithStorage {
  address public lastCaller;

  function execute() external {
    lastCaller = address(0xdead);
  }
}

/// @dev R2-3 (Codex round 2): a stateful counter payload; `executions` is slot 0 (owner).
contract CounterPayload {
  uint256 public executions;

  function execute() external {
    executions++;
  }
}

/// @dev Writes `VALUE` into raw slot `SLOT` of the Executor.
contract SlotWriterPayload {
  uint256 public immutable SLOT;
  bytes32 public immutable VALUE;

  constructor(uint256 slot, bytes32 value) {
    SLOT = slot;
    VALUE = value;
  }

  function execute() external {
    uint256 s = SLOT;
    bytes32 v = VALUE;
    assembly {
      sstore(s, v)
    }
  }
}

/// @dev Forges a new queue entry by raw writes: entry at index `INDEX`, length = INDEX + 1.
contract ForgeQueueEntryPayload {
  uint256 immutable INDEX;
  bytes32 immutable TX_HASH;
  bytes32 immutable CODEHASH;

  constructor(uint256 index, bytes32 txHash, bytes32 codehash) {
    INDEX = index;
    TX_HASH = txHash;
    CODEHASH = codehash;
  }

  function execute() external {
    uint256 i = INDEX;
    bytes32 h = TX_HASH;
    bytes32 c = CODEHASH;
    assembly {
      sstore(add(5, mul(2, i)), h)
      sstore(add(6, mul(2, i)), c)
      sstore(4, add(i, 1))
    }
  }
}

/// @dev Calls a self-governance function from inside the delegatecall (msg.sender == Executor).
contract SelfCallSetDelayPayload {
  uint256 immutable NEW_DELAY;

  constructor(uint256 newDelay) {
    NEW_DELAY = newDelay;
  }

  function execute() external {
    Executor(address(this)).setDelay(NEW_DELAY);
  }
}

contract SelfCallTransferOwnershipPayload {
  address immutable NEW_OWNER;

  constructor(address newOwner) {
    NEW_OWNER = newOwner;
  }

  function execute() external {
    Executor(address(this)).transferOwnership(NEW_OWNER);
  }
}

/// @dev Makes the Executor its own owner, executes another ready queue entry through the public
/// entry point, then restores the owner. The other entry's removal is a governance change.
contract HijackOwnerPayload {
  address immutable OWNER;
  address immutable OTHER_TARGET;
  uint256 immutable OTHER_ETA;

  constructor(address owner_, address otherTarget, uint256 otherEta) {
    OWNER = owner_;
    OTHER_TARGET = otherTarget;
    OTHER_ETA = otherEta;
  }

  function execute() external {
    assembly {
      sstore(0, address())
    }
    Executor(address(this)).execute(OTHER_TARGET, '', OTHER_ETA);
    address o = OWNER;
    assembly {
      sstore(0, o)
    }
  }
}

/// @dev Changes the owner slot, proves the change is live by reading it back through an external
/// call to the Executor (so the optimizer cannot drop the write), then restores it: no net change.
contract TransientRestorePayload {
  event ObservedOwner(address owner);

  function execute() external {
    address original = Executor(address(this)).owner();
    assembly {
      sstore(0, 0xdead)
    }
    address observed = Executor(address(this)).owner();
    require(observed == address(0xdead), 'intermediate write not visible');
    emit ObservedOwner(observed);
    assembly {
      sstore(0, original)
    }
  }
}

contract RevertingPayload {
  function execute() external pure {
    revert('99'); // Aave-style error code
  }
}

contract CustomErrorPayload {
  error PayloadFailed(uint256 code);

  function execute() external pure {
    revert PayloadFailed(42);
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
