// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.7.5 <0.9.0;

import 'forge-std/StdJson.sol';
import 'forge-std/Test.sol';

/**
 * Helper contract to invoke json diffing via js
 */
contract DiffUtils is Test {
  using stdJson for string;

  /// @dev Exact, lockfile-pinned version (package.json / yarn.lock). Never fetched at run time:
  /// `npx --no-install` only runs the copy installed from the lockfile.
  string internal constant AAVE_CLI = '@bgd-labs/aave-cli@1.0.0';

  /**
   * @dev Writes a human-readable markdown diff of two configuration reports. Informational only:
   * the tests' assertions do not depend on it. Opt-in (CORE-06): runs only with
   * AAVE_CLI_DIFFS=true and the `reports` profile (ffi = true); otherwise it is a no-op.
   * Known limitation (2026-11-20): aave-cli 1.0.0 fails to load under Node 24 (CommonJS named
   * export), and 1.1.0-1.4.8 need an RPC for the report's chain id, which 31337 does not have.
   */
  function diffReports(string memory reportBefore, string memory reportAfter) internal {
    if (!vm.envOr('AAVE_CLI_DIFFS', false)) return;
    string memory outPath = string(
      abi.encodePacked('./diffs/', reportBefore, '_', reportAfter, '.md')
    );
    string memory beforePath = string(abi.encodePacked('./reports/', reportBefore, '.json'));
    string memory afterPath = string(abi.encodePacked('./reports/', reportAfter, '.json'));

    string[] memory inputs = new string[](8);
    inputs[0] = 'npx';
    inputs[1] = '--no-install';
    inputs[2] = AAVE_CLI;
    inputs[3] = 'diff-snapshots';
    inputs[4] = beforePath;
    inputs[5] = afterPath;
    inputs[6] = '-o';
    inputs[7] = outPath;
    vm.ffi(inputs);
  }
}
