#!/usr/bin/env python3

# SPDX-License-Identifier: BSD-3-Clause-clear
#
# Python wrapper for make_fitimage.sh
# accepts a kernel dir, .deb, or .rpm.
#
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
#

import argparse, glob, os, re, shutil, subprocess, sys, tempfile

SCRIPT_DIR  = os.path.dirname(os.path.realpath(__file__))
MAKE_FIT    = os.path.join(SCRIPT_DIR, "make_fitimage.sh")
CHECK_META  = os.path.join(SCRIPT_DIR, "check-fitimage-metadata.sh")
DEF_ITS     = os.path.join(SCRIPT_DIR, "qcom-next-fitimage.its")
DEF_META    = os.path.join(SCRIPT_DIR, "qcom-metadata.dts")


def sanity_check(its, metadata):
    """Run check-fitimage-metadata.sh to validate ITS and metadata before building."""
    if not os.path.exists(CHECK_META):
        print("Warning: check-fitimage-metadata.sh not found, skipping sanity check")
        return
    result = subprocess.run([CHECK_META, its, metadata])
    if result.returncode != 0:
        sys.exit(f"Error: ITS/metadata sanity check failed (exit {result.returncode})")


def unpack_deb(path, dest):
    subprocess.run(["dpkg-deb", "-x", path, dest], check=True)


def unpack_rpm(path, dest):
    r = subprocess.Popen(["rpm2cpio", path], stdout=subprocess.PIPE)
    subprocess.run(["cpio", "-idm"], stdin=r.stdout, cwd=dest, check=True)
    r.stdout.close(); r.wait()


def find_kobj(root):
    # Walk unpacked tree to find the dir containing arch/arm64/boot/dts
    for d, _, _ in os.walk(root):
        if os.path.isdir(os.path.join(d, "arch", "arm64", "boot", "dts")):
            return d
    return root  # fallback to unpacked root


# DTB root paths per package type (tried in order, first match wins):
#   deb  1. usr/lib/linux-image-<version>/        ← Debian/standard
#        2. usr/lib/firmware/*/device-tree         ← Ubuntu usrmerge layout
#        3. lib/firmware/*/device-tree             ← Ubuntu legacy layout
#   rpm  1. boot/dtb-<version>/                   ← openSUSE/SLES
#        2. usr/lib/modules/<version>/dtb/         ← Fedora/RHEL
#        3. boot/dtb/                              ← generic fallback
_DTB_ROOT_GLOBS = {
    'deb': ["usr/lib/linux-image-*",
            "usr/lib/firmware/*/device-tree",
            "lib/firmware/*/device-tree"],
    'rpm': ["boot/dtb-*", "usr/lib/modules/*/dtb", "boot/dtb"],
}


def find_dtb_root(unpacked_root, pkg_type):
    """Return the vendor DTB tree root inside an unpacked package, or None."""
    for pattern in _DTB_ROOT_GLOBS.get(pkg_type, []):
        for m in glob.glob(os.path.join(unpacked_root, pattern)):
            if os.path.isdir(m):
                return m
    return None


def find_all_dtb_files(dtb_root):
    """Return all DTB/DTBO files in qcom subdirectories under dtb_root."""
    return [os.path.join(d, f)
            for d, _, files in os.walk(dtb_root)
            if 'qcom' in d.split(os.sep)
            for f in files if f.endswith(('.dtb', '.dtbo'))]


def reorganize_dtb_files(unpacked_root, its_file, pkg_type='deb'):
    """Reorganize DTB/DTBO files from a package to match ITS file expectations.
    Creates a temporary kobj-like structure and returns its path.
    """
    dtb_root = find_dtb_root(unpacked_root, pkg_type)
    if dtb_root:
        print(f"Using {pkg_type} DTB path: {os.path.relpath(dtb_root, unpacked_root)}")
    else:
        print(f"Warning: standard {pkg_type} DTB path not found, falling back to full tree search")
        dtb_root = unpacked_root

    # Extract expected DTB paths from ITS file
    its_content = open(its_file).read()
    expected_paths = re.findall(r'/incbin/\("(\./[^"]+)"\)', its_content)

    # Filter out qcom-metadata.dtb (generated at build time)
    expected_paths = [p for p in expected_paths if os.path.basename(p) != "qcom-metadata.dtb"]

    if not expected_paths:
        print("No DTB files referenced in ITS file")
        return unpacked_root

    # Find all DTB files under the package-specific DTB root
    found_dtbs = find_all_dtb_files(dtb_root)

    if not found_dtbs:
        sys.exit("Error: No DTB/DTBO files found in qcom directories")

    print(f"Found {len(found_dtbs)} DTB/DTBO files in qcom directories")

    # Create a reorganized directory structure
    reorg_dir = tempfile.mkdtemp(prefix="fit_reorg_")

    # Build a mapping of expected filenames to their expected paths
    expected_map = {}
    for exp_path in expected_paths:
        filename = os.path.basename(exp_path)
        # Store the relative path from kobj root (strip leading ./)
        expected_map[filename] = exp_path.lstrip("./")

    # Copy found DTB files to their expected locations
    copied_count = 0
    missing_files = []

    for filename, expected_rel_path in expected_map.items():
        # Find this file in the found DTBs
        found = False
        for dtb_path in found_dtbs:
            if os.path.basename(dtb_path) == filename:
                # Create the expected directory structure
                target_path = os.path.join(reorg_dir, expected_rel_path)
                target_dir = os.path.dirname(target_path)
                os.makedirs(target_dir, exist_ok=True)

                # Copy the DTB file
                shutil.copy2(dtb_path, target_path)
                print(f"  Mapped: {filename} -> {expected_rel_path}")
                copied_count += 1
                found = True
                break

        if not found:
            missing_files.append(filename)

    if missing_files:
        print(f"Error: {len(missing_files)} DTB/DTBO file(s) not found in package:")
        for mf in missing_files:
            print(f"  missing: {mf}")
        sys.exit(1)

    if copied_count == 0:
        print("Error: No DTB files could be mapped from package to ITS expectations")
        shutil.rmtree(reorg_dir, ignore_errors=True)
        return unpacked_root

    print(f"Successfully reorganized {copied_count}/{len(expected_map)} DTB/DTBO files")
    return reorg_dir


