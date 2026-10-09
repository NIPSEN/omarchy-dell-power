"""Exercise CLI uncertain-outcome reporting with entirely mocked hardware."""
import contextlib
import io
import json
import os
from pathlib import Path
import runpy
import signal
import sys
import types
import unittest
from unittest import mock


class ControlReportingTests(unittest.TestCase):
    def test_outer_error_reports_unknown_mutation_outcome(self):
        module = types.ModuleType('backend')
        module.PROTOCOL_VERSION = 1
        module.Refused = type('Refused', (Exception,), {})
        module.Hardware = mock.Mock()
        module.Controller = mock.Mock()
        module.Controller.return_value.execute.side_effect = module.Refused('Fixture unavailable transaction outcome')
        output = io.StringIO()
        control = Path(__file__).resolve().parents[1] / 'system/dell-charge-limit'
        with mock.patch.dict(sys.modules, {'backend': module}), mock.patch.dict(os.environ), \
                mock.patch.object(sys, 'argv', ['control', 'status']), \
                mock.patch.object(sys, 'path', list(sys.path)), \
                mock.patch.object(sys, 'dont_write_bytecode', True), \
                mock.patch.object(signal, 'signal'), mock.patch.object(signal, 'alarm'), \
                contextlib.redirect_stdout(output), self.assertRaises(SystemExit) as exited:
            runpy.run_path(str(control), run_name='__main__')
        self.assertEqual(exited.exception.code, 1)
        result = json.loads(output.getvalue())
        self.assertFalse(result['ok'])
        self.assertFalse(result['applied'])
        self.assertIsNone(result['rollback']['attempted'])
        self.assertIsNone(result['rollback']['ok'])
        self.assertNotIn('before', result)
        self.assertNotIn('actual', result)
        module.Controller.return_value.execute.assert_called_once_with(['status'])
