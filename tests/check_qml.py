#!/usr/bin/env python3
"""Offscreen integration of actual Omarchy UI and copied plugin production code.

Only copied Controller command paths, UPower imports, and native KeyboardPanel
window construction are redirected. Every
helper/elevation process targets a strict fixture simulator; action cases write
only its temporary status file. The read-only fixture rejects mutations. The real unprivileged snapshot bridge uses isolated HOME/XDG state.
"""
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
UI_ROOT = Path('/usr/share/omarchy/shell')


def prepare(directory, fixture="shell.qml"):
    root = Path(directory)
    plugin = root / 'plugin'
    plugin.mkdir()
    for name in ('Panel.qml', 'FeaturesPage.qml', 'PresentationModel.js', 'Service.qml',
                 'Controller.qml', 'Model.js', 'ControllerModel.js', 'PolicyModel.js', 'state.py'):
        shutil.copy2(ROOT / name, plugin / name)
    imports = root / 'imports'
    (imports / 'qs').mkdir(parents=True)
    (imports / 'qs/Commons').symlink_to(UI_ROOT / 'Commons', target_is_directory=True)
    (imports / 'qs/Ui').mkdir()
    for source in (UI_ROOT / 'Ui').iterdir():
        if source.name != 'KeyboardPanel.qml':
            (imports / 'qs/Ui' / source.name).symlink_to(source)
    shutil.copy2(ROOT / 'tests/qml/KeyboardPanel.qml', imports / 'qs/Ui/KeyboardPanel.qml')
    for name in ('Commons', 'Ui'):
        (root / name).symlink_to(imports / 'qs' / name, target_is_directory=True)
    shutil.copytree(ROOT / 'tests/qml', imports / 'FixtureUPower')
    shutil.copy2(ROOT / 'tests/qml' / fixture, root / 'shell.qml')
    for name in ('Panel.qml', 'Controller.qml'):
        path = plugin / name
        path.write_text(path.read_text().replace('import Quickshell.Services.UPower', 'import FixtureUPower'))
    fixture_status = {
        'ok': True, 'protocolVersion': 1, 'dell': True, 'vendor': 'Alienware',
        'backend': 'sysman', 'source': 'live', 'thresholds': {'start': 50, 'end': 80},
        'wmi': {'mode': 'Custom', 'usbPowerShare': 'Enabled', 'typeCPower': '15W'},
        'thermal': {'driver': 'alienware-wmi', 'profile': 'custom',
                    'choices': ['low-power', 'cool', 'quiet', 'balanced', 'balanced-performance', 'performance', 'custom']},
        'controllers': [{'name': 'alienware-wmi', 'profile': 'custom', 'choices': ['balanced', 'custom']}],
        'ppd': {'available': True, 'profile': 'balanced', 'choices': ['power-saver', 'balanced', 'performance']},
        'sensors': {'fans': [{'id': 'fan1', 'label': 'CPU Fan', 'boost': 40, 'rpm': None, 'max': None}], 'temps': []},
        'battery': {'health': 'Good', 'capacityHealthPercent': 85, 'energyFullWh': 51,
                    'energyDesignWh': 60, 'energyEstimated': True, 'cycleCount': 12,
                    'temperatureC': 31, 'state': 'Charging', 'rateW': 15},
        'capabilities': dict.fromkeys(['charging', 'thresholds', 'thermal', 'systemProfiles', 'usb',
                                       'fanBoost', 'telemetry', 'powerFlow', 'brightness'], True),
    }
    fixture_status['controllers'][0]['choices'] = fixture_status['thermal']['choices']
    fixture_status['controllers'].append({'name': 'SoC Power Slider', 'profile': 'balanced', 'choices': ['low-power', 'balanced', 'performance']})
    fixture_status['brightness'] = 500
    fixture_status['brightnessMax'] = 1000
    (root / 'status.json').write_text(json.dumps(fixture_status))
    (root / 'flags.json').write_text(json.dumps({'actions': fixture == 'actions.qml'}))
    if fixture == 'actions.qml':
        (plugin / 'state.py').rename(plugin / 'real_state.py')
        shutil.copy2(ROOT / 'tests/qml/bridge.py', plugin / 'state.py')
        shutil.copy2(ROOT / 'tests/qml/control.py', root / 'fixture-control.py')
    command = root / 'mock-command'
    shutil.copy2(ROOT / 'tests/qml/mock_helper.py', command)
    command.chmod(0o755)
    (root / 'mock-monitor').write_text('#!/usr/bin/python3\nimport time\ntime.sleep(20)\n')
    (root / 'mock-monitor').chmod(0o755)
    for name in ('mock-battery', 'mock-profiles'):
        (root / name).symlink_to(command)
    controller = plugin / 'Controller.qml'
    text = controller.read_text()
    substitutions = {
        '/usr/lib/dell-power-extension/control': str(command),
        '/usr/bin/sudo': str(command), '/usr/bin/pkexec': str(command),
        '/usr/bin/dbus-monitor': str(root / 'mock-monitor'),
        '/usr/share/omarchy/bin/omarchy-battery-status': str(root / 'mock-battery'),
        '/usr/share/omarchy/bin/omarchy-powerprofiles-list': str(root / 'mock-profiles'),
        '/usr/share/omarchy/bin/omarchy-powerprofiles-set': str(command),
    }
    for original, replacement in substitutions.items(): text = text.replace(original, replacement)
    if any(original in text for original in substitutions): raise AssertionError('Unredirected fixture process path')
    controller.write_text(text)
    for name in ('home', 'state', 'config', 'cache', 'runtime'):
        (root / name).mkdir(mode=0o700)
    env = {key: value for key, value in os.environ.items()
           if key not in {'DISPLAY', 'WAYLAND_DISPLAY', 'HYPRLAND_INSTANCE_SIGNATURE', 'DBUS_SESSION_BUS_ADDRESS', 'OMARCHY_PATH'}}
    env.update(QT_QPA_PLATFORM='offscreen', QT_QPA_PLATFORMTHEME='none', QT_QUICK_CONTROLS_STYLE='Basic', QSG_RHI_BACKEND='software',
               HOME=str(root / 'home'), XDG_STATE_HOME=str(root / 'state'),
               XDG_CONFIG_HOME=str(root / 'config'), XDG_CACHE_HOME=str(root / 'cache'),
               XDG_RUNTIME_DIR=str(root / 'runtime'), QML_IMPORT_PATH=str(imports))
    return root, env


