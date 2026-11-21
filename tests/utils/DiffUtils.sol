// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.7.5 <0.9.0;

import 'forge-std/StdJson.sol';
import 'forge-std/Test.sol';

/**
 * Helper contract to invoke json diffing via js
 */
contract DiffUtils is Test {
  using stdJson for string;

  /// @dev The project-local CLI installed from the lockfile (package.json pins aave-cli 1.0.0).
  /// Called directly, never through npx, so no global or cached copy and no download can run.
  string internal constant AAVE_CLI = 'node_modules/.bin/aave-cli';
  string internal constant AAVE_CLI_VERSION = '1.0.0';

  /**
   * @dev Writes a human-readable markdown diff of two configuration reports. Informational only:
   * the tests' assertions do not depend on it. Opt-in (CORE-06): runs only with
   * AAVE_CLI_DIFFS=true and the `reports` profile (ffi = true); otherwise it is a no-op.
   *
   * UNSUPPORTED as of 2026-11-20: no Node / aave-cli combination is verified to produce these
   * diffs for chain 31337. aave-cli 1.0.0 with js-utils 1.4.8 fails to load under
   * Node 24 (CHAIN_ID_CLIENT_MAP import error); 1.1.0-1.4.8 need an RPC for the report's chain
   * id, which 31337 does not have; strategy images are fetched from dash.onaave.com. If you
   * enable it, a failing CLI fails the test loudly (exit code and stderr) instead of leaving a
   * missing or stale markdown file.
   */
  function diffReports(string memory reportBefore, string memory reportAfter) internal {
    if (!vm.envOr('AAVE_CLI_DIFFS', false)) return;
    string memory outPath = string(
      abi.encodePacked('./diffs/', reportBefore, '_', reportAfter, '.md')
    );
    string memory beforePath = string(abi.encodePacked('./reports/', reportBefore, '.json'));
    string memory afterPath = string(abi.encodePacked('./reports/', reportAfter, '.json'));

    _requirePinnedCli();

    string[] memory inputs = new string[](6);
    inputs[0] = AAVE_CLI;
    inputs[1] = 'diff-snapshots';
    inputs[2] = beforePath;
    inputs[3] = afterPath;
    inputs[4] = '-o';
    inputs[5] = outPath;
    Vm.FfiResult memory result = vm.tryFfi(inputs);
    if (result.exitCode != 0) {
      revert(
        string(
          abi.encodePacked(
            'aave-cli diff-snapshots failed (exit ',
            vm.toString(int256(result.exitCode)),
            '; run `yarn install --frozen-lockfile` first): ',
            string(result.stderr)
          )
        )
      );
    }
  }

  /// @dev Refuses a stale local install (e.g. one made under an older version range): the
  /// installed package must be exactly AAVE_CLI_VERSION.
  function _requirePinnedCli() private {
    string[] memory versionCmd = new string[](3);
    versionCmd[0] = 'node';
    versionCmd[1] = '-p';
    versionCmd[2] = "require('./node_modules/@bgd-labs/aave-cli/package.json').version";
    Vm.FfiResult memory version = vm.tryFfi(versionCmd);
    if (version.exitCode != 0 || keccak256(version.stdout) != keccak256(bytes(AAVE_CLI_VERSION))) {
      revert(
        string(
          abi.encodePacked(
            'aave-cli ',
            AAVE_CLI_VERSION,
            ' is not installed locally (found: ',
            string(version.stdout),
            string(version.stderr),
            '); run `yarn install --frozen-lockfile` first'
          )
        )
      );
    }
  }
}
