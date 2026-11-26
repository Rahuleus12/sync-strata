import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

import sync_home as H
import sync_remote


PROFILE = Path(__file__).resolve().parents[2] / 'packaging' / 'src' / 'pack-component' / 'dsh-profile'
ROWS = (
    'session-telemetry-otel',
    'session-log-deepseek',
    'plugin-package-inventory-deepseek',
    'desktop-product-telemetry',
    'product-analytics',
)
DISABLE_PATCH = ''.join(f'- id: {row}\n  disabled: true\n' for row in ROWS)


class DshTelemetryTest(unittest.TestCase):
    def setUp(self):
        self.root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.dsh_home = self.root / 'dsh home'
        self.settings = dict(dsh_home=str(self.dsh_home), proxy_port=8081, dsh_port=3080,
                             relay_port=3090, api_port=8080, context=32768)
        self.enterContext(patch.dict(os.environ, SYNC_HOME=str(self.root), SYNC_USE_DSH_TASK='0',
                                     DSH_TELEMETRY_DISABLED=''))
        self.enterContext(patch.object(H, 'search_plugin', return_value=None))

    def test_fresh_profile_disables_exporters_and_keeps_local_provider(self):
        with patch.object(H, 'DSH_PROFILE_SRC', str(PROFILE)):
            profile = Path(H.prepare_dsh_home(self.settings))
        text = (profile / 'cordis.patch.yml').read_text(encoding='utf-8')
        for row in ROWS:
            with self.subTest(row=row):
                self.assertRegex(text, rf'(?m)^- id: {row}\n  disabled: true$')
        self.assertIn('baseURL: http://127.0.0.1:8081/v1', text)
        self.assertIn('provider: strata', text)

    def start_with_existing_profile(self, dump):
        profile = self.dsh_home / 'profiles' / 'web'
        profile.mkdir(parents=True)
        original = b'# existing user profile\n- id: session-log-deepseek\n  disabled: false\n'
        profile_patch = profile / 'cordis.patch.yml'
        profile_patch.write_bytes(original)
        home_patch = self.dsh_home / 'cordis.patch.yml'
        home_patch.write_bytes(original)
        ctx_cmd = ['node', H.DSH_BIN, '--profile', 'web', '--dump-config']
        run_options = {'side_effect': dump} if isinstance(dump, Exception) else {'return_value': dump}
        with (
            patch.multiple(H, ensure_ports=Mock(), listening=Mock(side_effect=lambda p: p != 3080),
                           alive=Mock(side_effect=lambda n: n != 'dsh'), node_exe=Mock(return_value='node'),
                           restrict=Mock(), spawn=Mock(), wait_port=Mock(return_value=True)),
            patch.object(sync_remote, 'dsh_args', return_value=['--trusted-host', 'example.test']),
            patch.object(H._sync_ctx.subprocess, 'run', **run_options) as config_dump,
        ):
            self.assertTrue(H.start_dsh(self.settings, Mock()))
            H.spawn.assert_called_once()
            args, kwargs = H.spawn.call_args
            config_dump.assert_called_once()
            self.assertEqual(config_dump.call_args.args[0], ctx_cmd)
            self.assertEqual(config_dump.call_args.kwargs['env'], kwargs['env'])
        self.assertEqual(args[0], 'dsh')
        self.assertEqual(kwargs['env']['DSH_TELEMETRY_DISABLED'], '1')
        self.assertEqual(os.environ['DSH_TELEMETRY_DISABLED'], '')
        self.assertEqual(profile_patch.read_bytes(), original)
        self.assertEqual(home_patch.read_bytes(), original)
        privacy = self.root / 'run' / 'dsh-privacy.patch.yml'
        self.assertEqual(privacy.read_text(encoding='utf-8'), DISABLE_PATCH)
        return args[1][args[1].index(H.DSH_BIN) + 1:]

    def test_existing_profile_gets_privacy_patch_after_context_patch(self):
        dump = subprocess.CompletedProcess([], 0, stdout=b'''- id: preset-example
  config:
    - id: compaction-basic
      config:
        headroomTokens: 65536
''')
        args = self.start_with_existing_profile(dump)
        self.assertEqual(args, ['web', '--patch', str(self.root / 'run' / 'dsh-ctx.patch.yml'),
                                '--patch', str(self.root / 'run' / 'dsh-privacy.patch.yml'),
                                '--no-open', '--port', '3080', '--trusted-host', 'example.test'])
        self.assertIn('headroomTokens: 4096', Path(args[2]).read_text(encoding='utf-8'))

    def test_privacy_patch_still_applies_when_context_dump_times_out(self):
        args = self.start_with_existing_profile(subprocess.TimeoutExpired('dsh', 60))
        self.assertEqual(args, ['web', '--patch', str(self.root / 'run' / 'dsh-privacy.patch.yml'),
                                '--no-open', '--port', '3080', '--trusted-host', 'example.test'])


if __name__ == '__main__':
    unittest.main()
