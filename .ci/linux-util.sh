#!/bin/bash

function free_up_disk_space_ubuntu()
{
    local pkgs='azure-cli aspnetcore-* dotnet-* ghc-* firefox*
                google-chrome-stable google-cloud-cli libmono-* llvm-*
                microsoft-edge-stable mono-* msbuild mysql-server-core-*
                php-* php7* powershell* temurin-* zulu-*'

    # Use apt patterns to only select real packages that match the names
    # in the list above.
    local pkgs=$(echo $pkgs | sed 's/[^ ]* */~n&/g')

    sudo apt update && sudo apt-get --auto-remove -y purge $pkgs

    local paths='/usr/local/lib/android/ /usr/share/dotnet/ /opt/ghc/
                 /usr/local/share/boost/'
    sudo rm -rf $paths
}

function set_containers_apparmor_profile()
{
    local profile=$1

    sed -i "s/^#apparmor_profile = \".*\"$/apparmor_profile = \"$profile\"/" \
        /usr/share/containers/containers.conf
}

# On multiple occasions GitHub added things to /etc/hosts that are not
# a correct syntax for this file causing test failures:
#   https://github.com/actions/runner-images/issues/3353
#   https://github.com/actions/runner-images/issues/12192
# Just clearing those out, if any.
function fix_etc_hosts()
{
    cp /etc/hosts ./hosts.bak
    sed -E -n \
      '/^[[:space:]]*(#.*|[0-9a-fA-F:.]+([[:space:]]+[a-zA-Z0-9.-]+)+|)$/p' \
      ./hosts.bak | sudo tee /etc/hosts

    diff -u ./hosts.bak /etc/hosts || true
}

# Workaround until https://github.com/actions/runner-images/issues/10015
# is resolved in some way.
function disable_apparmor()
{
    # https://bugs.launchpad.net/ubuntu/+source/apparmor/+bug/2093797
    sudo aa-teardown || true
    sudo systemctl disable --now apparmor.service
}

function log() {
    echo "[$(date '+%H:%M:%S')] $*"
}

# ovn_upgrade_save_current_binaries
# Saves current version's binaries and schemas to /tmp/ovn-upgrade-binaries/
function ovn_upgrade_save_current_binaries()
{
    mkdir -p /tmp/ovn-upgrade-binaries

    # New ovn-controller may generate OpenFlow flows with new actions that old
    # OVS doesn't understand, so we need also to use new OVS.
    # New ovs-vswitchd binary expects columns/tables defined in the current
    # schema, so we also need to use new schemas.
    files="controller/ovn-controller ovs/vswitchd/ovs-vswitchd
           ovs/ovsdb/ovsdb-server ovs/utilities/ovs-vsctl
           ovs/utilities/ovs-ofctl ovs/utilities/ovs-appctl
           ovs/utilities/ovs-dpctl ovs/vswitchd/vswitch.ovsschema"
    for file in $files; do
        if [ ! -f "$file" ]; then
            log "ERROR: $file not found"
            return 1
        fi
        cp "$file" /tmp/ovn-upgrade-binaries/
    done

    # In the upgrade scenario we use old ovn-northd and new ovn-controller.
    # OFTABLES are defined through a combination of northd/northd.h and
    # controller/lflow.h. Tests uses either (old) table numbers, table names
    # (defined in ovn-macros) or ovn-debug.
    #
    # Extract OFCTL_* table defines from current lflow.h
    if ! grep '^#define OFTABLE_' controller/lflow.h > \
        /tmp/ovn-upgrade-ofctl-defines.h; then
        log "No #define OFTABLE_ found in lflow.h"
        return 1
    fi

    # Extract OFTABLE m4 defines from current tests/ovn-macros.at
    # These are used by tests to reference table numbers
    # In old tests, there might be no OFTABLE_ in ovn-macros, so grep can fail.
    grep '^m4_define(\[OFTABLE_' tests/ovn-macros.at > \
        /tmp/ovn-upgrade-oftable-m4-defines.txt || true

    # Extract key table numbers for calculating shifts in hardcoded table
    # references. OFTABLE_SAVE_INPORT is where normal (unshifted) tables
    # resume.
    LINE=$(grep "define OFTABLE_LOG_EGRESS_PIPELINE" controller/lflow.h)
    NEW_LOG_EGRESS=$(echo "$LINE" | grep -oE '[0-9]+')
    LINE=$(grep "define OFTABLE_SAVE_INPORT" controller/lflow.h)
    NEW_SAVE_INPORT=$(echo "$LINE" | grep -oE '[0-9]+')
    if [ -z "$NEW_LOG_EGRESS" ]; then
        log "ERROR: Could not extract OFTABLE_LOG_EGRESS_PIPELINE value"
        return 1
    fi
    if [ -z "$NEW_SAVE_INPORT" ]; then
        log "ERROR: Could not extract OFTABLE_SAVE_INPORT value"
        return 1
    fi

    echo "$NEW_LOG_EGRESS" > /tmp/ovn-upgrade-new-log-egress.txt
    echo "$NEW_SAVE_INPORT" > /tmp/ovn-upgrade-new-save-inport.txt

    echo ""
    log "Saved current versions:"
    log " ovn-controller:$(/tmp/ovn-upgrade-binaries/ovn-controller --version |
        grep ovn-controller)"
    log " SB DB schema:$(/tmp/ovn-upgrade-binaries/ovn-controller --version |
        grep "SB DB Schema")"
    log " ovs-vswitchd:$(/tmp/ovn-upgrade-binaries/ovs-vswitchd --version |
        grep vSwitch)"
}

