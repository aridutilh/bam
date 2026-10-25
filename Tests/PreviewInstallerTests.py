#!/usr/bin/env python3
"""Headless canonical-preview install checks; all app fixtures live in a temp dir."""
import importlib.util
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True
MODULE = Path(__file__).resolve().parents[1] / 'scripts/preview_install.py'
spec = importlib.util.spec_from_file_location('preview_install', MODULE)
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class FixtureOperations:
    def __init__(self):
        self.running_checks = 0
        self.live_on_check = None
        self.fail = None
        self.copied = False
        self.after_copy = None

    def copy(self, source, destination):
        self.copied = True
        shutil.copytree(source, destination, symlinks=True)
        if self.after_copy:
            self.after_copy()
        if self.fail == 'copy':
            raise installer.InstallError('Injected copy failure')

    def sign(self, app):
        if self.fail == 'sign':
            raise installer.InstallError('Injected signing failure')

    def verify(self, app):
        phase = 'stage-verify' if app.parent.name == 'staged' else 'installed-verify'
        if self.fail == phase:
            raise installer.InstallError('Injected verification failure')

    def move(self, source, destination):
        if self.fail == 'install-move' and source.parent.name == 'staged':
            raise installer.InstallError('Injected install move failure')
        if self.fail == 'rollback' and source.parent.name == 'backup':
            raise installer.InstallError('Injected restore failure')
        os.rename(source, destination)
        if self.fail == 'rollback' and destination.parent.name == 'applications':
            raise installer.InstallError('Injected post-install failure')

    def running(self, app):
        self.running_checks += 1
        return self.running_checks == self.live_on_check


class PreviewInstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='bam-preview-installer-')
        self.root = Path(self.temporary.name)
        self.source = self.root / 'build/Bam.app'
        self.destination = self.root / 'applications/Bam Preview.app'
        self.destination.parent.mkdir()
        self.operations = FixtureOperations()
        self.make_app(self.source, 'com.ari.orbitprototype', b'new build')
        # The release fixture must remain untouched by every success/failure.
        self.release = self.destination.parent / 'Bam.app'
        self.make_app(self.release, 'com.ari.orbitprototype', b'release')

    def tearDown(self):
        self.assertEqual((self.release / 'Contents/MacOS/BamBrowser').read_bytes(), b'release')
        self.assertEqual(installer.read_plist(self.release)['CFBundleIdentifier'], 'com.ari.orbitprototype')
        self.temporary.cleanup()

    def make_app(self, app, identifier, content=b'old build'):
        (app / 'Contents/MacOS').mkdir(parents=True)
        (app / 'Contents/Resources').mkdir()
        binary = app / 'Contents/MacOS/BamBrowser'
        binary.write_bytes(content)
        binary.chmod(0o755)
        (app / 'Contents/Resources/BamPreviewIcon.icns').write_bytes(b'fixture icon')
        with (app / 'Contents/Info.plist').open('wb') as stream:
            plistlib.dump({'CFBundleIdentifier': identifier, 'CFBundleExecutable': 'BamBrowser',
                           'BamPreviewProfileIdentifier': 'com.ari.bam.preview',
                           'CFBundleName': 'Bam', 'CFBundleURLTypes': [{'CFBundleURLSchemes': ['https']}]}, stream)

    def prepare(self):
        with installer.installation_lock(self.destination.parent):
            return installer.prepare(self.source, self.destination, self.operations)

    def assert_clean(self):
        self.assertEqual(list(self.destination.parent.glob('.bam-preview-install-*')), [])

    def test_fresh_install_sets_canonical_identity_without_changing_input(self):
        before = (self.source / 'Contents/Info.plist').read_bytes()
        self.assertEqual(self.prepare(), self.destination)
        manifest = installer.read_plist(self.destination)
        self.assertEqual(manifest['CFBundleIdentifier'], 'com.ari.bam.preview')
        self.assertEqual(manifest['CFBundleName'], 'Bam Preview')
        self.assertEqual(manifest['CFBundleDisplayName'], 'Bam Preview')
        self.assertEqual(manifest['CFBundleIconFile'], 'BamPreviewIcon.icns')
        self.assertNotIn('CFBundleURLTypes', manifest)
        self.assertEqual((self.source / 'Contents/Info.plist').read_bytes(), before)
        self.assert_clean()

    def test_unsupported_build_input_keeps_existing_preview(self):
        self.make_app(self.destination, 'com.ari.bam.preview')
        original = installer.fingerprint(self.destination)
        manifest = installer.read_plist(self.source)
        for field, value in (('BamPreviewProfileIdentifier', None),
                             ('BamPreviewProfileIdentifier', 'com.ari.bam.extensionpreview'),
                             ('CFBundleExecutable', 'OldBrowser')):
            with self.subTest(field=field, value=value):
                unsupported = dict(manifest)
                if value is None:
                    unsupported.pop(field)
                else:
                    unsupported[field] = value
                with (self.source / 'Contents/Info.plist').open('wb') as stream:
                    plistlib.dump(unsupported, stream)
                with self.assertRaisesRegex(installer.InstallError, 'Rebuild'):
                    self.prepare()
                self.assertEqual(installer.fingerprint(self.destination), original)
                self.assertEqual((self.destination / 'Contents/MacOS/BamBrowser').read_bytes(), b'old build')
                self.assertFalse(self.operations.copied)
                self.assert_clean()

    def test_only_preview_ids_may_be_replaced(self):
        for identifier in ('com.ari.bam.preview', 'com.ari.bam.extensionpreview', 'com.ari.bam.proportionspreview'):
            with self.subTest(identifier=identifier):
                self.make_app(self.destination, identifier)
                self.prepare()
                self.assertEqual((self.destination / 'Contents/MacOS/BamBrowser').read_bytes(), b'new build')
                shutil.rmtree(self.destination)
        self.assert_clean()

    def test_unrelated_destination_is_untouched(self):
        self.make_app(self.destination, 'com.ari.orbitprototype')
        before = installer.fingerprint(self.destination)
        with self.assertRaises(installer.InstallError):
            self.prepare()
        self.assertEqual(installer.fingerprint(self.destination), before)
        self.assertFalse(self.operations.copied)

    def test_symlink_destination_is_untouched(self):
        self.destination.symlink_to(self.release, target_is_directory=True)
        with self.assertRaises(installer.InstallError):
            self.prepare()
        self.assertTrue(self.destination.is_symlink())
        self.assertFalse(self.operations.copied)

    def test_live_preview_is_not_replaced(self):
        self.make_app(self.destination, 'com.ari.bam.preview')
        self.operations.live_on_check = 1
        with self.assertRaises(installer.InstallError):
            self.prepare()
        self.assertFalse(self.operations.copied)
        self.assertEqual((self.destination / 'Contents/MacOS/BamBrowser').read_bytes(), b'old build')

    def test_preview_launching_during_preparation_is_not_replaced(self):
        self.make_app(self.destination, 'com.ari.bam.preview')
        self.operations.live_on_check = 2
        with self.assertRaises(installer.InstallError):
            self.prepare()
        self.assertEqual((self.destination / 'Contents/MacOS/BamBrowser').read_bytes(), b'old build')
        self.assert_clean()

    def test_failures_restore_exact_previous_bundle(self):
        self.make_app(self.destination, 'com.ari.bam.preview')
        original = installer.fingerprint(self.destination)
        for failure in ('copy', 'sign', 'stage-verify', 'install-move', 'installed-verify'):
            with self.subTest(failure=failure):
                self.operations = FixtureOperations()
                self.operations.fail = failure
                with self.assertRaises(installer.InstallError):
                    self.prepare()
                self.assertEqual(installer.fingerprint(self.destination), original)
                self.assertEqual((self.destination / 'Contents/MacOS/BamBrowser').read_bytes(), b'old build')
                self.assert_clean()

    def test_failed_first_install_leaves_no_bundle(self):
        self.operations.fail = 'installed-verify'
        with self.assertRaises(installer.InstallError):
            self.prepare()
        self.assertFalse(self.destination.exists())
        self.assert_clean()

    def test_restore_failure_preserves_backup(self):
        self.make_app(self.destination, 'com.ari.bam.preview')
        self.operations.fail = 'rollback'
        with self.assertRaisesRegex(installer.InstallError, 'previous preview is preserved'):
            self.prepare()
        backups = list(self.destination.parent.glob('.bam-preview-install-*/backup/Bam Preview.app'))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / 'Contents/MacOS/BamBrowser').read_bytes(), b'old build')

    def test_changed_destination_is_not_overwritten(self):
        self.operations.after_copy = lambda: self.make_app(self.destination, 'com.example.unrelated')
        with self.assertRaises(installer.InstallError):
            self.prepare()
        self.assertEqual(installer.read_plist(self.destination)['CFBundleIdentifier'], 'com.example.unrelated')
        self.assert_clean()

    def test_linked_metadata_does_not_write_through_to_source(self):
        manifest = self.source / 'Contents/Info.plist'
        backing = self.source / 'manifest.plist'
        manifest.rename(backing)
        manifest.symlink_to(backing)
        before = backing.read_bytes()
        with self.assertRaises(installer.InstallError):
            self.prepare()
        self.assertEqual(backing.read_bytes(), before)
        self.assertFalse(self.destination.exists())
        self.assert_clean()

    def test_installed_preview_cannot_be_used_as_build_input(self):
        self.make_app(self.destination, 'com.ari.bam.preview')
        self.source = self.destination
        with self.assertRaises(installer.InstallError):
            self.prepare()
        self.assertFalse(self.operations.copied)

    def test_cross_process_install_lock_and_crash_recovery(self):
        code = ('import importlib.util, pathlib, sys; '
                'spec=importlib.util.spec_from_file_location("installer",sys.argv[1]); '
                'm=importlib.util.module_from_spec(spec); spec.loader.exec_module(m); '
                'lock=m.installation_lock(pathlib.Path(sys.argv[2])); lock.__enter__(); '
                'print("READY",flush=True); sys.stdin.read()')
        child = subprocess.Popen([sys.executable, '-B', '-c', code, str(MODULE), str(self.destination.parent)],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(child.stdout.readline().strip(), 'READY')
            with self.assertRaisesRegex(installer.InstallError, 'in progress'):
                self.prepare()
            self.assertFalse(self.operations.copied)
        finally:
            child.kill()
            child.wait(timeout=5)
            child.stdin.close()
            child.stdout.close()
        self.prepare()
        self.assertTrue(self.destination.exists())

    def test_symlink_install_lock_is_rejected(self):
        marker = self.root / 'marker'
        marker.write_text('unchanged')
        (self.destination.parent / '.bam-preview-install.lock').symlink_to(marker)
        with self.assertRaises(OSError):
            self.prepare()
        self.assertEqual(marker.read_text(), 'unchanged')
        self.assertFalse(self.operations.copied)

    def test_both_modes_exec_canonical_bundle_with_lock_held(self):
        class ExecObserved(BaseException):
            pass
        for options, expected in (([], '--persistent-preview'), (['--fresh', '--onboarding'], '--fresh-preview')):
            with self.subTest(options=options):
                def execute(path, arguments):
                    self.assertEqual(path, self.destination / 'Contents/MacOS/BamBrowser')
                    self.assertEqual(arguments[:2], [str(path), expected])
                    if '--onboarding' in options:
                        self.assertIn('--onboarding', arguments)
                    with self.assertRaises(installer.InstallError):
                        with installer.installation_lock(self.destination.parent):
                            pass
                    raise ExecObserved()
                with mock.patch.object(installer, 'DESTINATION', self.destination), \
                     mock.patch.object(installer, 'NativeOperations', return_value=self.operations), \
                     mock.patch.object(sys, 'argv', ['preview_install.py', '--source', str(self.source), *options]), \
                     mock.patch.object(installer.os, 'execv', side_effect=execute):
                    with self.assertRaises(ExecObserved):
                        installer.main()
                self.assert_clean()

    def test_prepare_only_does_not_launch(self):
        with mock.patch.object(installer, 'DESTINATION', self.destination), \
             mock.patch.object(installer, 'NativeOperations', return_value=self.operations), \
             mock.patch.object(sys, 'argv', ['preview_install.py', '--source', str(self.source), '--prepare-only']), \
             mock.patch.object(installer.os, 'execv') as execute:
            self.assertEqual(installer.main(), 0)
            execute.assert_not_called()
        self.assertTrue(self.destination.exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
