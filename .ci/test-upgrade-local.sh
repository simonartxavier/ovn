#!/bin/bash

set -e

. "$(dirname $0)/linux-util.sh"

BASE_VERSION="${BASE_VERSION:-branch-24.03}"
TEST_RANGE="${TEST_RANGE:-1-}"
LOG_DIR="$(pwd)/upgrade-test-logs"
BUILD_CURRENT_LOG="$LOG_DIR/build-current.log"
BUILD_BASE_LOG="$LOG_DIR/build-base.log"

BASE_VERSION_CHECKED_OUT=0
CLEANUP_DONE=0
TEST_STATUS=1

usage() {
    cat << EOF
Usage: $0 [options]

Test OVN upgrade compatibility without GitHub.

Options:
    -b, --base-version VERSION   Base version to test (default: branch-24.03)
    -t, --test-range RANGE       Test range to run (default: 1-)
                                 Examples: -100, 101-, 55
    -h, --help                   Show this help message

Environment Variables:
    BASE_VERSION                 Same as --base-version
    TEST_RANGE                   Same as --test-range

Examples:
    # Test against branch-24.03 with all tests
    $0

    # Test against specific version
    $0 --base-version v24.03.0

    # Test specific test range
    $0 --test-range 101-200
EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -b|--base-version)
            BASE_VERSION="$2"
            shift 2
            ;;
        -t|--test-range)
            TEST_RANGE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

log "========================================"
log "OVN Upgrade Test"
log "Base version: $BASE_VERSION"
log "Test range: $TEST_RANGE"

# Check if we're in the OVN repository root
if [ ! -f "configure.ac" ] || ! grep -q "ovn" configure.ac; then
    log "Error: This script must be run from the OVN repository root"
    exit 1
fi

start_sudo_keepalive() {
    (while true; do sudo -n true; sleep 50; done) 2>/dev/null &
    SUDO_KEEPALIVE_PID=$!
    if ! kill -0 $SUDO_KEEPALIVE_PID 2>/dev/null; then
        log "ERROR: sudo keepalive failed to start"
        exit 1
    fi
}

stop_sudo_keepalive() {
    if [ -n "$SUDO_KEEPALIVE_PID" ]; then
        kill $SUDO_KEEPALIVE_PID 2>/dev/null || true
    fi
}

# Cleanup function - always runs on exit
cleanup() {
    if [ $CLEANUP_DONE -eq 1 ]; then
        return
    fi
    CLEANUP_DONE=1

    stop_sudo_keepalive

    # Only restore git state if we checked out base version
    if [ $BASE_VERSION_CHECKED_OUT -eq 1 ]; then
        echo
        log "Cleaning up..."
        log "Restoring modified files... "
        # Restore OVN test files
        git checkout tests/ovn-macros.at tests/system-kmod-macros.at \
                    tests/system-ovn.at tests/system-ovn-kmod.at
            > /dev/null 2>&1 || true
        # Restore OVS submodule files
        (cd ovs && git checkout vswitchd/vswitch.ovsschema
            > /dev/null 2>&1 || true)
        log "Restoring original commit... "
        if ! git checkout "$CURRENT_COMMIT" > /dev/null 2>&1; then
            log "WARNING: Failed to restore commit $CURRENT_COMMIT" >&2
        fi

        log "Updating submodules... "
        git submodule update --init > /dev/null 2>&1 || true
        log "Restored to: $CURRENT_BRANCH ($CURRENT_COMMIT)"
    fi

    # Cleanup temporary files
    rm -rf /tmp/ovn-upgrade-binaries
    rm -f /tmp/ovn-upgrade-ofctl-defines.h
    rm -f /tmp/ovn-upgrade-oftable-m4-defines.txt
    rm -f /tmp/ovn-upgrade-new-log-egress.txt
    rm -f /tmp/ovn-upgrade-new-save-inport.txt
}

trap cleanup EXIT INT TERM

