"""Exercise failed source builds with isolated, stubbed process commands."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class SourceBuildTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="ampestra-source-tests-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / "script").mkdir()
        (self.root / "bin").mkdir()
        for name in ["build_and_run.sh", "install_app.sh", "stable_launcher_ids.sh"]:
            shutil.copy(ROOT / "script" / name, self.root / "script" / name)
        self.write_executable("script/swift.sh", "#!/bin/bash\nexit 42\n")
        self.write_executable("bin/pgrep", "#!/bin/bash\nexit 0\n")
        self.write_executable("bin/killall", '#!/bin/bash\ntouch "$TEST_ROOT/closed-app"\n')
        self.env = dict(os.environ, PATH=str(self.root / "bin") + os.pathsep + os.environ["PATH"],
                        CODESIGN_IDENTITY="-", TEST_ROOT=str(self.root))

    def write_executable(self, name, content):
        path = self.root / name
        path.write_text(content)
        path.chmod(0o755)

    def assert_failed_build_keeps_app_running(self, script, *arguments):
        result = subprocess.run(["bash", str(self.root / "script" / script), *arguments],
                                cwd=self.root, env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertFalse((self.root / "closed-app").exists(), result.stdout)
        self.assertFalse((self.root / "dist").exists(), result.stdout)

    def test_failed_development_build_keeps_app_running(self):
        self.assert_failed_build_keeps_app_running("build_and_run.sh")

    def test_failed_source_install_keeps_app_running(self):
        self.assert_failed_build_keeps_app_running("install_app.sh", "--yes", "--no-open")
