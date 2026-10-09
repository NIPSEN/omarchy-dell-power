"""Baseline behavior guards, separate from new specification feature tests.

Static guards identify removed interactions/components. Runtime wiring and
lifecycle assertions live in check_qml.py; actual native windows and firmware
acceptance remain outside these offline checks.
"""
from pathlib import Path
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


class BaselinePreservation(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.panel = (ROOT / 'Panel.qml').read_text()
        cls.features = (ROOT / 'FeaturesPage.qml').read_text()
        cls.model = (ROOT / 'Model.js').read_text()

    def test_original_model_behavior_checks_remain_executable(self):
        result = subprocess.run(['node', 'Model.test.js'], cwd=ROOT,
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        # The original suite must continue exercising Alienware and Latitude,
        # bounds, fallback values and calculations rather than merely existing.
        tests = (ROOT / 'Model.test.js').read_text()
        for evidence in ('aw thermal ordered', 'aw gpu boost', 'older helper: no thermal',
                         'clampEnd invariant', 'parseKeyValue tab', 't2t au-dessus du seuil'):
            self.assertIn(evidence, tests)

    def test_original_visual_components_are_retained(self):
        for component in ('FanRow', 'TempTile', 'BoostSlider', 'DellToggle', 'FlowArrow',
                          'FlowNode', 'InfoPair', 'InfoLabel', 'InfoValue'):
            self.assertRegex(self.panel, r'component\s+' + component + r'\s*:')
        for token in ('heroIcon', 'heroStatus', 'heroPercent', 'barTrack', 'barFill',
                      'thresholdZone', 'startTick', 'stopTick', 'thresholdTip'):
            self.assertRegex(self.panel, r'id:\s*' + token + r'\b')
        for behavior in ('phraseSwap', 'onRotatingPhrasesChanged', 'SequentialAnimation on opacity',
                         'Behavior on width', 'Color.tooltip', 'Color.accent'):
            self.assertIn(behavior, self.panel)

    def test_percentage_and_keyboard_interactions_are_retained(self):
        for interaction in ('Qt.RightButton', 'togglePercentage()', 'button.glyphPaintedWidth',
                            '!vertical', 'selectProfileByDelta', 'activateSelectedProfile',
                            'onMoveRequested', 'onActivateRequested', 'onCloseRequested',
                            'onTabRequested', 'root.switchPanel(direction)'):
            self.assertIn(interaction, self.panel)
        self.assertRegex(self.panel, r'function\s+togglePercentage\s*\(')
        self.assertIn('setSetting("showPercentage"', self.panel)

    def test_threshold_markers_keep_configurable_drag_and_inactive_styling(self):
        for interaction in ('tickNear', 'onPressed', 'onPositionChanged', 'onReleased',
                            'previewStart', 'previewEnd', 'pct / root.chargeLimitStep',
                            'Model.DELL_GAP', 'setThresholds', 'mode !== "Custom"',
                            'mode === "Custom" ? 1 : 0.6', 'inactive (mode'):
            self.assertIn(interaction, self.panel)
        self.assertIn('chargingPaused', self.panel)
        # The hero line stays upstream's; the battery state tells an active
        # Custom limit apart from any other pause.
        self.assertIn('return Model.modeLabel(device, root.discharging, upowerStates())', self.panel)
        self.assertIn('root.chargeThresholdActive ? "Holding" : "Paused"', self.panel)

    def test_optional_sampling_does_not_own_alienware_fan_controls(self):
        self.assertIn('Model.groupBoost(root.controlFans, group)', self.panel)
        self.assertIn('readonly property var controlFans: dellStatus ? dellStatus.fans', self.panel)
        self.assertIn('visible: root.fanBoostAvailable', self.panel)
        self.assertIn('setFanBoost(boostBox.group, v)', self.panel)
        self.assertIn('setThermalProfile(String(modelData))', self.panel)
        self.assertIn('Model.thermalChoices(thermal)', self.panel)
        self.assertNotIn('Model.thermalExtended(thermal)', self.panel)

    def test_usb_and_power_flow_presentation_are_retained(self):
        for interaction in ('USB PowerShare', 'Type-C 7.5 W', 'Type-C 15 W',
                            'setUsbPowerShare()', 'setDellTypeCPower("15W")',
                            'sourceNode', 'componentsNode', 'batteryNode', 'FlowArrow',
                            'collapsible: true', '"CPU package"', 'label: "iGPU"',
                            'label: "RAM"', 'label: "Other"', 'packV', 'packA'):
            self.assertIn(interaction, self.panel)
        self.assertIn('text: "POWER FLOW"', self.panel)
        self.assertIn('hint: "Estimates"', self.panel)
        self.assertIn('Presentation.capacityText(root.basicBattery', self.panel)
        self.assertIn('Presentation.rateText(root.basicBattery.rateW)', self.panel)

    def test_panel_delegates_work_to_shared_service_and_keeps_clipboard(self):
        self.assertIn('serviceFor(root.moduleName)', self.panel)
        self.assertIn('service.controller', self.panel)
        self.assertRegex(self.panel, r'attachPanel\(panelToken(?:,|\))')
        self.assertIn('setPanelOpen(panelToken, opened)', self.panel)
        self.assertIn('detachPanel(panelToken)', self.panel)
        processes = re.findall(r'\bProcess\s*\{', self.panel)
        self.assertEqual(len(processes), 1, 'Panel must not duplicate status/control/sensor processes')
        self.assertIn('"/usr/bin/wl-copy", root.setupCommand', self.panel)
        self.assertIn('root.setupCopied', self.panel)
        for removed in ('systemProc', 'systemInfo', 'dellActionProc', 'powerChainProc'):
            self.assertNotIn(removed, self.panel)

    def test_ipc_has_one_shared_owner(self):
        controller = (ROOT / 'Controller.qml').read_text()
        self.assertEqual(len(re.findall(r'\bIpcHandler\s*\{', self.panel)), 0)
        self.assertEqual(len(re.findall(r'\bIpcHandler\s*\{', controller)), 1)
        self.assertIn('togglePercentage', controller)

    def test_features_restores_remain_separate_from_enable_toggles(self):
        for contract in ('featureEnabled', 'featureVisible', 'setFeature', 'restoreProtection()',
                         'restorePolicy("profile")', 'restorePolicy("brightness")',
                         'configureSourceProfile', 'saverEnter', 'saverExit', 'brightnessCap'):
            self.assertIn(contract, self.features)
        self.assertIn('protectionSnapshot', self.features)
        self.assertIn('policySnapshots.profile', self.features)
        self.assertIn('policySnapshots.brightness', self.features)
        # Enabled and Visible must have separate actions.
        self.assertIn('"enabled"', self.features)
        self.assertIn('"visible"', self.features)


if __name__ == '__main__': unittest.main()
