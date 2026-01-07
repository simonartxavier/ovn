#!/bin/bash

set -e

. "$(dirname $0)/linux-util.sh"

BASE_VERSION="${BASE_VERSION:-branch-24.03}"
TEST_RANGE="${TEST_RANGE:-1-}"

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

    echo
    log "Cleaning up..."
    log "Restoring modified files..."
    # Restore OVN test files
    git checkout tests/ovn-macros.at tests/system-kmod-macros.at \
                tests/system-ovn.at tests/system-ovn-kmod.at \
                >> logs/git.log 2>&1 || true
    # Restore OVS submodule files
    (cd ovs && git checkout vswitchd/vswitch.ovsschema \
        >> ../logs/git.log 2>&1 || true)
    # Restore CI scripts (may have been replaced during upgrade test)
    git checkout .ci/linux-build.sh .ci/linux-util.sh \
                >> logs/git.log 2>&1 || true

    log "Restoring original branch/commit..."
    # If we were on a branch, restore to the branch; otherwise restore to commit
    if [ "$CURRENT_BRANCH" != "HEAD" ]; then
        if ! git checkout "$CURRENT_BRANCH" >> logs/git.log 2>&1; then
            log "WARNING: Failed to restore branch $CURRENT_BRANCH" >&2
        fi
    else
        # We were in detached HEAD state, restore to the commit
        if ! git checkout "$CURRENT_COMMIT" >> logs/git.log 2>&1; then
            log "WARNING: Failed to restore commit $CURRENT_COMMIT" >&2
        fi
    fi

    log "Updating submodules..."
    git submodule update --init >> logs/git.log 2>&1 || true
    log "Restored to: $CURRENT_BRANCH ($CURRENT_COMMIT)"

    # Cleanup temporary files
    rm -rf /tmp/ovn-upgrade-binaries /tmp/ovn-upgrade-ci
    rm -f /tmp/ovn-upgrade-ofctl-defines.h
    rm -f /tmp/ovn-upgrade-oftable-m4-defines.txt
    rm -f /tmp/ovn-upgrade-new-log-egress.txt
    rm -f /tmp/ovn-upgrade-new-save-inport.txt
}

trap cleanup EXIT INT TERM

# Request sudo credentials early
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

# Create logs directory
mkdir -p logs

# Export environment variables for linux-build.sh
export TESTSUITE="upgrade-test"
export BASE_VERSION="$BASE_VERSION"
export TEST_RANGE="$TEST_RANGE"
export JOBS="${JOBS:--j$(nproc 2>/dev/null || echo 4)}"
export CC="${CC:-gcc}"
export DEBUG="${DEBUG:-0}"  # Disable verbose set -x output by default
export USE_SPARSE="${USE_SPARSE:-no}"  # Disable sparse for local tests

log "Running upgrade tests via linux-build.sh..."
echo

# Run linux-build.sh which will call execute_upgrade_tests()
if ./.ci/linux-build.sh; then
    echo
    log "Upgrade test completed successfully"
    TEST_STATUS=0
else
    echo
    log "Upgrade test failed - check logs"
    TEST_STATUS=1
fi

# Print summary
echo
log "Logs saved to:"
log "  - logs/git.log"
log "  - tests/system-kmod-testsuite.log"

exit $TEST_STATUS
