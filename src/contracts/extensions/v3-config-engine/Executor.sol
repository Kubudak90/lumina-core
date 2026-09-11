// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from '../../dependencies/openzeppelin/contracts/Ownable.sol';

contract Executor is Ownable {
  uint256 public constant MINIMUM_DELAY = 1 days;
  uint256 public constant MAXIMUM_DELAY = 30 days;

  uint256 public delay;
  mapping(bytes32 => bool) public queuedTransactions;

  event NewDelay(uint256 indexed newDelay);
  event QueueTransaction(bytes32 indexed txHash, address indexed target, uint256 eta);
  event ExecuteTransaction(bytes32 indexed txHash, address indexed target, uint256 eta);
  event CancelTransaction(bytes32 indexed txHash, address indexed target, uint256 eta);

  constructor(uint256 _delay) {
    require(_delay >= MINIMUM_DELAY, 'delay < minimum');
    require(_delay <= MAXIMUM_DELAY, 'delay > maximum');
    delay = _delay;
  }

  function setDelay(uint256 _delay) external onlyOwner {
    require(_delay >= MINIMUM_DELAY, 'delay < minimum');
    require(_delay <= MAXIMUM_DELAY, 'delay > maximum');
    delay = _delay;
    emit NewDelay(_delay);
  }

  function queueTransaction(address _target) external onlyOwner returns (bytes32) {
    uint256 eta = block.timestamp + delay;
    bytes32 txHash = keccak256(abi.encode(_target, eta));
    require(!queuedTransactions[txHash], 'already queued');

    queuedTransactions[txHash] = true;
    emit QueueTransaction(txHash, _target, eta);
    return txHash;
  }

  function cancelTransaction(address _target, uint256 _eta) external onlyOwner {
    bytes32 txHash = keccak256(abi.encode(_target, _eta));
    require(queuedTransactions[txHash], 'not queued');

    queuedTransactions[txHash] = false;
    emit CancelTransaction(txHash, _target, _eta);
  }

  function execute(address _target, uint256 _eta) external onlyOwner {
    bytes32 txHash = keccak256(abi.encode(_target, _eta));
    require(queuedTransactions[txHash], 'not queued');
    require(block.timestamp >= _eta, 'not ready');
    require(block.timestamp <= _eta + 14 days, 'expired');

    queuedTransactions[txHash] = false;

    (bool success, bytes memory returnData) = _target.delegatecall(
      abi.encodeWithSignature('execute()')
    );
    require(success, string(returnData));

    emit ExecuteTransaction(txHash, _target, _eta);
  }

  /// @notice Emergency execute without timelock — can be permanently disabled
  bool public emergencyDisabled;

  event EmergencyExecuted(address indexed target);
  event EmergencyPermanentlyDisabled();

  function emergencyExecute(address _target) external onlyOwner {
    require(!emergencyDisabled, 'emergency disabled');
    (bool success, bytes memory returnData) = _target.delegatecall(
      abi.encodeWithSignature('execute()')
    );
    require(success, string(returnData));
    emit EmergencyExecuted(_target);
  }

  /// @notice Permanently disable emergency execute — cannot be undone
  function disableEmergency() external onlyOwner {
    emergencyDisabled = true;
    emit EmergencyPermanentlyDisabled();
  }
}
