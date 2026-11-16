import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "build-apple-platforms.sh"


class BuildPipelineTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "scripts").mkdir()
        (self.root / "bin").mkdir()
        shutil.copyfile(SCRIPT, self.root / "scripts/build-apple-platforms.sh")
        bootstrap = self.root / "scripts/bootstrap.sh"
        bootstrap.write_text("#!/bin/bash\nexit 0\n")
        bootstrap.chmod(0o755)
        xcodebuild = self.root / "bin/xcodebuild"
        xcodebuild.write_text('''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

arguments = sys.argv[1:]
with Path(os.environ["BUILD_INVOCATIONS"]).open("a") as log:
    log.write(json.dumps(arguments) + "\\n")
configuration = arguments[arguments.index("-configuration") + 1]
print("Synthetic " + configuration + " build output", flush=True)
if configuration == os.environ.get("FAIL_CONFIGURATION"):
    print("Synthetic build failure", file=sys.stderr)
    sys.exit(42)
''')
        xcodebuild.chmod(0o755)
        self.invocations = self.root / "invocations.jsonl"
        self.environment = dict(os.environ,
                                PATH=f"{self.root / 'bin'}{os.pathsep}{os.environ['PATH']}",
                                BUILD_INVOCATIONS=str(self.invocations))

    def run_pipeline(self, failure=None):
        environment = dict(self.environment)
        if failure:
            environment["FAIL_CONFIGURATION"] = failure
        else:
            environment.pop("FAIL_CONFIGURATION", None)
        result = subprocess.run(["bash", str(self.root / "scripts/build-apple-platforms.sh")],
                                cwd=self.root, env=environment, capture_output=True, text=True)
        commands = [json.loads(line) for line in self.invocations.read_text().splitlines()]
        return result, commands

    def test_pipeline_also_compiles_unsigned_device_release_with_its_own_log(self):
        result, commands = self.run_pipeline()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        release = [command for command in commands
                   if command[command.index("-configuration") + 1] == "Release"]
        self.assertEqual(len(release), 1, "Normal validation must compile the app Release path")
        command = release[0]
        self.assertEqual(command[command.index("-destination") + 1], "generic/platform=iOS")
        self.assertEqual(command[command.index("-scheme") + 1], "Munie")
        self.assertIn("CODE_SIGNING_ALLOWED=NO", command)
        self.assertEqual(command[-1], "build")
        self.assertEqual(len(commands), 6)
        self.assertIn("Synthetic Release build output",
                      (self.root / "build/ios-release-build.log").read_text())

    def test_release_failure_fails_validation_and_preserves_diagnostic_output(self):
        result, commands = self.run_pipeline(failure="Release")
        self.assertNotEqual(result.returncode, 0,
                            "A failed Release compile must not report a passing pipeline")
        self.assertEqual(commands[-1][commands[-1].index("-configuration") + 1], "Release")
        self.assertIn("Synthetic build failure", result.stdout + result.stderr)
        self.assertIn("Synthetic build failure",
                      (self.root / "build/ios-release-build.log").read_text())
        self.assertNotIn("All Apple platform builds passed", result.stdout)

    def test_earlier_debug_failure_stops_before_release(self):
        result, commands = self.run_pipeline(failure="Debug")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(commands), 1)
        self.assertFalse((self.root / "build/ios-release-build.log").exists())
        self.assertIn("Synthetic build failure", (self.root / "build/ios-build.log").read_text())


if __name__ == "__main__":
    unittest.main()
