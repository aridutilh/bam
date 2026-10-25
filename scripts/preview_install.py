#!/usr/bin/env python3
"""Prepare and launch the single local Bam preview. Never installs the release app."""
import argparse
import contextlib
import ctypes
import fcntl
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile


DESTINATION = Path('/Applications/Bam Preview.app')
PREVIEW_ID = 'com.ari.bam.preview'


class InstallError(Exception):
    pass


class NativeOperations:
    def copy(self, source, destination):
        subprocess.run(['/usr/bin/ditto', '--norsrc', '--noextattr', str(source), str(destination)], check=True)

    def sign(self, app):
        for attribute in ('com.apple.FinderInfo', 'com.apple.ResourceFork'):
            subprocess.run(['/usr/bin/xattr', '-dr', attribute, str(app)], stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, check=False)
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none', str(app)], check=True)

    def verify(self, app):
        subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(app)], check=True)

    def move(self, source, destination):
        os.rename(source, destination)

    def running(self, app):
        """Match the actual executable path, not another preview's name or ID."""
        executable = (app / 'Contents/MacOS/BamBrowser').resolve()
        listing = subprocess.check_output(['/bin/ps', '-axww', '-o', 'pid=', '-o', 'comm='], text=True)
        proc = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
        proc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        proc.proc_pidpath.restype = ctypes.c_int
        for line in listing.splitlines():
            fields = line.strip().split(None, 1)
            if len(fields) != 2 or Path(fields[1]).name != 'BamBrowser':
                continue
            pid = int(fields[0])
            buffer = ctypes.create_string_buffer(4096)
            if proc.proc_pidpath(pid, buffer, len(buffer)) > 0:
                if Path(os.fsdecode(buffer.value)).resolve() == executable:
                    return True
            else:
                # A process may disappear between ps and proc_pidpath. If it
                # still exists but cannot be inspected, do not risk replacing it.
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    continue
                raise InstallError('Could not inspect a running BamBrowser process; leave the preview unchanged.')
        return False


def read_plist(app):
    with (app / 'Contents/Info.plist').open('rb') as stream:
        manifest = plistlib.load(stream)
    if not isinstance(manifest, dict):
        raise InstallError(f'Invalid application manifest at {app}')
    return manifest


def fingerprint(path):
    entry = path.lstat()
    return entry.st_dev, entry.st_ino


def check_destination(destination):
    if destination.is_symlink():
        raise InstallError(f'Refusing a symlink preview destination: {destination}')
    if not destination.exists():
        return None
    if not destination.is_dir():
        raise InstallError(f'Refusing a non-app preview destination: {destination}')
    identifier = read_plist(destination).get('CFBundleIdentifier', '')
    if not isinstance(identifier, str) or not re.fullmatch(r'com\.ari\.bam\.[A-Za-z0-9.-]*preview', identifier):
        raise InstallError(f'Refusing to replace an unrelated app at {destination} ({identifier!r}).')
    return fingerprint(destination)


@contextlib.contextmanager
def installation_lock(parent):
    # Never unlink this file: waiting installers must always share one inode.
    path = parent / '.bam-preview-install.lock'
    flags = os.O_CREAT | os.O_RDWR | os.O_CLOEXEC | os.O_NOFOLLOW
    descriptor = os.open(path, flags, 0o600)
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise InstallError(f'Preview install lock is not a regular file: {path}')
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise InstallError('Another Bam preview install is in progress. Try again when it finishes.') from error
        yield
    finally:
        os.close(descriptor)


