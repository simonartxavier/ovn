#!/usr/bin/env python3

import os
import re
import shutil
import subprocess
from datetime import datetime
from pathlib import Path


def log(message):
    timestamp = datetime.now().strftime("%H:%M:%S")
    print(f"[{timestamp}] {message}", flush=True)


def run_command(cmd):
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    return result.returncode == 0, result.stdout, result.stderr


def run_shell_command(cmd, log_file=None):
    if log_file:
        with open(log_file, 'a', encoding='utf-8') as f:
            result = subprocess.run(["bash", "-c", cmd], stdout=f,
                                    stderr=subprocess.STDOUT, check=False)
    else:
        result = subprocess.run(["bash", "-c", cmd], check=False)
    return result.returncode == 0


def extract_oftable_values(content):
    match = re.search(r'^#define\s+OFTABLE_LOG_EGRESS_PIPELINE\s+(\d+)',
                      content, re.MULTILINE)
    log_egress = int(match.group(1)) if match else None
    match = re.search(r'^#define\s+OFTABLE_SAVE_INPORT\s+(\d+)',
                      content, re.MULTILINE)
    save_inport = int(match.group(1)) if match else None
    return log_egress, save_inport


def replace_block_in_file(target_file, src_file, line_prefix):
    if not target_file.exists():
        return False
    if not src_file.exists():
        # No src_file file means nothing to replace.
        return True
    with open(target_file, encoding='utf-8') as f:
        lines = f.readlines()
    with open(src_file, encoding='utf-8') as f:
        new_content = f.read()

    # Replace all lines starting with line_prefix with new_content.
    output_lines = []
    inserted = False

    for line in lines:
        if line.startswith(line_prefix):
            if not inserted:
                output_lines.append(new_content)
                inserted = True
            # Skip old lines with this prefix
            continue
        output_lines.append(line)

    with open(target_file, 'w', encoding='utf-8') as f:
        f.writelines(output_lines)

    return True


def ovn_upgrade_build(log_file):
    use_sparse = "yes" if shutil.which("sparse") else "no"
    cc = os.environ.get('CC', 'gcc')
    opts = os.environ.get('OPTS', '')
    log(f"Rebuilding OVN with {cc}")

    build_script = f"""
        set -e
        export USE_SPARSE={use_sparse}
        export CC={cc}
        export OPTS={opts}
        make $JOBS
    """
    return run_shell_command(build_script, log_file)


def ovs_ovn_upgrade_build(log_file):
    use_sparse = "yes" if shutil.which("sparse") else "no"
    cc = os.environ.get('CC', 'gcc')
    opts = os.environ.get('OPTS', '')
    log(f"Building OVS and OVN with {cc}")
    build_script = f"""
        set -e
        export USE_SPARSE={use_sparse}
        export CC={cc}
        export OPTS={opts}
        . .ci/linux-build.sh
    """
    return run_shell_command(build_script, log_file)


def log_binary_version(binary_path, keywords):
    success, stdout, _ = run_command([binary_path, "--version"])
    if success:
        for line in stdout.splitlines():
            if any(kw in line for kw in keywords):
                log(f"  {line}")


def ovn_upgrade_save_current_binaries(binaries_dir):

    files = [
        "controller/ovn-controller",
        "ovs/vswitchd/ovs-vswitchd",
        "ovs/ovsdb/ovsdb-server",
        "ovs/utilities/ovs-vsctl",
        "ovs/utilities/ovs-ofctl",
        "ovs/utilities/ovs-appctl",
        "ovs/utilities/ovs-dpctl",
        "ovs/vswitchd/vswitch.ovsschema"
    ]

    for file in files:
        try:
            shutil.copy(Path(file), binaries_dir)
        except Exception as e:
            log(f"Failed to copy {file}: {e}")
            return False

    log("Saved current versions:")
    log_binary_version(str(binaries_dir / "ovn-controller"),
                       ['ovn-controller', 'SB DB Schema'])
    log_binary_version(str(binaries_dir / "ovs-vswitchd"), ['vSwitch'])
    return True