# ovn_upgrade_checkout_base BASE_VERSION LOG_FILE
# Checks out base version from git
function ovn_upgrade_checkout_base()
{
    local base_version=$1
    local log_file=$2

    log "Checking out base version: $base_version"

    # Try to checkout directly first (might already exist locally)
    if git checkout "$base_version" >> "$log_file" 2>&1; then
        log "Using locally available $base_version"
    else
        # Not available locally, try to fetch it
        log "Fetching $base_version from origin..."

        # Try as a tag first
        if git fetch --depth=1 origin tag "$base_version" \
            >> "$log_file" 2>&1; then
            log "Fetched tag $base_version"

        # Try as a branch
        elif git fetch --depth=1 origin "$base_version" \
            >> "$log_file" 2>&1; then
            log "Fetched branch $base_version"

        else
            git fetch origin >> "$log_file" 2>&1 || true
            log "Fetched all refs from origin"
        fi

        # Try checkout
        if git checkout "$base_version" >> "$log_file" 2>&1; then
            log "Using $base_version from origin"
        else
            # origin might be a private repo w/o all branches.
            # Try ovn-org as fallback.
            log "Not in origin, fetching from ovn-org..."
            git fetch https://github.com/ovn-org/ovn.git \
                "$base_version:$base_version" >> "$log_file" 2>&1 || return 1
            log "Fetched $base_version from ovn-org"
            git checkout "$base_version" >> "$log_file" 2>&1 || return 1
        fi
    fi

    git submodule update --init >> "$log_file" 2>&1 || return 1
}

# Patch base version's lflow.h with current OFTABLE table defines
# This ensures ovn-debug uses correct table numbers
function ovn_upgrade_patch_for_ovn_debug()
{
    if [ -f /tmp/ovn-upgrade-ofctl-defines.h ] && \
       [ -f controller/lflow.h ]; then
        # Replace old OFCTL defines with current ones in one pass
        awk '
            !inserted && /^#define OFTABLE_/ {
                system("cat /tmp/ovn-upgrade-ofctl-defines.h")
                inserted = 1
            }
            /^#define OFTABLE_/ { next }
            { print }
        ' controller/lflow.h > controller/lflow.h.tmp

        mv controller/lflow.h.tmp controller/lflow.h
    fi
}

# ovn_upgrade_save_ovn_debug
# Saves ovn-debug binary built with current OFTABLE defines
# This creates a hybrid ovn-debug: current table numbers + base logical flow
# stages
function ovn_upgrade_save_ovn_debug()
{
    log "Saving hybrid ovn-debug..."
    cp utilities/ovn-debug /tmp/ovn-upgrade-binaries/ovn-debug
}

# update_test old_first_table old_last_table shift test_file
# Update test tables in test_file, for old_first <= tables < old_last_table
function update_test()
{
    test_file=$4
    awk -v old_start=$1 \
        -v old_end=$2 \
        -v shift=$3 '
    {
        result = ""
        rest = $0
        # Process all table=NUMBER matches in the line
        while (match(rest, /table *= *[0-9]+/)) {
            # Save match position before calling match() again
            pos = RSTART
            len = RLENGTH

            # Add everything before the match
            result = result substr(rest, 1, pos-1)

            # Extract the matched text and the number
            matched = substr(rest, pos, len)
            if (match(matched, /[0-9]+/)) {
                num = substr(matched, RSTART, RLENGTH)
            } else {
                num = 0
            }

            # Check if this table number needs updating
            if (num >= old_start && num < old_end) {
                result = result "table=" (num + shift)
            } else {
                result = result matched
            }

            # Continue with the rest of the line (use saved pos/len)
            rest = substr(rest, pos + len)
        }
        # Add any remaining text
        print result rest
    }' "$test_file" > "$test_file.tmp" && mv "$test_file.tmp" "$test_file"
}

