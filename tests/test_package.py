"""Inspect locally built privileged artifact, never install or execute it."""
import json
from pathlib import Path
import subprocess
import tarfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PackageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        listed = subprocess.check_output(['/usr/bin/makepkg','--packagelist'],cwd=ROOT,text=True,timeout=15)
        packages = [Path(line) for line in listed.splitlines()]
        if len(packages) != 1 or not packages[0].is_file():
            raise AssertionError('Build exactly one local artifact with make package before checks')
        cls.archive = tarfile.open(packages[0], 'r:zst')

    @classmethod
    def tearDownClass(cls):
        cls.archive.close()

    def test_root_owned_fixed_payload_and_no_active_authorization(self):
        expected = {
          'usr/lib/dell-power-extension/control': 'system/control',
          'usr/lib/dell-power-extension/backend.py': 'system/backend.py',
          'usr/lib/dell-power-extension/setup': 'system/setup',
          'usr/lib/dell-power-extension/control.policy': 'system/local.dell-power-extension.policy',
          'usr/share/licenses/dell-power-extension/LICENSE': 'LICENSE'}
        for name, source in expected.items():
            member = self.archive.getmember(name)
            self.assertEqual(member.uid,0)
            self.assertEqual(member.gid,0)
            self.assertEqual(member.mode & 0o022,0)
            self.assertFalse(member.issym() or member.islnk())
            self.assertEqual(self.archive.extractfile(member).read(),(ROOT/source).read_bytes())
        names = self.archive.getnames()
        self.assertFalse(any(n.startswith(('etc/','sys/','usr/lib/systemd/','usr/share/polkit-1/')) for n in names))
        self.assertNotIn('.INSTALL',names)
        self.assertEqual(self.archive.extractfile('usr/lib/dell-power-extension/INSTALLER_OWNER').read().strip(),b'local.dell-power-extension')

    def test_manifest_service_identity_defaults_and_validation(self):
        m=json.loads((ROOT/'manifest.json').read_text())
        self.assertEqual(m['id'],'local.dell-power-extension')
        self.assertIn('service',m['kinds'])
        self.assertEqual(m['entryPoints']['service'],'Service.qml')
        self.assertEqual(m['barWidget']['defaultSection'],'right')
        for key in ('automation','saver','brightness','telemetry','powerFlow'):
            self.assertFalse(m['barWidget']['defaults'][key+'Enabled'])
        subprocess.run(['/usr/share/omarchy/bin/omarchy-plugin-validate',str(ROOT)],check=True,capture_output=True,timeout=15)

    def test_packagelist_matches_single_produced_script_package(self):
        listed = subprocess.check_output(['/usr/bin/makepkg','--packagelist'],cwd=ROOT,text=True,timeout=15)
        paths=[Path(line) for line in listed.splitlines()]
        self.assertEqual(len(paths),1)
        self.assertTrue(paths[0].is_file())
        self.assertNotIn('-debug-',paths[0].name)


if __name__ == '__main__': unittest.main()
