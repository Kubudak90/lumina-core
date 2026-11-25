// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Script} from 'forge-std/Script.sol';
import {VmSafe} from 'forge-std/Vm.sol';
import {console} from 'forge-std/console.sol';

/**
 * @title LighterManifest
 * @notice Reads and writes the deployment manifest (lumina-monorepo `deployments/<env>.json`,
 * schema in `deployments/README.md`) from forge scripts.
 *
 * The file is a staged copy under `reports/lighter/` (foundry.toml `fs_permissions`); its path is
 * `$LUMINA_MANIFEST`. The caller (lumina-monorepo `harness/deploy/`) copies the manifest there,
 * runs the script and, only when the script and its broadcast succeeded, validates the staged copy
 * with the monorepo loader (`deployments/index.mjs`) before it replaces the manifest. forge writes
 * files during its local simulation, before broadcasting; the validated copy-back is what makes
 * a failed broadcast leave the manifest untouched.
 *
 * `vm.writeJson` replaces whole values by key; array elements are rewritten as whole arrays.
 */
abstract contract LighterManifest is Script {
  string internal constant LIGHTER_ENVIRONMENT = 'lighter-devnet';
  string internal constant CORE_REPO = 'lumina-core';
  bytes32 internal constant EIP1967_IMPLEMENTATION_SLOT =
    0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

  string internal _manifestPath;
  string internal _json;

  // ------------------------------------------------------------------------------------------
  // Loading
  // ------------------------------------------------------------------------------------------

  /// @dev Loads `$LUMINA_MANIFEST` and refuses a manifest for another chain or environment.
  function _loadManifest() internal {
    _manifestPath = vm.envString('LUMINA_MANIFEST');
    _json = vm.readFile(_manifestPath);
    require(vm.parseJsonUint(_json, '.schemaVersion') == 1, 'manifest: schemaVersion != 1');
    require(
      keccak256(bytes(vm.parseJsonString(_json, '.environment'))) ==
        keccak256(bytes(LIGHTER_ENVIRONMENT)),
      'manifest: environment is not lighter-devnet'
    );
    uint256 chainId = vm.parseJsonUint(_json, '.chainId');
    require(
      chainId == block.chainid,
      string.concat(
        'manifest: chainId ',
        vm.toString(chainId),
        ' does not match the RPC chain ',
        vm.toString(block.chainid)
      )
    );
    console.log('manifest:', _manifestPath);
  }

  function _reload() internal {
    _json = vm.readFile(_manifestPath);
  }

  /// @dev An address value, or address(0) when it is JSON null.
  function _address(string memory key) internal view returns (address) {
    bytes memory raw = vm.parseJson(_json, key);
    if (raw.length == 0) return address(0);
    return abi.decode(raw, (address));
  }

  function _requireAddress(string memory key) internal view returns (address a) {
    a = _address(key);
    require(a != address(0), string.concat('manifest: ', key, ' is not set'));
  }

  /// @dev An address that must be set and hold code.
  function _requireDeployed(string memory key) internal view returns (address a) {
    a = _requireAddress(key);
    require(a.code.length > 0, string.concat('manifest: no code at ', key));
  }

  /// @dev True when the address at `key` is set and holds code.
  function _isDeployed(string memory key) internal view returns (bool) {
    if (!vm.keyExistsJson(_json, key)) return false;
    address a = _address(key);
    return a != address(0) && a.code.length > 0;
  }

  function _uint(string memory key) internal view returns (uint256) {
    return vm.parseJsonUint(_json, key);
  }

  function _bool(string memory key) internal view returns (bool) {
    return vm.parseJsonBool(_json, key);
  }

  function _isNull(string memory key) internal view returns (bool) {
    bytes memory raw = vm.parseJson(_json, key);
    return raw.length == 32 && bytes32(raw) == bytes32(0);
  }

  // ------------------------------------------------------------------------------------------
  // Writing
  // ------------------------------------------------------------------------------------------

  /// @dev Replaces the value at `key` (created if missing) with the JSON text `value`.
  function _write(string memory key, string memory value) internal {
    vm.writeJson(value, _manifestPath, key);
    _reload();
  }

  function _q(string memory s) internal pure returns (string memory) {
    return string.concat('"', s, '"');
  }

  function _jAddress(address a) internal pure returns (string memory) {
    return _q(vm.toString(a));
  }

  function _jHash(bytes32 h) internal pure returns (string memory) {
    return _q(vm.toString(h)); // lowercase 0x-hex
  }

  function _jUint(uint256 v) internal pure returns (string memory) {
    return vm.toString(v);
  }

  /// @dev Decimal string (the manifest's format for amounts that may exceed 2^53).
  function _jUintString(uint256 v) internal pure returns (string memory) {
    return _q(vm.toString(v));
  }

  function _jBool(bool b) internal pure returns (string memory) {
    return b ? 'true' : 'false';
  }

  function _jAddressArray(address[] memory list) internal pure returns (string memory out) {
    out = '[';
    for (uint256 i = 0; i < list.length; i++) {
      out = string.concat(out, i == 0 ? '' : ',', _jAddress(list[i]));
    }
    out = string.concat(out, ']');
  }

  /// @dev Foundry artifact path of `name` compiled from `<name>.sol`.
  function _out(string memory name) internal pure returns (string memory) {
    return string.concat('out/', name, '.sol/', name, '.json');
  }

  function _artifactJson(string memory name) internal pure returns (string memory) {
    return
      string.concat(
        '{"repo":',
        _q(CORE_REPO),
        ',"path":',
        _q(_out(name)),
        ',"contractName":',
        _q(name),
        '}'
      );
  }

  /// @dev `{address, artifact, codehash}` of a deployed lumina-core contract.
  function _contractJson(address a, string memory name) internal view returns (string memory) {
    require(a.code.length > 0, string.concat('no code for ', name));
    return
      string.concat(
        '{"address":',
        _jAddress(a),
        ',"artifact":',
        _artifactJson(name),
        ',"codehash":',
        _jHash(a.codehash),
        '}'
      );
  }

  /// @dev Same with linked libraries (`libraries` is a JSON object text).
  function _contractJsonWithLibraries(
    address a,
    string memory name,
    string memory libraries
  ) internal view returns (string memory) {
    require(a.code.length > 0, string.concat('no code for ', name));
    return
      string.concat(
        '{"address":',
        _jAddress(a),
        ',"artifact":',
        _artifactJson(name),
        ',"codehash":',
        _jHash(a.codehash),
        ',"libraries":',
        libraries,
        '}'
      );
  }

  /// @dev An EIP-1967 proxy and its implementation (`implementation` is a contract JSON text).
  function _proxyJson(
    address proxy,
    string memory proxyName,
    string memory implementation
  ) internal view returns (string memory) {
    require(proxy.code.length > 0, string.concat('no code for proxy ', proxyName));
    return
      string.concat(
        '{"address":',
        _jAddress(proxy),
        ',"artifact":',
        _artifactJson(proxyName),
        ',"codehash":',
        _jHash(proxy.codehash),
        ',"implementation":',
        implementation,
        '}'
      );
  }

  function _implementationOf(address proxy) internal view returns (address) {
    return address(uint160(uint256(vm.load(proxy, EIP1967_IMPLEMENTATION_SLOT))));
  }

  function _writeContract(string memory key, address a, string memory name) internal {
    _write(string.concat('.contracts.', key), _contractJson(a, name));
  }

  // ------------------------------------------------------------------------------------------
  // Broadcast hygiene
  // ------------------------------------------------------------------------------------------

  /**
   * @dev forge deploys (and broadcasts) any library a script needs that FOUNDRY_LIBRARIES does not
   * link, before `run()` starts. Those deployments would be unrecorded and would shift the
   * deployer nonce. They show up as a simulated nonce above the chain's: refuse to continue.
   */
  function _requireNoForgeLibraryDeploys(address deployer) internal {
    bytes memory raw = vm.rpc(
      'eth_getTransactionCount',
      string.concat('["', vm.toString(deployer), '","latest"]')
    );
    uint256 onChain;
    for (uint256 i = 0; i < raw.length; i++) onChain = (onChain << 8) | uint8(raw[i]);
    require(
      vm.getNonce(deployer) == onChain,
      'forge queued its own library deployments: FOUNDRY_LIBRARIES does not link every library this script needs'
    );
  }

  // ------------------------------------------------------------------------------------------
  // Source provenance (needs --ffi; fixed argv, no shell)
  // ------------------------------------------------------------------------------------------

  /// @dev HEAD of this checkout as 40 lowercase hex characters.
  function _gitHead() internal returns (string memory) {
    string[] memory cmd = new string[](3);
    cmd[0] = 'git';
    cmd[1] = 'rev-parse';
    cmd[2] = 'HEAD';
    bytes memory out = vm.ffi(cmd);
    // forge hex-decodes ffi output that is valid hex: a commit hash comes back as 20 bytes.
    if (out.length == 20) {
      bytes memory hexed = bytes(vm.toString(out));
      bytes memory commit = new bytes(40);
      for (uint256 i = 0; i < 40; i++) commit[i] = hexed[i + 2];
      return string(commit);
    }
    require(out.length == 40, 'git rev-parse HEAD: unexpected output');
    return string(out);
  }

  /**
   * @dev The deployed bytecode must be reproducible from `sourceCommits`: refuse a checkout with
   * changes unless `LUMINA_ALLOW_DIRTY=true` (local iteration only; never for a live deploy).
   */
  function _requireCleanCheckout() internal {
    string[] memory cmd = new string[](3);
    cmd[0] = 'git';
    cmd[1] = 'status';
    cmd[2] = '--porcelain';
    bytes memory out = vm.ffi(cmd);
    if (out.length == 0) return;
    bool allowDirty = vm.envOr('LUMINA_ALLOW_DIRTY', false);
    if (allowDirty) {
      console.log(
        'WARNING: lumina-core checkout has uncommitted changes (LUMINA_ALLOW_DIRTY=true)'
      );
      return;
    }
    revert(
      'lumina-core checkout has uncommitted changes; commit first (sourceCommits must match the build)'
    );
  }

  /// @dev The lumina-core commit the manifest records, or '' when it is still null.
  function _recordedCommit() internal view returns (string memory) {
    string memory key = string.concat('.sourceCommits.', CORE_REPO);
    if (_isNull(key)) return '';
    return vm.parseJsonString(_json, key);
  }

  /**
   * @dev Call before a phase sends anything. A clean checkout (see `_requireCleanCheckout`), and a
   * partial deploy is only continued from the commit that started it: every lumina-core contract
   * in one manifest is built from one `sourceCommits` entry.
   */
  function _beforeBroadcast() internal {
    _requireCleanCheckout();
    string memory recorded = _recordedCommit();
    string memory head = _gitHead();
    require(
      bytes(recorded).length == 0 || keccak256(bytes(recorded)) == keccak256(bytes(head)),
      string.concat(
        'lumina-core HEAD ',
        head,
        ' differs from the manifest sourceCommits ',
        recorded,
        ': continue a partial deploy from the commit that started it'
      )
    );
  }

  /// @dev Call after a phase sent transactions: records HEAD when no commit is recorded yet. A
  /// phase that sent nothing never touches sourceCommits.
  function _recordSourceCommit() internal {
    if (bytes(_recordedCommit()).length == 0) {
      _write(string.concat('.sourceCommits.', CORE_REPO), _q(_gitHead()));
    }
  }

  // ------------------------------------------------------------------------------------------
  // Logs on Forge's active fork (the chain this run broadcasts to)
  // ------------------------------------------------------------------------------------------

  /**
   * @dev The log `emitter` emitted with `topic0` / `topic1` in transaction `txHash`, read with
   * `eth_getLogs` on the active fork (never another RPC). Its block must be canonical there: the
   * keccak256 of the fork's raw header at that height is the log's block hash. Only a successful
   * transaction leaves logs. Reverts when no such log exists.
   * @return blockNumber of the transaction
   */
  function _requireLog(
    address emitter,
    bytes32 topic0,
    bytes32 topic1,
    bytes32 txHash,
    uint256 fromBlock
  ) internal returns (uint256 blockNumber) {
    bytes32[] memory topics = new bytes32[](topic1 == bytes32(0) ? 1 : 2);
    topics[0] = topic0;
    if (topic1 != bytes32(0)) topics[1] = topic1;
    VmSafe.EthGetLogs[] memory logs = vm.eth_getLogs(fromBlock, block.number, emitter, topics);
    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].transactionHash != txHash || logs[i].removed) continue;
      require(
        keccak256(ILighterRawHeader(address(vm)).getRawBlockHeader(logs[i].blockNumber)) ==
          logs[i].blockHash,
        string.concat('log block is not canonical on this fork: ', vm.toString(txHash))
      );
      return logs[i].blockNumber;
    }
    revert(
      string.concat('no log of ', vm.toString(emitter), ' in transaction ', vm.toString(txHash))
    );
  }

  /// @dev True when the 20 bytes of `a` occur in `code` (a linked library address).
  function _containsAddress(bytes memory code, address a) internal pure returns (bool found) {
    if (code.length < 20) return false;
    assembly ('memory-safe') {
      let start := add(code, 32)
      let end := sub(add(start, mload(code)), 19)
      for {
        let p := start
      } lt(p, end) {
        p := add(p, 1)
      } {
        if eq(shr(96, mload(p)), a) {
          found := 1
          break
        }
      }
    }
  }
}

/// @dev Foundry cheatcode (not yet in this forge-std): the RLP block header at `blockNumber` on the
/// active fork; its keccak256 is the block hash.
interface ILighterRawHeader {
  function getRawBlockHeader(uint256 blockNumber) external view returns (bytes memory);
}
