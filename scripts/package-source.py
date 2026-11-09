#!/usr/bin/env python3
"""Package the working source tree, including initialized Git submodules.

Uses Git's tracked and nonignored untracked file lists so local pending changes
are included while build output and repository metadata are not. No symlinks
are dereferenced. Run from any directory after installing under scripts/.
"""
import argparse
import gzip
import hashlib
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
EXCLUDED_COMPONENTS = {".git", ".build", "dist"}
LOCAL_PRIVATE_COMPONENTS = {".aws", ".ssh", ".gnupg", ".azure", ".codex", ".config"}
LOCAL_PRIVATE_NAMES = {".netrc", ".npmrc", ".pypirc", "id_rsa", "id_ed25519"}


def git_output(repository, *arguments):
    return subprocess.check_output(["git", "-C", str(repository), *arguments])


def git_paths(repository, *arguments):
    data = git_output(repository, "ls-files", *arguments, "-z")
    return {os.fsdecode(name) for name in data.split(b"\0") if name}


def safe_path(name):
    path = PurePosixPath(name)
    if path.is_absolute() or any(part in ("", ".", "..") for part in path.parts):
        raise ValueError("Unsafe repository path: " + repr(name))
    return path


def excluded(path, untracked):
    if any(part in EXCLUDED_COMPONENTS for part in path.parts):
        return True
    if not untracked:
        return False
    # Local credential files should never enter a release just because they
    # were not yet added to .gitignore. Tracked project files remain explicit.
    return (any(part in LOCAL_PRIVATE_COMPONENTS for part in path.parts)
            or path.name in LOCAL_PRIVATE_NAMES
            or path.name == ".env" or path.name.startswith(".env.")
            or path.suffix.lower() in {".key", ".pem", ".p12", ".pfx"})


def collect_files(repository, prefix=PurePosixPath("."), visited=None):
    if visited is None:
        visited = set()
    repository = repository.resolve()
    if repository in visited:
        raise ValueError("Recursive submodule path: " + str(repository))
    visited.add(repository)
    try:
        top_level = Path(os.fsdecode(git_output(repository, "rev-parse", "--show-toplevel")).strip()).resolve()
    except subprocess.CalledProcessError as error:
        raise ValueError("Missing Git source tree: " + str(repository)) from error
    if top_level != repository:
        raise ValueError("Uninitialized submodule: " + str(repository)
                         + "; run git submodule update --init --recursive")

    submodules = set()
    for entry in git_output(repository, "ls-files", "--stage", "-z").split(b"\0"):
        if not entry:
            continue
        metadata, raw_name = entry.split(b"\t", 1)
        mode, _object_id, stage = metadata.split()
        if stage != b"0":
            raise ValueError("Resolve merge conflicts before packaging: " + os.fsdecode(raw_name))
        if mode == b"160000":
            submodules.add(os.fsdecode(raw_name))
    tracked = git_paths(repository, "--cached")
    untracked = git_paths(repository, "--others", "--exclude-standard")
    files = []
    for name in sorted(tracked | untracked):
        relative = safe_path(name)
        archive_path = prefix / relative
        if excluded(archive_path, name not in tracked):
            continue
        source = repository.joinpath(*relative.parts)
        if name in submodules:
            if not source.is_dir() or source.is_symlink():
                raise ValueError("Uninitialized submodule: " + str(source)
                                 + "; run git submodule update --init --recursive")
            files.extend(collect_files(source, archive_path, visited))
            continue
        try:
            mode = source.lstat().st_mode
        except FileNotFoundError:
            # A tracked file deleted in the current working tree is not part
            # of the source being built and must not be resurrected.
            continue
        if not (stat.S_ISREG(mode) or stat.S_ISLNK(mode)):
            raise ValueError("Unsupported source file type: " + str(source))
        # A directory symlink must not pull files from outside the checkout.
        if any(parent.is_symlink() for parent in source.parents if parent != repository
               and repository in parent.parents):
            raise ValueError("Source path traverses a symlink: " + str(source))
        files.append((source, archive_path))
    return files


def public_metadata(info):
    # Preserve mode and symlink target, but omit the local account identity.
    info.uid = info.gid = 0
    info.uname = info.gname = ""
    return info


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version", nargs="?", help="Release version; defaults to Resources/Info.plist")
    arguments = parser.parse_args()
    if arguments.version is None:
        with (ROOT / "Resources/Info.plist").open("rb") as stream:
            version = plistlib.load(stream)["CFBundleShortVersionString"]
    else:
        version = arguments.version
    if not re.fullmatch(r"[0-9][A-Za-z0-9.+_-]{0,99}", version):
        parser.error("Use a version such as 0.2.2 or 0.2.2-build.123.1")

    files = collect_files(ROOT)
    paths = {str(relative) for _source, relative in files}
    # A shallow or uninitialized copy must fail instead of producing a source
    # release that cannot rebuild its bundled engine.
    required = {"Package.swift", "build.sh", "Native/SevenZipBridge.cpp",
                "vendor/7zip/C/7zVersion.h", "vendor/7zip/DOC/License.txt"}
    missing = required - paths
    if missing:
        raise ValueError("Incomplete source tree: " + ", ".join(sorted(missing)))

    output_dir = ROOT / "dist"
    staging_root = ROOT / ".build/source"
    output_dir.mkdir(exist_ok=True)
    staging_root.mkdir(parents=True, exist_ok=True)
    filename = "SevenZip-" + version + "-source.tar.gz"
    top_directory = "SevenZip-" + version
    destination = output_dir / filename
    with tempfile.TemporaryDirectory(prefix="package.", dir=staging_root) as temporary:
        temporary = Path(temporary)
        archive_path = temporary / filename
        with tarfile.open(archive_path, "w:gz", format=tarfile.PAX_FORMAT, dereference=False) as archive:
            top = tarfile.TarInfo(top_directory)
            top.type = tarfile.DIRTYPE
            top.mode = 0o755
            archive.addfile(top)
            for source, relative in files:
                archive.add(source, arcname=str(PurePosixPath(top_directory) / relative),
                            recursive=False, filter=public_metadata)
        # Read to EOF so gzip verifies its checksum before replacing a release.
        with gzip.open(archive_path, "rb") as stream:
            while stream.read(1024 * 1024):
                pass
        digest = hashlib.sha256()
        with archive_path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        checksum_path = temporary / (filename + ".sha256")
        checksum_path.write_text(digest.hexdigest() + "  " + filename + "\n", encoding="utf-8")
        os.replace(archive_path, destination)
        os.replace(checksum_path, output_dir / checksum_path.name)
    print("Packaged " + str(len(files)) + " source files, including initialized submodules.")
    print("Generated: " + str(destination))
    print("Checksum: " + str(destination) + ".sha256")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit("Source packaging failed: " + str(error))
