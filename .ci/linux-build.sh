#!/bin/bash

set -o errexit
# Enable debug output for CI, optional for local
if [ "${NO_DEBUG:-0}" = "0" ]; then
    set -x
fi

ARCH=${ARCH:-"x86_64"}
USE_SPARSE=${USE_SPARSE:-"yes"}
COMMON_CFLAGS=""
OVN_CFLAGS=""
OPTS="$OPTS --enable-Werror"
JOBS=${JOBS:-"-j4"}
RECHECK=${RECHECK:-"no"}
TIMEOUT=${TIMEOUT:-"0"}

function install_dpdk()
{
    local DPDK_INSTALL_DIR="$(pwd)/dpdk-dir"
    local VERSION_FILE="${DPDK_INSTALL_DIR}/cached-version"
    local DPDK_PC=$(find $DPDK_INSTALL_DIR -type f -name libdpdk-libs.pc)

    # Export the following path for pkg-config to find the .pc file.
    export PKG_CONFIG_PATH="$(dirname $DPDK_PC):$PKG_CONFIG_PATH"

    if [ ! -f "${VERSION_FILE}" ]; then
        echo "Could not find DPDK in $DPDK_INSTALL_DIR"
        return 1
    fi

    # As we build inside a container we need to update the prefix.
    sed -i -E "s|^prefix=.*|prefix=${DPDK_INSTALL_DIR}|" $DPDK_PC

    # Update the library paths.
    sudo ldconfig
    echo "Found cached DPDK $(cat ${VERSION_FILE}) build in $DPDK_INSTALL_DIR"
}

function configure_ovs()
{
    if [ "$DPDK" ]; then
        # When DPDK is enabled, we need to build OVS twice. Once to have
        # ovs-vswitchd with DPDK. But OVN does not like the OVS libraries to
        # be compiled with DPDK enabled, hence we need a final clean build
        # with this disabled.
        install_dpdk

        pushd ovs
        ./boot.sh && ./configure CFLAGS="${COMMON_CFLAGS}" --with-dpdk=static \
            $* || { cat config.log; exit 1; }
        make $JOBS || { cat config.log; exit 1; }
        cp vswitchd/ovs-vswitchd vswitchd/ovs-vswitchd_with_dpdk
        popd
    fi

    pushd ovs
    ./boot.sh && ./configure CFLAGS="${COMMON_CFLAGS}" $* || \
        { cat config.log; exit 1; }
    make $JOBS || { cat config.log; exit 1; }
    popd

    if [ "$DPDK" ]; then
        cp ovs/vswitchd/ovs-vswitchd_with_dpdk ovs/vswitchd/ovs-vswitchd
    fi
}

function configure_ovn()
{
    configure_ovs $*
    ./boot.sh && ./configure CFLAGS="${COMMON_CFLAGS} ${OVN_CFLAGS}" $* || \
    { cat config.log; exit 1; }
}

function configure_sanitizers()
{
    # If AddressSanitizer and UndefinedBehaviorSanitizer are requested,
    # enable them, but only for OVN, not for OVS.  However, disable some
    # optimizations for OVS, to make sanitizer reports user friendly.
    COMMON_CFLAGS="${COMMON_CFLAGS} -O1 -fno-omit-frame-pointer -fno-common -g"
    OVN_CFLAGS="${OVN_CFLAGS} -fsanitize=address,undefined"
}

