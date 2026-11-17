"""Safety regressions for the native host experiment, independent of a Codex installation."""

import copy
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'probe-codex-host.py'
SPEC = importlib.util.spec_from_file_location('host_probe_under_test', SCRIPT)
host = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(host)


def valid_result():
    return {'milestone': 'result', 'mode': 'start', 'scenario': 'text', 'phase': 'completed',
            'hasUpstream': True, 'pendingApproval': False, 'eventCount': 13,
            'commandCompleted': False, 'commandExit': None, 'toolProcessesGoneBeforeClose': False,
            'agentMessageMatched': True, 'cleanup': {'leaderExitStatus': 0, 'stdoutEOF': True,
                'stderrEOF': True, 'groupGone': True, 'escalated': False,
                'stdinBytes': 861, 'stdoutBytes': 7533, 'stderrBytes': 205}}


class NativeResultTests(unittest.TestCase):
    def test_result_requires_true_native_terminal_marker_and_cleanup(self):
        host.validate_result(valid_result(), 'text', 'start')
        changes = [('phase', 'running'), ('hasUpstream', False), ('pendingApproval', True),
                   ('eventCount', True), ('eventCount', 0), ('agentMessageMatched', False)]
        for field, value in changes:
            with self.subTest(field=field):
                frame = valid_result()
                frame[field] = value
                with self.assertRaises(ValueError):
                    host.validate_result(frame, 'text', 'start')
        for field, value in [('groupGone', False), ('stderrEOF', False), ('leaderExitStatus', 9),
                             ('stdinBytes', True), ('stdinBytes', 0), ('stdoutBytes', 0), ('stderrBytes', 1048577)]:
            with self.subTest(cleanup=field):
                frame = valid_result()
                frame['cleanup'][field] = value
                with self.assertRaises(ValueError):
                    host.validate_result(frame, 'text', 'start')

    def test_approval_and_running_cancel_require_their_specific_evidence(self):
        frame = valid_result()
        frame.update(scenario='approval-accept')
        with self.assertRaisesRegex(ValueError, 'tool did not complete'):
            host.validate_result(frame, 'approval-accept', 'start')
        frame.update(commandCompleted=True, commandExit=0)
        host.validate_result(frame, 'approval-accept', 'start')
        frame.update(scenario='running-interrupt', phase='cancelled')
        with self.assertRaisesRegex(ValueError, 'before transport shutdown'):
            host.validate_result(frame, 'running-interrupt', 'start')
        frame['toolProcessesGoneBeforeClose'] = True
        host.validate_result(frame, 'running-interrupt', 'start')

    def test_lost_mapping_cannot_be_reported_as_complete_or_as_a_mapped_turn(self):
        frame = valid_result()
        frame.update(mode='recover', scenario='mapping-loss', phase='reconciling', hasUpstream=False,
                     agentMessageMatched=False, eventCount=0)
        host.validate_result(frame, 'mapping-loss', 'recover')
        for field, value in [('phase', 'completed'), ('hasUpstream', True)]:
            changed = copy.deepcopy(frame)
            changed[field] = value
            with self.assertRaises(ValueError):
                host.validate_result(changed, 'mapping-loss', 'recover')

    def test_ps_failure_does_not_skip_initial_kill_signal(self):
        with patch.object(host.os, 'killpg') as kill, \
                patch.object(host.probe, 'group_members', side_effect=OSError('synthetic')):
            with self.assertRaises(OSError):
                host.stop_native_group(123456789)
        kill.assert_called_once_with(123456789, host.signal.SIGKILL)


class MilestoneTests(unittest.TestCase):
    def test_fault_barrier_is_exact_and_cannot_be_bypassed_or_repeated(self):
        for scenario, phase in (('pending-crash', 'awaitingApproval'),
                                ('mapped-crash', 'running'), ('mapping-loss', 'dispatching')):
            frame = {'milestone': 'barrier', 'mode': 'start', 'scenario': scenario, 'phase': phase}
            host.validate_milestone(frame, ['spawned'], scenario, 'start')
            for previous in ([], ['spawned', 'barrier']):
                with self.assertRaises(ValueError):
                    host.validate_milestone(frame, previous, scenario, 'start')
            with self.assertRaises(ValueError):
                host.validate_milestone(dict(frame, phase='wrong'), ['spawned'], scenario, 'start')
            result = valid_result() | {'scenario': scenario, 'phase': 'reconciling'}
            with self.assertRaises(ValueError):
                host.validate_milestone(result, ['spawned'], scenario, 'start')
            if scenario != 'mapping-loss':
                host.validate_milestone(result, ['spawned', 'barrier'], scenario, 'start')

    def test_spawn_and_startup_loss_order_is_unique(self):
        frame = {'milestone': 'spawned', 'mode': 'start', 'scenario': 'text', 'nativeGroup': 12345}
        host.validate_milestone(frame, [], 'text', 'start')
        with self.assertRaises(ValueError):
            host.validate_milestone(frame, ['spawned'], 'text', 'start')
        for value in (True, '12345'):
            with self.assertRaises(ValueError):
                host.validate_milestone(dict(frame, nativeGroup=value), [], 'text', 'start')
        arming = {'milestone': 'arming', 'mode': 'start', 'scenario': 'startup-loss'}
        host.validate_milestone(arming, [], 'startup-loss', 'start')
        with self.assertRaises(ValueError):
            host.validate_milestone(arming, ['arming'], 'startup-loss', 'start')


class ProviderInputTests(unittest.TestCase):
    def test_exact_last_user_input_is_required(self):
        item = {'role': 'user', 'content': [{'type': 'input_text',
                'text': 'Execute the Munie native host fixture: text'}]}
        host.validate_user_input({'input': [item]}, 'text')
        for value in ([], [{'role': 'assistant', 'content': item['content']}],
                      [dict(item, content=[])], [dict(item, content='text')],
                      [dict(item, content=[{'type': 'input_text', 'text': 'wrong'}])],
                      [dict(item, content=item['content'] * 2)]):
            with self.subTest(value=value), self.assertRaises(ValueError):
                host.validate_user_input({'input': value}, 'text')
        with self.assertRaises(ValueError):
            host.validate_user_input({'input': [item]}, 'approval-accept')


class LaunchRegistryTests(unittest.TestCase):
    def test_registry_binds_exact_parent_group_and_private_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'registry.json'
            data = {'registryVersion': 1, 'guardianPID': 123456789,
                    'processGroupID': 123456789, 'parentPID': 234567890}
            path.write_text(json.dumps(data))
            path.chmod(0o600)
            self.assertEqual(host.registered_group(path, 234567890), 123456789)
            with self.assertRaises(ValueError):
                host.registered_group(path, 345678901)
            path.chmod(0o644)
            with self.assertRaises(ValueError):
                host.registered_group(path, 234567890)

    def test_registry_rejects_alias_boolean_identity_and_hardlink(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / 'registry.json'
            data = {'registryVersion': True, 'guardianPID': 123456789,
                    'processGroupID': 123456789, 'parentPID': 234567890}
            path.write_text(json.dumps(data))
            path.chmod(0o600)
            with self.assertRaises(ValueError):
                host.registered_group(path, 234567890)
            alias = root / 'alias'
            alias.symlink_to(path)
            with self.assertRaises(OSError):
                host.registered_group(alias, 234567890)
            data['registryVersion'] = 1
            path.write_text(json.dumps(data))
            os.link(path, root / 'hardlink')
            with self.assertRaises(ValueError):
                host.registered_group(path, 234567890)


if __name__ == '__main__':
    unittest.main()
