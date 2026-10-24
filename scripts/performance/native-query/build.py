#!/usr/bin/env python3
"""Freeze and build disposable actual-source query hosts. Never launches an app."""
import argparse
import datetime
import hashlib
import json
import os
import pathlib
import platform
import plistlib
import shutil
import subprocess
import sys
import tempfile
import uuid

HERE = pathlib.Path(__file__).resolve().parent
DEFAULT_BASELINE = "8dec99c87f77436eefc50f0615abbf3855186e83"
INPUT_ROOTS = ("Sources", "Resources", "Info.plist", "VERSION")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args])


def revision(repo, ref):
    return git(repo, "rev-parse", "--verify", ref + "^{commit}").decode().strip()


def relative_path(name):
    path = pathlib.PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts or not path.parts or path.parts[0] not in INPUT_ROOTS:
        raise ValueError("Unexpected snapshot input: " + name)
    if path.parts[:2] == ("Resources", "Recovered"):
        raise ValueError("Extracted third-party resources are not permitted: " + name)
    return path


def write_snapshot(destination, files):
    for name, data in files.items():
        path = destination / relative_path(name)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    for required in ("Info.plist", "VERSION", "Sources/BrowserController.swift"):
        if required not in files:
            raise ValueError("Snapshot is missing " + required)


def commit_files(repo, commit):
    files = {}
    listing = git(repo, "ls-tree", "-rz", "--full-tree", commit, "--", *INPUT_ROOTS)
    for record in listing.split(b"\0"):
        if not record:
            continue
        meta, raw_name = record.split(b"\t", 1)
        mode, kind, object_id = meta.split()
        name = os.fsdecode(raw_name)
        relative_path(name)
        if kind != b"blob" or mode not in (b"100644", b"100755"):
            raise ValueError("Snapshot requires regular source/resource files: " + name)
        files[name] = git(repo, "cat-file", "blob", object_id.decode())
    return files


def working_files(repo):
    # Restrict reads to source/resource inputs; never copy repository metadata,
    # app bundles, browser profiles, generated results or ignored resources.
    names = git(repo, "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", *INPUT_ROOTS)
    files = {}
    for raw_name in sorted(set(names.split(b"\0")) - {b""}):
        name = os.fsdecode(raw_name)
        path = repo / relative_path(name)
        relative = pathlib.PurePosixPath(name)
        if any((repo.joinpath(*relative.parts[:i])).is_symlink() for i in range(1, len(relative.parts) + 1)):
            raise ValueError("Working snapshot refuses symlinks: " + name)
        if not path.exists():  # A tracked deletion is part of the working state.
            continue
        if not path.is_file():
            raise ValueError("Working snapshot requires a regular file: " + name)
        files[name] = path.read_bytes()
    return files


def hashes(root):
    return {path.relative_to(root).as_posix(): digest(path)
            for path in sorted(root.rglob("*")) if path.is_file()}