function configure_gcc()
{
    if [ "$ARCH" = "x86" ]; then
        # Adding m32 flag directly to CC to avoid any possible issues
        # with API/ABI difference on 'configure' and 'make' stages.
        export CC="$CC -m32"
        if which apt; then
            # We should install gcc-multilib for x86 build, we cannot
            # do it directly because gcc-multilib is not available
            # for arm64
            sudo apt update && sudo apt install -y gcc-multilib
        elif which dnf; then
            # Install equivalent of gcc-multilib for Fedora.
            sudo dnf -y install glibc-devel.i686
        fi

        return
    fi

    if [ "$ARCH" = "x86_64" ] && [ "$USE_SPARSE" = "yes" ]; then
        # Enable sparse only for x86_64 architecture.
        OPTS="$OPTS --enable-sparse"
    fi

    if [ "$SANITIZERS" ]; then
        configure_sanitizers
        # Unlike for clang we also need to statically link the libraries.
        # https://gcc.gnu.org/bugzilla/show_bug.cgi?id=94328
        OVN_CFLAGS="${OVN_CFLAGS} -static-libasan -static-libubsan"
    fi
}

function configure_clang()
{
    if [ "$SANITIZERS" ]; then
        configure_sanitizers
    fi
    COMMON_CFLAGS="${COMMON_CFLAGS} -Wno-error=unused-command-line-argument"
}

function execute_dist_tests()
{
    # 'distcheck' will reconfigure with required options.
    # Now we only need to prepare the Makefile without sparse-wrapped CC.
    configure_ovn

    export DISTCHECK_CONFIGURE_FLAGS="$OPTS"

    # Just list the tests during distcheck.
    if ! timeout -k 5m -v $TIMEOUT make distcheck \
        CFLAGS="${COMMON_CFLAGS} ${OVN_CFLAGS}" $JOBS \
        TESTSUITEFLAGS="-l"
    then
        # config.log is necessary for debugging.
        cat config.log
        exit 1
    fi
}

function run_tests()
{
    if ! timeout -k 5m -v $TIMEOUT make check \
        CFLAGS="${COMMON_CFLAGS} ${OVN_CFLAGS}" $JOBS \
        TESTSUITEFLAGS="$JOBS $TEST_RANGE" RECHECK=$RECHECK \
        SKIP_UNSTABLE=$SKIP_UNSTABLE
    then
        # testsuite.log is necessary for debugging.
        cat tests/testsuite.log
        return 1
    fi
}

function execute_tests()
{
    configure_ovn $OPTS
    make $JOBS || { cat config.log; exit 1; }

    local stable_rc=0
    local unstable_rc=0

    if ! SKIP_UNSTABLE=yes run_tests; then
        stable_rc=1
    fi

    if [ "$UNSTABLE" ]; then
        if ! SKIP_UNSTABLE=no TEST_RANGE="-k unstable" RECHECK=yes \
                run_tests; then
            unstable_rc=1
        fi
    fi

    if [[ $stable_rc -ne 0 ]] || [[ $unstable_rc -ne 0 ]]; then
        exit 1
    fi
}

function run_system_tests()
{
    local type=$1
    local log_file=$2

    if ! sudo timeout -k 5m -v $TIMEOUT make $JOBS $type \
        TESTSUITEFLAGS="$TEST_RANGE" RECHECK=$RECHECK \
        SKIP_UNSTABLE=$SKIP_UNSTABLE; then
        # $log_file is necessary for debugging.
        cat tests/$log_file
        return 1
    fi
}

function execute_system_tests()
{
    local test_type=$1
    local log_file=$2
    local skip_list=$3
    local skip_build=$4

    # Only build if not already built (upgrade tests build separately)
    if [ "$skip_build" != "yes" ]; then
        configure_ovn $OPTS
        make $JOBS || { cat config.log; exit 1; }
    fi

    local stable_rc=0
    local unstable_rc=0

    if ! SKIP_UNSTABLE=yes run_system_tests $@; then
        stable_rc=1
    fi

    if [ "$UNSTABLE" ]; then
        local unstable_range="-k unstable"
        # For upgrade tests, exclude skipped tests from unstable run
        if [ -n "$skip_list" ]; then
            . .ci/linux-util.sh
            unstable_range=$(ovn_upgrade_adjust_test_range \
                 "$unstable_range" "$skip_list") || true
        fi
        if ! SKIP_UNSTABLE=no TEST_RANGE="$unstable_range" RECHECK=yes \
                run_system_tests $test_type $log_file; then
            unstable_rc=1
        fi
    fi

    if [[ $stable_rc -ne 0 ]] || [[ $unstable_rc -ne 0 ]]; then
        exit 1
    fi
}