def run_fixture(fixture):
    if not shutil.which('qs') or not (UI_ROOT / 'Ui/Panel.qml').exists():
        raise SystemExit('Actual Quickshell/Omarchy modules are required for the runtime check')
    with tempfile.TemporaryDirectory(prefix='dell-qml-') as directory:
        root, env = prepare(directory, fixture)
        try:
            result = subprocess.run(['qs', '--no-color', '-p', str(root)], env=env,
                                    capture_output=True, text=True, timeout=24)
        except subprocess.TimeoutExpired as error:
            print(((error.stdout or b'').decode() if isinstance(error.stdout, bytes) else (error.stdout or ''))[:16000])
            print(((error.stderr or b'').decode() if isinstance(error.stderr, bytes) else (error.stderr or ''))[:16000])
            raise SystemExit('Offscreen fixture exceeded its bounded timeout')
        output = result.stdout + result.stderr
        matches = re.findall(r'FIXTURE_RESULT (\{[^\n]*\})', output)
        if result.returncode or not matches:
            print(output[:16000])
            raise SystemExit('Offscreen plugin load failed')
        evidence = json.loads(matches[-1])
        errors = [line for line in output.splitlines() if re.search(r'(TypeError|ReferenceError|ASSERTION FAILED|Cannot assign|Unable to assign|Duplicate IPC|Handler was registered but will not be used|Binding loop)', line)]
        commands = [json.loads(line) for line in (root / 'commands.jsonl').read_text().splitlines()]
        allowed = {'status', 'status-live', 'sensors', 'power-chain', 'battery-info', 'profile-list'}
        if fixture == 'actions.qml':
            allowed |= {'charge-protect', 'charge-mode', 'charge-restore', 'profile', 'profile-owned', 'profile-owned-state', 'profile-restore-state', 'brightness-owned', 'brightness-restore'}
        forbidden = [item for item in commands if item['operation'] not in allowed]
        if evidence['failed'] or errors or forbidden:
            print(output[:16000])
            print('Fixture operations:', [(x['operation'], x['args']) for x in commands])
            print('Forbidden fixture operations:', forbidden)
            raise SystemExit('Offscreen behavioral checks failed')
        snapshot = root / 'state/dell-power-extension/snapshots.json'
        saved = json.loads(snapshot.read_text())
        if fixture == 'shell.qml':
            for operation in ('sensors', 'power-chain'):
                assert sum(item['operation'] == operation for item in commands) == 1, operation + ' must have one shared initial sample'
            assert saved['protectionSnapshot']['before']['mode'] == 'Standard'
        else:
            mutations = [item for item in commands if item['operation'] not in {'status', 'status-live', 'battery-info', 'profile-list'}]
            assert sum(item['operation'] == 'charge-protect' for item in mutations) == 1, 'failed preflight must not reach helper'
            assert sum(item['operation'] == 'profile-owned-state' for item in mutations) == 2, 'each saver episode applies profiles once'
            assert sum(item['operation'] == 'brightness-owned' for item in mutations) == 2, 'each saver episode applies brightness once'
            queued_modes = [item['args'][1] for item in mutations if item['operation'] == 'charge-mode']
            assert queued_modes == ['Standard', 'Adaptive', 'Custom'], 'refusal and queued requests must retain order'
            assert saved['policySnapshots'] == {}, 'retired ownership snapshots must be persisted'
            assert saved['policyState']['episode'] is False
            for item in mutations:
                if item['operation'] == 'charge-protect': assert item['snapshot']['protectionSnapshot']['applied']['mode'] == 'PrimAcUse'
                if item['operation'] in {'profile-owned', 'profile-owned-state'}: assert item['snapshot']['policySnapshots']['profile']['applied']['dell'] == 'quiet'
                if item['operation'] == 'brightness-owned': assert item['snapshot']['policySnapshots']['brightness']['applied'] == 300
            assert any(item['operation'] == 'profile-restore-state' for item in mutations), 'preference failure must attempt conditional rollback'
            bridge = [json.loads(line) for line in (root / 'bridge.jsonl').read_text().splitlines()]
            assert any(item['operation'] == 'save' and not item['ok'] for item in bridge)
            assert any(item['operation'] == 'remember' and not item['ok'] for item in bridge)
        assert stat.S_IMODE(snapshot.stat().st_mode) == 0o600
        assert stat.S_IMODE(snapshot.parent.stat().st_mode) == 0o700
        print(f"Offscreen QML {fixture} checks passed: {len(evidence['passed'])} assertions; {len(commands)} fixture operations; private snapshot checks verified.")
        for label in evidence['passed']: print('  PASS ' + label)


def main():
    run_fixture('shell.qml')
    run_fixture('actions.qml')


if __name__ == '__main__': main()