# Request sudo credentials early - so we do not have to wait until compilation
# is complete.
if ! sudo -nv 2>/dev/null; then
    log "This script requires sudo for running system tests."
    log "Please enter your password now:"
    sudo -v || {
        log "Error: sudo authentication failed"
        exit 1
    }
fi

start_sudo_keepalive

# Save current branch/commit
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
CURRENT_COMMIT=$(git rev-parse HEAD)
log "Current branch: $CURRENT_BRANCH"
log "Current commit: $CURRENT_COMMIT"
echo

# Check if working directory is clean
if ! git diff-index --quiet HEAD --; then
    log "Warning: Working directory has uncommitted changes"
    read -p "Continue anyway? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

mkdir -p "$LOG_DIR"

# Build current ovn-controller
if ovs_ovn_upgrade_build "$BUILD_CURRENT_LOG"; then
    ovn_upgrade_save_current_binaries
else
    log "Build FAILED"
    log "Build log: $BUILD_CURRENT_LOG"
    exit 1
fi
echo

# Checkout base version
if ! ovn_upgrade_checkout_base "$BASE_VERSION" "$BUILD_BASE_LOG"; then
    log "Checkout FAILED"
    exit 1
fi
BASE_VERSION_CHECKED_OUT=1

# Patch tests now so we only recompile them once.
# This must also be done before patching lflow.h
log "patching tests"
ovn_upgrade_apply_tests_patches

# Second build - with patched lflow.h to create hybrid ovn-debug
log "Patching lflow.h with current OFTABLE defines..."
ovn_upgrade_patch_for_ovn_debug

if ! ovs_ovn_upgrade_build "$BUILD_BASE_LOG"; then
    log "Build FAILED"
    log "Build log: $BUILD_BASE_LOG"
    exit 1
fi

ovn_upgrade_save_ovn_debug

# Third build - restore lflow.h and rebuild for clean base
log "Restoring lflow.h to original..."
git checkout controller/lflow.h > /dev/null 2>&1

if ! ovn_upgrade_build "$BUILD_BASE_LOG"; then
    log "Rebuild FAILED"
    log "Build log: $BUILD_BASE_LOG"
    exit 1
fi
echo

# Replace ovn-controller and OVS binaries with current versions
ovn_upgrade_restore_binaries

# Run tests
export TEST_RANGE="$TEST_RANGE"

# Get version-specific skip list
SKIP_TESTS=$(ovn_upgrade_get_skip_list "$BASE_VERSION")
if [ -n "$SKIP_TESTS" ]; then
    echo "Skipping tests for $BASE_VERSION: $SKIP_TESTS"
    ADJUSTED_RANGE=$(ovn_upgrade_adjust_test_range "$TEST_RANGE" "$SKIP_TESTS")
    export TEST_RANGE="$ADJUSTED_RANGE"
fi

log "Running: make check-kernel with TEST_RANGE=$TEST_RANGE"
stop_sudo_keepalive

# Run tests
if sudo make check-kernel TESTSUITEFLAGS="$TEST_RANGE"; then
    echo "Tests PASSED!"
    TEST_STATUS=0
else
    echo "Tests FAILED"
    TEST_STATUS=1
fi

# Print summary (cleanup will happen automatically via trap)
echo
if [ $TEST_STATUS -eq 0 ]; then
    log "Upgrade test completed successfully"
    echo
    log "Logs saved to:"
    log "  Build logs: $LOG_DIR/"
    log "  - Current build: $BUILD_CURRENT_LOG"
    log "  - Base build: $BUILD_BASE_LOG"
else
    log "Upgrade test failed - check logs"
    echo
    log "Logs saved to:"
    log "  Build logs: $LOG_DIR/"
    log "  - Current build: $BUILD_CURRENT_LOG"
    log "  - Base build: $BUILD_BASE_LOG"
    log "  Test logs:"
    log "  - Full log: tests/system-kmod-testsuite.log"
    log "  - Filtered log: tests/filtered-testsuite.log"
fi

exit $TEST_STATUS
