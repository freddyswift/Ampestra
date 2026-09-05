"""Release orchestration tests. All git, GitHub and packaging calls are stubs."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="ampestra-release-tests-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / "script").mkdir()
        (self.root / "Sources/Ampestra").mkdir(parents=True)
        (self.root / "bin").mkdir()
        for name in ["release.sh", "release_preflight.sh"]:
            shutil.copy(ROOT / "script" / name, self.root / "script" / name)
        shutil.copy(ROOT / "Sources/Ampestra/Info.plist", self.root / "Sources/Ampestra/Info.plist")
        metadata = plistlib.loads((ROOT / "Sources/Ampestra/Info.plist").read_bytes())
        self.version = metadata["CFBundleShortVersionString"]
        self.build = metadata["CFBundleVersion"]
        self.tag = "v" + self.version
        self.env = dict(os.environ, PATH=str(self.root / "bin") + os.pathsep + os.environ["PATH"],
                        CODESIGN_IDENTITY="Test Developer ID", NOTARY_PROFILE="stub", SPARKLE_PUBLIC_ED_KEY="stub",
                        TEST_ROOT=str(self.root), TEST_HEAD="a" * 40, TEST_REMOTE="a" * 40,
                        TEST_LOCAL="", TEST_EXISTS="false", RELEASE_DIR=str(self.root / "dist"))
        self.write_executable("script/package_release.sh", '#!/bin/bash\nprintf "packaged" > "$TEST_ROOT/packaged"\n')
        self.write_executable("bin/git", '''#!/usr/bin/env python3
import os, sys
a = sys.argv[1:]
if a[:1] == ['-C']: a = a[2:]
if a[0] == 'rev-parse': print(os.environ.get('TEST_LOCAL') if 'refs/tags/' in a[-1] else os.environ['TEST_HEAD'])
elif a[0] == 'show-ref': sys.exit(0 if os.environ.get('TEST_LOCAL') else 1)
elif a[0] == 'ls-remote':
    value = os.environ['TEST_REMOTE']
    if value == 'error': sys.exit(128)
    if not value: sys.exit(2)
    print(value + '\\t' + a[-1])
elif a[0] not in ['diff', 'ls-files']: sys.exit(99)
''')
        self.write_executable("bin/gh", '''#!/usr/bin/env python3
import json, os, pathlib, sys
a = sys.argv[1:]
root = pathlib.Path(os.environ['TEST_ROOT'])
with (root / 'gh-log').open('a') as f: f.write(json.dumps(a) + '\\n')
if a[0] == 'repo': print('test/ampestra')
elif a[0] == 'api':
    if os.environ.get('TEST_API_ERROR'):
        print('network unavailable', file=sys.stderr); sys.exit(1)
    if os.environ['TEST_EXISTS'] != 'true':
        print('gh: Not Found (HTTP 404)', file=sys.stderr); sys.exit(1)
elif a[:2] in [['release', 'edit'], ['release', 'create']]:
    i = a.index('--notes-file')
    (root / 'published-notes').write_text(pathlib.Path(a[i + 1]).read_text())
elif a[:2] != ['release', 'upload']: sys.exit(99)
''')

    def write_executable(self, name, text):
        path = self.root / name
        path.write_text(text)
        path.chmod(0o755)

    def run_release(self, *extra, version=None, build=None, tag=None):
        return subprocess.run(["bash", str(self.root / "script/release.sh"),
                               version or self.version, "--build", build or self.build,
                               "--tag", tag or self.tag, "--notes", "## Fixes\n\n- Literal `code` and $value.",
                               "--upload", "--yes", *extra], cwd=self.root, env=self.env,
                              capture_output=True, text=True)

    def assert_stopped_before_packaging(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse((self.root / "packaged").exists(), result.stdout)

    def test_remote_tag_mismatch_stops_before_packaging(self):
        self.env['TEST_REMOTE'] = 'b' * 40
        self.assert_stopped_before_packaging(self.run_release())

    def test_local_tag_mismatch_stops_before_packaging(self):
        self.env['TEST_LOCAL'] = 'b' * 40
        self.assert_stopped_before_packaging(self.run_release())

    def test_remote_lookup_failure_stops_before_packaging(self):
        self.env['TEST_REMOTE'] = 'error'
        self.assert_stopped_before_packaging(self.run_release())

    def test_metadata_mismatch_stops_before_packaging(self):
        self.assert_stopped_before_packaging(self.run_release(build=str(int(self.build) + 1)))

    def test_invalid_tag_stops_before_packaging(self):
        self.assert_stopped_before_packaging(self.run_release(tag='v999.0.0'))

    def test_existing_release_requires_explicit_replacement(self):
        self.env['TEST_EXISTS'] = 'true'
        self.assert_stopped_before_packaging(self.run_release())

    def test_github_failure_is_not_treated_as_missing_release(self):
        self.env['TEST_API_ERROR'] = 'true'
        self.assert_stopped_before_packaging(self.run_release())

    def test_new_release_preserves_multiline_notes_and_commit(self):
        self.env['TEST_REMOTE'] = ''
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / 'published-notes').read_text(), '## Fixes\n\n- Literal `code` and $value.\n')
        calls = [json.loads(line) for line in (self.root / 'gh-log').read_text().splitlines()]
        create = next(call for call in calls if call[:2] == ['release', 'create'])
        self.assertEqual(create[create.index('--target') + 1], self.env['TEST_HEAD'])

    def test_replacement_updates_release_notes_without_deleting_assets(self):
        self.env['TEST_EXISTS'] = 'true'
        result = self.run_release('--replace-assets')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Literal `code` and $value.', (self.root / 'published-notes').read_text())
        calls = [json.loads(line) for line in (self.root / 'gh-log').read_text().splitlines()]
        self.assertFalse(any(call[:2] == ['release', 'delete-asset'] for call in calls))
        self.assertTrue(any(call[:2] == ['release', 'edit'] for call in calls))