# ovn_upgrade_table_numbers_in_tests_patch: fix hardcoded table numbers in
# test files
function ovn_upgrade_table_numbers_in_tests_patch()
{
    # Old tests (e.g., branch-24.03) have hardcoded numbers like "table=45"
    # which refer to specific logical tables. When OFTABLE defines shift,
    # these numbers must be updated.
    # Example: v24.03.0 has OFTABLE_LOG_EGRESS_PIPELINE=42, so "table=45"
    # means egress+3.
    # In main, OFTABLE_LOG_EGRESS_PIPELINE=47, so it should become "table=50".
    if [ ! -f /tmp/ovn-upgrade-new-log-egress.txt ] ||
       [ ! -f /tmp/ovn-upgrade-new-save-inport.txt ]; then
        log "WARNING: Table shift data not found, skipping hardcoded table \
             number updates"
        return
    fi

    if [ ! -f controller/lflow.h ]; then
        log "WARNING: controller/lflow.h not found, skipping hardcoded table \
             number updates"
        return
    fi

    NEW_LOG_EGRESS=$(cat /tmp/ovn-upgrade-new-log-egress.txt)
    NEW_SAVE_INPORT=$(cat /tmp/ovn-upgrade-new-save-inport.txt)

    # Get old values from base version's lflow.h (before we patched it)
    LINE=$(grep "#define OFTABLE_LOG_EGRESS_PIPELINE" controller/lflow.h)
    OLD_LOG_EGRESS=$(echo "$LINE" | grep -oE '[0-9]+')
    LINE=$(grep "#define OFTABLE_SAVE_INPORT" controller/lflow.h)
    OLD_SAVE_INPORT=$(echo "$LINE" | grep -oE '[0-9]+')

    if [ -z "$OLD_LOG_EGRESS" ] || [ -z "$OLD_SAVE_INPORT" ] || \
       [ "$OLD_LOG_EGRESS" == "$NEW_LOG_EGRESS" ]; then
       log "No change in tests files as old_log_egress=$OLD_LOG_EGRESS,
            old_save_inport=$OLD_SAVE_INPORT and
            new_log_egress=$NEW_LOG_EGRESS"
       return
    fi

    # Calculate the shift
    SHIFT=$((NEW_LOG_EGRESS - OLD_LOG_EGRESS))

    log "Updating hardcoded table numbers in tests (shift: +$SHIFT for tables \
         $OLD_LOG_EGRESS-$((OLD_SAVE_INPORT-1)))"

    # Update hardcoded table numbers in test files
    for test_file in tests/system-ovn.at tests/system-ovn-kmod.at; do
        if [ -f "$test_file" ]; then
            log "Updating $test_file"
            update_test "$OLD_LOG_EGRESS" "$OLD_SAVE_INPORT" "$SHIFT" \
                        "$test_file"
        fi
    done
}

