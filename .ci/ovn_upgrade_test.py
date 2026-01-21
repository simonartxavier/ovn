#!/usr/bin/env python3

import atexit
import os
import signal
import sys
from pathlib import Path


from ovn_upgrade_utils import (
    log,
    run_command,
    run_shell_command,
    ovn_upgrade_save_current_binaries,
    ovn_upgrade_extract_info,
    run_upgrade_workflow,
    remove_upgrade_test_directory,
)


def run_tests(base_dir, original_dir, flags, unstable):
    log(f"Running system tests in upgrade scenario with flags {flags}")
    os.chdir(base_dir)
    cc = os.environ.get('CC', 'gcc')
    no_debug = "1" if sys.stdout.isatty() else "0"

    test_cmd = f"""CC={cc} TESTSUITE=system-test UPGRADE_TEST=yes
               TEST_RANGE="{flags}" UNSTABLE={unstable}
               NO_DEBUG={no_debug} . {original_dir}/.ci/linux-build.sh"""

    success = run_shell_command(test_cmd)
    os.chdir(original_dir)
    return success


def main():
    test_success = False
    cleanup_done = False

    def cleanup():
        nonlocal cleanup_done
        if cleanup_done:
            return
        cleanup_done = True

        flags = os.environ.get('TESTSUITEFLAGS', '')
        if '-d' in flags or not test_success:
            log(f"Keeping {upgrade_dir} for debugging")
        else:
            remove_upgrade_test_directory(upgrade_dir, base_dir)

    atexit.register(cleanup)
    signal.signal(signal.SIGINT, lambda s, f: sys.exit(1))
    signal.signal(signal.SIGTERM, lambda s, f: sys.exit(1))

    base_version = os.environ.get('BASE_VERSION', 'branch-24.03')
    flags = os.environ.get('TESTSUITEFLAGS')
    unstable = os.environ.get('UNSTABLE')

    log("=" * 70)
    log(f"OVN Upgrade Test - Base: {base_version}, Flags: {flags}")
    log("=" * 70)

    if not run_command(["sudo", "-v"])[0]:
        log("sudo access required")
        return 1

    original_dir = Path.cwd()
    upgrade_dir = original_dir / "tests/upgrade-testsuite.dir"
    base_dir = upgrade_dir / "base-repo"
    binaries_dir = upgrade_dir / "ovn-upgrade-binaries"

    log(f"Removing old {upgrade_dir}...")
    if not remove_upgrade_test_directory(upgrade_dir, base_dir):
        log(f"Failed to remove old {upgrade_dir}")
        return 1

    upgrade_dir.mkdir(parents=True, exist_ok=True)
    base_dir.mkdir(parents=True, exist_ok=True)
    binaries_dir.mkdir(parents=True, exist_ok=True)

    log("Saving current version binaries")
    if not ovn_upgrade_save_current_binaries(binaries_dir):
        log("Failed to save current binaries")
        return 1

    if not ovn_upgrade_extract_info(upgrade_dir):
        log("Failed to extract info")
        return 1

    if not run_upgrade_workflow(base_version, base_dir, upgrade_dir,
                                binaries_dir):
        log("Upgrade workflow failed")
        return 1

    test_success = run_tests(base_dir, original_dir, flags, unstable)

    log("=" * 70)
    if test_success:
        log("UPGRADE TESTS PASSED")
    else:
        log("UPGRADE TESTS FAILED")
        log(f"Check: {base_dir}/tests/system-kmod-testsuite.log")
    log("=" * 70)

    return 0 if test_success else 1


if __name__ == "__main__":
    sys.exit(main())
