import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('state', Path(__file__).parents[1] / 'state.py')
state = importlib.util.module_from_spec(spec)
spec.loader.exec_module(state)


class StateTests(unittest.TestCase):
    def test_atomic_private_survives_new_reader(self):
        with tempfile.TemporaryDirectory() as temp:
            p = Path(temp) / 'private/snapshots.json'
            first = {'version':1,'protectionSnapshot':{'before':{'mode':'Adaptive'},'applied':{'mode':'PrimAcUse'}}}
            state.atomic_write(p, first)
            self.assertEqual(state.read_private(p),first)
            self.assertEqual(p.stat().st_mode & 0o777,0o600)
            self.assertEqual(p.parent.stat().st_mode & 0o777,0o700)
            state.atomic_write(p, {'version':1})
            self.assertEqual(state.read_private(p),{'version':1})
            self.assertEqual(list(p.parent.glob('.snapshot-*')),[])

    def test_symlink_file_and_directory_refused(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            target = root / 'target'; target.write_text('{}')
            link = root / 'link'; link.symlink_to(target)
            with self.assertRaises(OSError): state.read_private(link)
            with self.assertRaises(ValueError): state.atomic_write(link,{})
            directory = root / 'private'; directory.mkdir()
            linked = root / 'linked'; linked.symlink_to(directory)
            with self.assertRaises(ValueError): state.atomic_write(linked / 's.json',{})
            self.assertEqual(target.read_text(),'{}')

    def test_corrupt_insecure_oversized_snapshots_refused(self):
        with tempfile.TemporaryDirectory() as temp:
            p=Path(temp)/'s.json'; p.write_text('{}'); p.chmod(0o644)
            with self.assertRaises(ValueError): state.read_private(p)
            p.chmod(0o600); p.write_text('[')
            with self.assertRaises(ValueError): state.read_private(p)
            with self.assertRaises(ValueError): state.atomic_write(p,{'blob':'a'*65536})

    def test_failed_replace_preserves_original(self):
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as temp:
            p=Path(temp)/'state/s.json'; state.atomic_write(p,{'old':True})
            with patch.object(state.os,'replace',side_effect=OSError('fixture')):
                with self.assertRaises(OSError): state.atomic_write(p,{'new':True})
            self.assertEqual(state.read_private(p),{'old':True})
            self.assertEqual(list(p.parent.glob('.snapshot-*')),[])


if __name__ == '__main__': unittest.main()