# ovn_upgrade_cleanup_sbox_patch: filter out expected schema warnings.
function ovn_upgrade_cleanup_sbox_patch()
{
    cat << 'EOF' > /tmp/upgrade-schema-filter.patch
diff --git a/tests/ovn-macros.at b/tests/ovn-macros.at
index a08252d50..a31dc87b4 100644
--- a/tests/ovn-macros.at
+++ b/tests/ovn-macros.at
@@ -98,6 +98,7 @@ m4_define([OVN_CLEANUP_SBOX],[
         $error
         /connection failed (No such file or directory)/d
         /has no network name*/d
+        /OVN_Southbound database lacks/d
         /receive tunnel port not found*/d
         /Failed to locate tunnel to reach main chassis/d
         /Transaction causes multiple rows.*MAC_Binding/d
diff --git a/tests/system-kmod-macros.at b/tests/system-kmod-macros.at
index 6f6670199..4bd1a2c90 100644
--- a/tests/system-kmod-macros.at
+++ b/tests/system-kmod-macros.at
@@ -45,7 +45,8 @@ m4_define([OVS_TRAFFIC_VSWITCHD_START],
 # invoked. They can be used to perform additional cleanups such as name space
 # removal.
 m4_define([OVS_TRAFFIC_VSWITCHD_STOP],
-  [OVS_VSWITCHD_STOP([$1])
+  [OVS_VSWITCHD_STOP([dnl
+$1";/OVN_Southbound database lacks/d"])
    AT_CHECK([:; $2])
   ])

EOF

    # Try to apply schema filter patch. May fail on old OVN versions where
    # OVN_CLEANUP_SBOX doesn't check errors - this is expected and okay.
    # If patch fails for more recent OVN, then the test will fail due to the
    # "OVN_Southbound database lacks".
    patch -p1 < /tmp/upgrade-schema-filter.patch > /dev/null 2>&1 || true
    rm -f /tmp/upgrade-schema-filter.patch
}

# ovn_upgrade_oftable_ovn_macro_patch: update table numbers in ovn-macro
function ovn_upgrade_oftable_ovn_macro_patch()
{
    # Patch base version's tests/ovn-macros.at with current OFTABLE m4 defines
    # This ensures tests use correct table numbers when checking flows
    if [ -f /tmp/ovn-upgrade-oftable-m4-defines.txt ] &&
       [ -f tests/ovn-macros.at ]; then
        # Check if the base version has OFTABLE m4 defines
        if grep -q '^m4_define(\[OFTABLE_' tests/ovn-macros.at; then
            # Replace old m4_define OFTABLE statements with current ones
            awk '
                !inserted && /^m4_define\(\[OFTABLE_/ {
                    system("cat /tmp/ovn-upgrade-oftable-m4-defines.txt")
                    inserted = 1
                }
                /^m4_define\(\[OFTABLE_/ { next }
                { print }
            ' tests/ovn-macros.at > tests/ovn-macros.at.tmp

            mv tests/ovn-macros.at.tmp tests/ovn-macros.at
        fi
    fi
}

# Applies patches to base version after second build:
# 1. Schema error patch (filters "OVN_Southbound database lacks" warnings)
# 2. OFTABLE m4 defines patch in tests/ovn-macros.at (for test table numbers)
# 3. Hardcoded table numbers patch in test files
function ovn_upgrade_apply_tests_patches()
{
    log "Applying schema filter and table number patches..."
    ovn_upgrade_table_numbers_in_tests_patch
    ovn_upgrade_cleanup_sbox_patch
    ovn_upgrade_oftable_ovn_macro_patch
}

# ovn_upgrade_restore_binaries
#
# Replaces base version binaries with saved current versions:
# - ovn-controller (from current)
# - OVS binaries and schema (from current)
# - ovn-debug (hybrid: current OFTABLE + base logical stages)
function ovn_upgrade_restore_binaries()
{
    log "Replacing binaries with current versions"

    # Replace OVN controller
    cp /tmp/ovn-upgrade-binaries/ovn-controller controller/ovn-controller

    # Replace ovn-debug with hybrid version (built with current OFTABLE + base
    # northd.h)
    cp /tmp/ovn-upgrade-binaries/ovn-debug utilities/ovn-debug

    # Replace OVS binaries
    cp /tmp/ovn-upgrade-binaries/ovs-vswitchd ovs/vswitchd/ovs-vswitchd
    cp /tmp/ovn-upgrade-binaries/ovsdb-server ovs/ovsdb/ovsdb-server
    cp /tmp/ovn-upgrade-binaries/ovs-vsctl ovs/utilities/ovs-vsctl
    cp /tmp/ovn-upgrade-binaries/ovs-ofctl ovs/utilities/ovs-ofctl
    cp /tmp/ovn-upgrade-binaries/ovs-appctl ovs/utilities/ovs-appctl
    cp /tmp/ovn-upgrade-binaries/ovs-dpctl ovs/utilities/ovs-dpctl

    # Replace OVS schema (current binaries expect current schema)
    cp /tmp/ovn-upgrade-binaries/vswitch.ovsschema \
       ovs/vswitchd/vswitch.ovsschema

    echo ""
    log "Verification - Current versions (from current patch):"
    log "  ovn-controller: $(controller/ovn-controller --version |
         grep ovn-controller)"
    log "  SB DB Schema: $(controller/ovn-controller --version |
         grep "SB DB Schema")"
    log "  ovs-vswitchd: $(ovs/vswitchd/ovs-vswitchd --version | grep vSwitch)"
    log "Verification - Base versions (for compatibility testing):"
    log "  ovn-northd: $(northd/ovn-northd --version | grep ovn-northd)"
    log "  ovn-nbctl: $(utilities/ovn-nbctl --version | grep ovn-nbctl)"
}