def save(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=pathlib.Path, default=HERE.parents[2], help="Bam Git repository (default: this checkout)")
    parser.add_argument("--baseline-ref", default=DEFAULT_BASELINE, help="Explicit baseline commit/ref; default is the recorded original baseline")
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument("--candidate-ref", help="Candidate commit/ref; defaults to HEAD")
    selection.add_argument("--working-tree", action="store_true", help="Freeze tracked and nonignored source/resource files, including uncommitted edits")
    parser.add_argument("--output-dir", type=pathlib.Path, help="New directory for frozen sources, manifests, logs and apps; default: new system temporary directory")
    parser.add_argument("--arch", choices=("arm64", "x86_64"), default=platform.machine())
    parser.add_argument("--prepare-only", action="store_true", help="Freeze all inputs and manifests without invoking the compiler")
    args = parser.parse_args()
    repo = args.repo.resolve()
    experiment = json.loads((HERE / "experiment.json").read_text())
    entry_bytes = (HERE / "QueryMain.swift").read_bytes()
    fixture_bytes = {name: (HERE / "fixture" / name).read_bytes() for name in experiment["fixture_sha256"]}
    if hashlib.sha256(entry_bytes).hexdigest() != experiment["entry_sha256"]:
        raise ValueError("Harness entry differs from experiment.json")
    for name, expected in experiment["fixture_sha256"].items():
        if hashlib.sha256(fixture_bytes[name]).hexdigest() != expected:
            raise ValueError("Fixture differs from experiment.json: " + name)
    baseline = revision(repo, args.baseline_ref)
    candidate = revision(repo, args.candidate_ref or "HEAD")
    if not args.prepare_only and sys.platform != "darwin":
        parser.error("Native builds require macOS with the current WebKit SDK and Swift compiler")
    if args.output_dir:
        root = args.output_dir.resolve()
        root.mkdir(parents=True, exist_ok=False)
    else:
        root = pathlib.Path(tempfile.mkdtemp(prefix="bam-native-query-")).resolve()
    build_id = uuid.uuid4().hex[:12]
    common = {"experiment": "original-extension-query-v1", "created_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "baseline_revision": baseline, "candidate_base_revision": candidate,
              "candidate_mode": "working-tree" if args.working_tree else "commit", "architecture": args.arch,
              "entry_sha256": experiment["entry_sha256"], "fixture_sha256": experiment["fixture_sha256"],
              "driver_sha256": digest(HERE / "build.py"), "experiment_metadata_sha256": digest(HERE / "experiment.json"),
              "launch_performed": False, "variants": {}}
    save(root / "build-manifest.json", common)
    for label, commit in (("before", baseline), ("after", candidate)):
        source = root / "inputs" / label
        files = working_files(repo) if label == "after" and args.working_tree else commit_files(repo, commit)
        if label == "after" and args.working_tree:
            if files != working_files(repo) or candidate != revision(repo, "HEAD"):
                raise RuntimeError("Working source changed during capture; retry after edits stop")
        write_snapshot(source, files)
        (source / "QueryMain.swift").write_bytes(entry_bytes)
        variant = {"revision": commit, "source_kind": "working-tree" if label == "after" and args.working_tree else "commit",
                   "source_root": str(source), "frozen_input_sha256": hashes(source), "status": "prepared"}
        common["variants"][label] = variant
        save(root / "build-manifest.json", common)
    fixture = root / "inputs" / "QueryFixture"
    fixture.mkdir()
    for name, data in fixture_bytes.items():
        (fixture / name).write_bytes(data)
    common["frozen_fixture_sha256"] = hashes(fixture)
    save(root / "build-manifest.json", common)
    if args.prepare_only:
        print(json.dumps({"root": str(root), "status": "prepared", "launched": False}))
        return
    swift = subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    common["compiler_version"] = subprocess.check_output([swift, "--version"], text=True).strip()
    common["sdk_path"] = sdk
    # Same local CLT duplicate-module workaround as the normal Bam build.
    (root / "empty.modulemap").write_text("// Legacy duplicate module-map workaround, scoped to this build.\n")
    overlay = {"version": 0, "case-sensitive": "true", "roots": [{"type": "file", "name": "/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap", "external-contents": str(root / "empty.modulemap")}]}
    save(root / "overlay.json", overlay)
    for label in ("before", "after"):
        variant = common["variants"][label]
        source = pathlib.Path(variant["source_root"])
        if hashes(source) != variant["frozen_input_sha256"] or hashes(fixture) != common["frozen_fixture_sha256"]:
            raise RuntimeError("Frozen build inputs changed")
        app = root / ("Bam Native Query " + label + ".app")
        contents = app / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        shutil.copytree(source / "Resources", contents / "Resources")
        shutil.copytree(fixture, contents / "Resources" / "QueryFixture")
        info = plistlib.loads((source / "Info.plist").read_bytes())
        info.update(CFBundleIdentifier="com.ari.bam.native-query-" + label + ".build" + build_id,
                    CFBundleName="Bam Native Query " + label, CFBundleDisplayName="Bam Native Query " + label,
                    CFBundleExecutable="BamQuery")
        info.pop("CFBundleURLTypes", None)
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
        sources = sorted(path for path in (source / "Sources").glob("*.swift") if path.name != "App.swift") + [source / "QueryMain.swift"]
        binary = contents / "MacOS" / "BamQuery"
        command = [swift, "-O", "-parse-as-library", "-swift-version", "5", "-sdk", sdk, "-target", args.arch + "-apple-macosx14.0",
                   "-module-cache-path", str(root / "module-cache"), "-vfsoverlay", str(root / "overlay.json"),
                   "-Xcc", "-ivfsoverlay", "-Xcc", str(root / "overlay.json"),
                   "-framework", "AppKit", "-framework", "WebKit", "-framework", "QuartzCore"]
        command += [str(path) for path in sources] + ["-o", str(binary)]
        variant.update(status="compiling", app=str(app), binary=str(binary), compile_argv=command,
                       compiled_sources=[path.relative_to(source).as_posix() for path in sources])
        save(root / "build-manifest.json", common)
        with (root / (label + "-build.log")).open("w") as log:
            result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
            variant["compile_exit_code"] = result.returncode
            variant["status"] = "compiled" if result.returncode == 0 else "compile_failed"
            save(root / "build-manifest.json", common)
            if result.returncode:
                raise RuntimeError(f"{label} compile failed; retained log: {root / (label + '-build.log')}")
            for sign_command in (["codesign", "--force", "--sign", "-", "--timestamp=none", str(app)],
                                 ["codesign", "--verify", "--strict", str(app)]):
                signed = subprocess.run(sign_command, stdout=log, stderr=subprocess.STDOUT)
                if signed.returncode:
                    variant["status"] = "signing_failed"
                    save(root / "build-manifest.json", common)
                    raise RuntimeError("Signing failed; retained build log: " + str(root / (label + "-build.log")))
        variant.update(status="built", binary_sha256=digest(binary), signature_verified=True)
        save(root / "build-manifest.json", common)
        print(json.dumps({"built": label, "app": str(app), "binary": str(binary), "binary_sha256": variant["binary_sha256"]}), flush=True)
    print(json.dumps({"root": str(root), "manifest": str(root / "build-manifest.json"), "launched": False}), flush=True)


if __name__ == "__main__":
    main()