def prepare(source, destination, operations):
    """Called with the installation lock held; destination parameter is for tests."""
    if source.resolve() == destination.resolve():
        raise InstallError('BAM_PREVIEW_APP must point to a build input, not the installed preview.')
    binary = source / 'Contents/MacOS/BamBrowser'
    icon = source / 'Contents/Resources/BamPreviewIcon.icns'
    if not binary.is_file() or not os.access(binary, os.X_OK) or not icon.is_file() or icon.stat().st_size == 0:
        raise InstallError('Build the local draft with bash build.sh first; its executable and construction icon are required.')
    source_manifest = read_plist(source)
    if (source_manifest.get('BamPreviewProfileIdentifier') != PREVIEW_ID
            or source_manifest.get('CFBundleExecutable') != 'BamBrowser'):
        raise InstallError('Rebuild the local draft with bash build.sh first; this build does not declare support for the canonical preview profile.')
    original = check_destination(destination)
    if operations.running(destination):
        raise InstallError('Quit Bam Preview before preparing its next build. No running app was stopped.')

    workspace = Path(tempfile.mkdtemp(prefix='.bam-preview-install-', dir=destination.parent))
    staged = workspace / 'staged' / 'Bam Preview.app'
    backup = workspace / 'backup' / 'Bam Preview.app'
    staged.parent.mkdir()
    backup.parent.mkdir()
    preserve_workspace = False
    installed = None
    try:
        operations.copy(source, staged)
        # Never write metadata through a copied link back into the build input.
        for relative in ('Contents', 'Contents/Info.plist', 'Contents/_CodeSignature'):
            if (staged / relative).is_symlink():
                raise InstallError(f'Refusing linked application metadata: {relative}')
        manifest = read_plist(staged)
        manifest.update(CFBundleName='Bam Preview', CFBundleDisplayName='Bam Preview',
                        CFBundleIdentifier=PREVIEW_ID, CFBundleExecutable='BamBrowser',
                        CFBundleIconFile='BamPreviewIcon.icns')
        manifest.pop('CFBundleURLTypes', None)
        with (staged / 'Contents/Info.plist').open('wb') as stream:
            plistlib.dump(manifest, stream)
        operations.sign(staged)
        operations.verify(staged)
        # Recheck after slow compilation/copy/signing work before any mutation.
        if check_destination(destination) != original:
            raise InstallError('Bam Preview changed during preparation; leave it unchanged and try again.')
        if operations.running(destination):
            raise InstallError('Bam Preview started during preparation. Quit it before installing this build.')
        if original is not None:
            operations.move(destination, backup)
        installed = fingerprint(staged)
        operations.move(staged, destination)
        operations.verify(destination)
    except BaseException as error:
        try:
            if installed is not None and destination.exists():
                if destination.is_symlink() or fingerprint(destination) != installed:
                    raise InstallError('The destination changed during rollback; it was not overwritten.')
                operations.move(destination, staged)
            if backup.exists():
                if destination.exists() or destination.is_symlink():
                    raise InstallError('Cannot restore the previous preview over an unexpected destination.')
                operations.move(backup, destination)
        except BaseException as rollback_error:
            preserve_workspace = True
            raise InstallError(f'{error}\nRollback could not finish: {rollback_error}\n'
                               f'The previous preview is preserved at {backup}; no backup was deleted.') from error
        raise
    finally:
        if not preserve_workspace:
            shutil.rmtree(workspace)
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--fresh', action='store_true')
    parser.add_argument('--onboarding', action='store_true')
    parser.add_argument('--prepare-only', action='store_true')
    arguments = parser.parse_args()
    try:
        with installation_lock(DESTINATION.parent):
            app = prepare(arguments.source, DESTINATION, NativeOperations())
            print(f'Prepared {app}', flush=True)
            if not arguments.prepare_only:
                options = ['--fresh-preview' if arguments.fresh else '--persistent-preview']
                if arguments.onboarding:
                    options.append('--onboarding')
                executable = app / 'Contents/MacOS/BamBrowser'
                # The install lock is close-on-exec: successful exec closes it
                # only after the canonical executable has been opened.
                os.execv(executable, [str(executable), *options])
    except (InstallError, OSError, subprocess.SubprocessError, plistlib.InvalidFileException) as error:
        print(f'preview-draft: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