function execute_upgrade_tests()
{
    . .ci/linux-util.sh

    # Save current CI scripts (will be replaced by base version after checkout)
    cp -rf .ci /tmp/ovn-upgrade-ci

    # Build current version
    log "Building current version..."
    mkdir -p logs
    configure_ovn $OPTS >> logs/build-current.log 2>&1 || {
        log "configure ovn failed - see config.log and logs/build-current.log"
        exit 1
    }
    make $JOBS >> logs/build-current.log 2>&1 || {
        log "building ovn failed - see logs/build-current.log"
        exit 1
    }

    ovn_upgrade_save_current_binaries

    # Checkout base version
    ovn_upgrade_checkout_base "$BASE_VERSION" logs/git.log

    # Clean from current version
    log "Cleaning build artifacts..."
    make distclean >> logs/build-base.log 2>&1 || true
    (cd ovs && make distclean >> ../logs/build-base.log 2>&1) || true

    # Apply test patches
    ovn_upgrade_apply_tests_patches

    # Build base with patches
    ovn_upgrade_patch_for_ovn_debug

    # Build (modified) base version
    log "Building base version (with patched lflow.h)..."
    configure_ovn $OPTS >> logs/build-base.log 2>&1 || {
        log "configure ovn failed - see config.log and logs/build-base.log"
        exit 1
    }
    make $JOBS >> logs/build-base.log 2>&1 || {
        log "building ovn failed - see logs/build-base.log"
        exit 1
    }
    ovn_upgrade_save_ovn_debug

    # Build (clean) base version
    log "Rebuilding base version (clean lflow.h)..."
    git checkout controller/lflow.h >> logs/git.log 2>&1
    make $JOBS >> logs/build-base.log 2>&1 || {
        log "building ovn failed - see logs/build-base.log"
        exit 1
    }

    # Restore binaries
    ovn_upgrade_restore_binaries

    # Restore current CI scripts for test execution
    cp -f /tmp/ovn-upgrade-ci/linux-build.sh .ci/linux-build.sh
    cp -f /tmp/ovn-upgrade-ci/linux-util.sh .ci/linux-util.sh

    SKIP_LIST=$(ovn_upgrade_get_skip_list "$BASE_VERSION")
    if [ -n "$SKIP_LIST" ]; then
        echo "Skipping tests for $BASE_VERSION: $SKIP_LIST"
        if ! TEST_RANGE=$(ovn_upgrade_adjust_test_range \
             "$TEST_RANGE" "$SKIP_LIST");
        then
            exit 1
        fi
    fi
    execute_system_tests "check-kernel" "system-kmod-testsuite.log" "$SKIP_LIST" "yes"
}

configure_$CC

if [ "$TESTSUITE" ]; then
    case "$TESTSUITE" in
        "test")
        execute_tests
        ;;

        "dist-test")
        execute_dist_tests
        ;;

        "system-test")
        execute_system_tests "check-kernel" "system-kmod-testsuite.log"
        ;;

        "system-test-userspace")
        execute_system_tests "check-system-userspace" \
            "system-userspace-testsuite.log"
        ;;

        "system-test-dpdk")
        # The dpdk tests need huge page memory, so reserve some 2M pages.
        sudo bash -c "echo 2048 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages"
        execute_system_tests "check-system-dpdk" "system-dpdk-testsuite.log"
        ;;

        "upgrade-test")
        execute_upgrade_tests
        ;;

    esac
else
    configure_ovn $OPTS
    make $JOBS || { cat config.log; exit 1; }
fi

exit 0