def ovn_upgrade_extract_info(upgrade_dir):
    lflow_h = Path("controller/lflow.h")
    if not lflow_h.exists():
        log("controller/lflow.h not found")
        return False

    # Get all ofctl defines from lflow.h.
    with open(lflow_h, encoding='utf-8') as f:
        oftable_defines = [
            line.strip() for line in f if line.startswith('#define OFTABLE_')
        ]

        if not oftable_defines:
            log("No #define OFTABLE_ found in lflow.h")
            return False

        output_file = upgrade_dir / "ovn-upgrade-ofctl-defines.h"
        with open(output_file, 'w', encoding='utf-8') as of:
            of.write('\n'.join(oftable_defines) + '\n')
        log(f"  Wrote {output_file}")

    # Get all m4_define([OFTABLE_ from ovn-macros.at.
    macros_file = Path("tests/ovn-macros.at")
    output_file = upgrade_dir / "ovn-upgrade-oftable-m4-defines.txt"
    if macros_file.exists():
        with open(macros_file, encoding='utf-8') as f:
            m4_defines = [
                line.strip() for line in f
                if line.startswith('m4_define([OFTABLE_')
            ]

            with open(output_file, 'w', encoding='utf-8') as of:
                of.write('\n'.join(m4_defines) + '\n' if m4_defines else '')
            log(f"  Wrote {output_file}")

    # Get value of OFTABLE_LOG_EGRESS_PIPELINE.
    with open(lflow_h, encoding='utf-8') as f:
        content = f.read()
    new_log_egress, _ = extract_oftable_values(content)

    if not new_log_egress:
        log("Could not extract OFTABLE_LOG_EGRESS_PIPELINE value")
        return False

    output_file = upgrade_dir / "ovn-upgrade-new-log-egress.txt"
    with open(output_file, 'w', encoding='utf-8') as f:
        f.write(str(new_log_egress) + '\n')
    log(f"  Wrote {output_file}")

    return True


def ovn_upgrade_checkout_local(base_version, base_dir, log_file_str):
    original_dir = os.getcwd()
    log(f"Running locally. Cloning from {original_dir} to {base_dir}")

    success, _, stderr = run_command([
        "git", "clone", "--local", "--shared", ".", str(base_dir),
        "--branch", base_version
    ])
    if not success:
        log(f"Failed to clone to {base_dir}")
        log(stderr)
        return False

    try:
        os.chdir(base_dir)
        log(f"Checking out base version: {base_version} from {base_dir}")
        success, stdout, stderr = run_command(["git", "checkout",
                                               base_version])
        with open(log_file_str, 'a', encoding='utf-8') as f:
            f.write(stdout + stderr)

        if not success:
            log(f"Failed to checkout {base_version}")
            log(stderr)
            return False

        return True

    finally:
        os.chdir(original_dir)


def ovn_upgrade_clone_github(base_version, base_dir, log_file_str):
    original_dir = os.getcwd()
    success, origin_url, _ = run_command(["git", "config", "--get",
                                          "remote.origin.url"])
    if not success or not origin_url.strip():
        log("Could not get origin URL from working directory")
        return False

    try:
        origin_url = origin_url.strip()
        os.chdir(base_dir)
        log(f"Cloning {base_version} from {origin_url} ")
        success, stdout, stderr = run_command([
            'git', 'clone', origin_url, base_dir, '--branch',
            base_version, '--depth', '1', '--no-tags'
        ])
        with open(log_file_str, 'a', encoding='utf-8') as f:
            f.write(stdout + stderr)

        if not success and origin_url != "https://github.com/ovn-org/ovn":
            log(f"Not found in {origin_url}, trying ovn-org...")
            success, stdout, stderr = run_command([
                'git', 'clone', "https://github.com/ovn-org/ovn.git", base_dir,
                '--branch', base_version, '--depth', '1', '--no-tags'
            ])
            with open(log_file_str, 'a', encoding='utf-8') as f:
                f.write(stdout + stderr)

        if not success:
            log(f"Failed to clone {base_version}")
            log(stderr)
            return False
    finally:
        os.chdir(original_dir)
    return success


def ovn_upgrade_checkout_base(base_version, upgrade_dir, base_dir):
    is_local = True
    if base_version.startswith("origin/"):
        base_version = base_version.split('/', 1)[-1]
        is_local = False

    success = False
    log_file = upgrade_dir / "git.log"
    if log_file.exists():
        log_file.unlink()
    log_file_str = str(log_file)

    if is_local:
        success = ovn_upgrade_checkout_local(base_version, base_dir,
                                             log_file_str)

    if not success:
        # Branch not requested or found in local repo.
        # Get working directory's origin URL (the real remote, e.g., GitHub)
        success = ovn_upgrade_clone_github(base_version, base_dir,
                                           log_file_str)

    if not success:
        log(f"Failed to fetch/checkout {base_version}")
        return False

    os.chdir(base_dir)
    success, stdout, stderr = run_command(["git", "checkout", base_version])
    with open(log_file_str, 'a', encoding='utf-8') as f:
        f.write(stdout + stderr)

    if not success:
        log(f"Failed to checkout {base_version}")
        log(stderr)
        return False

    log(f"Checked out {base_version}")

    log("Updating OVS submodule...")
    success, stdout, stderr = run_command(["git", "submodule", "update",
                                           "--init", "--depth", "1"])
    with open(log_file_str, 'a', encoding='utf-8') as f:
        f.write(stdout + stderr)

    if not success:
        log(f"Failed to update submodules: {stderr}")
        return False

    return True