def check_dtb_files(its_file, kobj):
    # Extract all /incbin/ paths from the ITS file and verify they exist under kobj
    paths = re.findall(r'/incbin/\("(\./[^"]+)"\)', open(its_file).read())
    missing = []
    for rel in paths:
        # qcom-metadata.dtb is generated at build time — skip it
        if os.path.basename(rel) == "qcom-metadata.dtb":
            continue
        if not os.path.exists(os.path.join(kobj, rel.lstrip("./"))) and \
           not os.path.exists(os.path.join(kobj, rel)):
            missing.append(rel)
    if missing:
        print(f"Error: {len(missing)} DTB/DTBO file(s) referenced in ITS not found in kobj:")
        for m in missing:
            print(f"  missing: {m}")
        sys.exit(1)
    else:
        print(f"OK: all DTB/DTBO files referenced in {os.path.basename(its_file)} found in kobj")
    return missing


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("kernel", help="kernel build dir, .deb, or .rpm")
    p.add_argument("--its",      default=DEF_ITS,  help="ITS file (default: qcom-next-fitimage.its)")
    p.add_argument("--metadata", default=DEF_META,  help="metadata DTS (default: qcom-metadata.dts)")
    p.add_argument("--output",   default="../images", help="output dir (default: ../images)")
    args = p.parse_args()

    kernel   = os.path.realpath(args.kernel)
    its      = os.path.realpath(args.its)
    metadata = os.path.realpath(args.metadata)
    output   = os.path.realpath(args.output)

    for label, path in [("kernel", kernel), ("ITS", its), ("metadata", metadata), ("make_fitimage.sh", MAKE_FIT)]:
        if not os.path.exists(path):
            sys.exit(f"Error: {label} not found: {path}")

    sanity_check(its, metadata)

    tmpdir = None
    reorg_dir = None
    try:
        if os.path.isdir(kernel):
            kobj = kernel
        elif kernel.endswith(".deb"):
            tmpdir = tempfile.mkdtemp(prefix="fit_deb_")
            unpack_deb(kernel, tmpdir)
            kobj = find_kobj(tmpdir)
            # If kobj doesn't have proper structure, reorganize DTB files
            if not os.path.isdir(os.path.join(kobj, "arch", "arm64", "boot", "dts")):
                print("Standard kernel structure not found, reorganizing DTB files from package-specific path...")
                reorg_dir = reorganize_dtb_files(tmpdir, its, pkg_type='deb')
                kobj = reorg_dir
        elif kernel.endswith(".rpm"):
            tmpdir = tempfile.mkdtemp(prefix="fit_rpm_")
            unpack_rpm(kernel, tmpdir)
            kobj = find_kobj(tmpdir)
            # If kobj doesn't have proper structure, reorganize DTB files
            if not os.path.isdir(os.path.join(kobj, "arch", "arm64", "boot", "dts")):
                print("Standard kernel structure not found, reorganizing DTB files from package-specific path...")
                reorg_dir = reorganize_dtb_files(tmpdir, its, pkg_type='rpm')
                kobj = reorg_dir
        else:
            sys.exit(f"Error: expected a directory, .deb, or .rpm — got: {kernel}")

        check_dtb_files(its, kobj)

        subprocess.run(
            [MAKE_FIT, "--kobj", kobj, "--metadata", metadata, "--its", its, "--output", output],
            check=True,
        )

        fit = os.path.join(output, "fit_dtb.bin")
        print(f"\nFIT image: {fit}" if os.path.exists(fit) else f"\nWarning: {fit} not found")

    finally:
        if tmpdir:
            shutil.rmtree(tmpdir, ignore_errors=True)
        if reorg_dir:
            shutil.rmtree(reorg_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