def ovn_upgrade_patch_for_ovn_debug(upgrade_dir):
    return replace_block_in_file(
        Path("controller/lflow.h"),
        upgrade_dir / "ovn-upgrade-ofctl-defines.h",
        '#define OFTABLE_')


def ovn_upgrade_save_ovn_debug(binaries_dir):
    log("Saving hybrid ovn-debug...")
    src = Path("utilities/ovn-debug")
    dst = binaries_dir / "ovn-debug"

    try:
        shutil.copy(src, dst)
    except Exception as e:
        log(f"Failed to save ovn-debug: {e}")
        return False

    return True


def update_test(old_start, old_end, shift, test_file):
    with open(test_file, encoding='utf-8') as f:
        content = f.read()

    def replace_table(match):
        table_num = int(match.group(1))
        if old_start <= table_num < old_end:
            return f"table={table_num + shift}"
        return match.group(0)

    # Replace all table=NUMBER patterns
    updated_content = re.sub(r'table\s*=\s*(\d+)', replace_table, content)

    with open(test_file, 'w', encoding='utf-8') as f:
        f.write(updated_content)


def ovn_upgrade_table_numbers_in_tests_patch(upgrade_dir):
    new_log_egress_file = upgrade_dir / "ovn-upgrade-new-log-egress.txt"
    lflow_h = Path("controller/lflow.h")

    if not new_log_egress_file.exists():
        log("No LOG_EGRESS")
        return False

    if not lflow_h.exists():
        log("Controller/lflow.h not found")
        return False

    with open(new_log_egress_file, encoding='utf-8') as f:
        new_log_egress = int(f.read().strip())

    # Get old values from base version's lflow.h
    with open(lflow_h, encoding='utf-8') as f:
        content = f.read()

    old_log_egress, old_save_inport = extract_oftable_values(content)

    if (not old_log_egress or not old_save_inport
            or old_log_egress == new_log_egress):
        log(f"No change in test files as old_log_egress={old_log_egress}, "
            f"old_save_inport={old_save_inport} and "
            f"new_log_egress={new_log_egress}")
        # No change needed is success.
        return True

    shift = new_log_egress - old_log_egress

    log(f"Updating hardcoded table numbers in tests (shift: +{shift} for "
        f"tables {old_log_egress}-{old_save_inport - 1})")

    # Update test files
    for test_file in ["tests/system-ovn.at", "tests/system-ovn-kmod.at"
                      "tests/system-ovn-netlink.at"]:
        if Path(test_file).exists():
            log(f"Updating {test_file}")
            update_test(old_log_egress, old_save_inport, shift, test_file)
    return True


def ovn_upgrade_schema_in_macros_patch():
    schema_filter = '/OVN_Southbound database lacks/d'
    ovn_pattern = r'/has no network name\*/d'

    macros_file = Path("tests/ovn-macros.at")
    if macros_file.exists():
        with open(macros_file, encoding='utf-8') as f:
            content = f.read()

        if schema_filter not in content:
            if re.search(ovn_pattern, content):
                content = re.sub(f'({ovn_pattern})',
                                 rf'\1\n{schema_filter}', content, count=1)
                with open(macros_file, 'w', encoding='utf-8') as f:
                    f.write(content)
                log("Added schema warning filter to ovn-macros.at")
            else:
                log("Could not find pattern in ovn-macros.at")
        else:
            log("Schema already updated in macro")
    else:
        log("tests/ovn-macros.at not found")
        return False

    kmod_file = Path("tests/system-kmod-macros.at")
    if kmod_file.exists():
        with open(kmod_file, encoding='utf-8') as f:
            content = f.read()

        if schema_filter not in content:
            ovs_pattern = r'\[OVS_VSWITCHD_STOP\(\[\$1\]\)'

            if re.search(ovs_pattern, content):
                content = re.sub(
                    ovs_pattern,
                    rf'[OVS_VSWITCHD_STOP([dnl\n$1";{schema_filter}"])',
                    content, count=1)
                with open(kmod_file, 'w', encoding='utf-8') as f:
                    f.write(content)
                log("Added schema warning filter to system-kmod-macros.at")
            else:
                log("Could not find pattern in system-kmod-macros.at")
                return False

    return True


def ovn_upgrade_oftable_ovn_macro_patch(upgrade_dir):
    return replace_block_in_file(
        Path("tests/ovn-macros.at"),
        upgrade_dir / "ovn-upgrade-oftable-m4-defines.txt",
        'm4_define([OFTABLE_')


def ovn_upgrade_apply_tests_patches(upgrade_dir):
    log("Applying schema filter and table number patches...")
    if not ovn_upgrade_table_numbers_in_tests_patch(upgrade_dir):
        return False
    if not ovn_upgrade_schema_in_macros_patch():
        return False
    if not ovn_upgrade_oftable_ovn_macro_patch(upgrade_dir):
        return False
    return True


def ovn_upgrade_restore_binaries(binaries_dir):
    log("Replacing binaries with current versions")

    binaries = [
        ("ovn-controller", "controller/ovn-controller"),
        ("ovn-debug", "utilities/ovn-debug"),
        ("ovs-vswitchd", "ovs/vswitchd/ovs-vswitchd"),
        ("ovsdb-server", "ovs/ovsdb/ovsdb-server"),
        ("ovs-vsctl", "ovs/utilities/ovs-vsctl"),
        ("ovs-ofctl", "ovs/utilities/ovs-ofctl"),
        ("ovs-appctl", "ovs/utilities/ovs-appctl"),
        ("ovs-dpctl", "ovs/utilities/ovs-dpctl"),
        ("vswitch.ovsschema", "ovs/vswitchd/vswitch.ovsschema"),
    ]

    for src_name, dest_path in binaries:
        src = binaries_dir / src_name
        dest = Path(dest_path)
        try:
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(src, dest)
        except Exception as e:
            log(f"Failed to copy {src_name} to {dest}: {e}")
            return False

    log("Current versions (from current patch):")
    log_binary_version("controller/ovn-controller",
                       ['ovn-controller', 'SB DB Schema'])
    log_binary_version("ovs/vswitchd/ovs-vswitchd", ['vSwitch'])

    log("Base versions (for compatibility testing):")
    log_binary_version("northd/ovn-northd", ['ovn-northd'])
    log_binary_version("utilities/ovn-nbctl", ['ovn-nbctl'])

    return True


def run_upgrade_workflow(base_version, base_dir, upgrade_dir, binaries_dir):
    original_dir = Path.cwd()

    try:
        if not ovn_upgrade_checkout_base(base_version, upgrade_dir, base_dir):
            log("Failed to checkout base version")
            return False

        if not ovn_upgrade_apply_tests_patches(upgrade_dir):
            log("Failed to apply test patches")
            return False

        log("Patching lflow.h with current OFTABLE defines...")
        ovn_upgrade_patch_for_ovn_debug(upgrade_dir)

        # Build base version with patched lflow.h
        log(f"Building base version (with patched lflow.h) from {Path.cwd()}")
        if not ovs_ovn_upgrade_build(str(upgrade_dir / "build-base.log")):
            log("Failed to build base version")
            log(f"See config.log and {upgrade_dir}/build-base.log")
            return False

        # Refresh sudo timestamp after long build
        run_command(["sudo", "-v"])

        if not ovn_upgrade_save_ovn_debug(binaries_dir):
            return False

        # Rebuild with original lflow.h
        log("Restoring lflow.h to original...")
        run_command(["git", "checkout", "controller/lflow.h"])

        log("Rebuilding base version (clean lflow.h)...")
        if not ovn_upgrade_build(str(upgrade_dir / "build-base.log")):
            log("Failed to rebuild base version")
            log(f"See {upgrade_dir}/build-base.log")
            return False

        if not ovn_upgrade_restore_binaries(binaries_dir):
            return False

        return True

    finally:
        os.chdir(original_dir)


def remove_upgrade_test_directory(upgrade_dir, base_dir):
    if upgrade_dir.exists():
        if base_dir.exists():
            test_dir = base_dir / "tests" / "system-kmod-testsuite.dir"
            test_log = base_dir / "tests" / "system-kmod-testsuite.log"

            if test_dir.exists():
                run_command(["sudo", "rm", "-rf", str(test_dir)])
            if test_log.exists():
                run_command(["sudo", "rm", "-f", str(test_log)])

        try:
            shutil.rmtree(upgrade_dir)
            return True
        except OSError as e:
            log(f"Failed to remove {upgrade_dir}: {e}")
            return False
    return True
