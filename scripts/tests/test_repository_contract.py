import importlib.util
import json
import shutil
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "check-repository.py"
SPEC = importlib.util.spec_from_file_location("check_repository", SCRIPT)
CHECKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKER)


def manifest():
    return {
        "platforms": [{"platformName": platform}
                      for platform in ("ios", "macos", "tvos", "watchos", "visionos")],
        "targets": [
            {"name": "SampleCore", "type": "regular"},
            {"name": "SampleCoreTests", "type": "test"},
        ],
    }


class PackageContractTests(unittest.TestCase):
    def test_upstream_debt_does_not_waive_new_strings_or_other_files(self):
        debt = {'apps/Vendor/View.swift': ['Existing']}
        check = CHECKER.localized_or_recorded_debt
        self.assertTrue(check('apps/Vendor/View.swift', 'Existing', {}, debt))
        self.assertFalse(check('apps/Vendor/View.swift', 'New copy', {}, debt))
        self.assertFalse(check('apps/New/View.swift', 'Existing', {}, debt))
        self.assertTrue(check('apps/New/View.swift', 'New copy', {'New copy': {}}, debt))

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.package = Path(self.temporary.name) / "SampleCore"
        (self.package / "Sources/SampleCore").mkdir(parents=True)
        (self.package / "Tests/SampleCoreTests").mkdir(parents=True)

    def test_conventional_multiplatform_package_is_accepted(self):
        CHECKER.validate_swift_package(self.package, manifest())

    def test_missing_platform_is_reported_before_xcode_build(self):
        package = manifest()
        package["platforms"] = [platform for platform in package["platforms"]
                                if platform["platformName"] != "watchos"]
        with self.assertRaisesRegex(ValueError, "every Apple platform: watchos"):
            CHECKER.validate_swift_package(self.package, package)

    def test_target_redirected_to_app_source_is_rejected(self):
        package = manifest()
        package["targets"][0]["path"] = "../../apps/Munie"
        with self.assertRaisesRegex(ValueError, "must use Sources/SampleCore"):
            CHECKER.validate_swift_package(self.package, package)

    def test_manifest_target_with_missing_sources_is_rejected(self):
        (self.package / "Tests/SampleCoreTests").rmdir()
        with self.assertRaisesRegex(ValueError, "Missing SwiftPM target source directory"):
            CHECKER.validate_swift_package(self.package, manifest())


def project_graph():
    return {"objects": {
        "app": {"isa": "PBXNativeTarget", "name": "Munie",
                "productType": "com.apple.product-type.application",
                "buildConfigurationList": "app-list"},
        "watch": {"isa": "PBXNativeTarget", "name": "MunieWatch",
                  "productType": "com.apple.product-type.application",
                  "buildConfigurationList": "watch-list"},
        "app-list": {"buildConfigurations": ["app-debug"]},
        "watch-list": {"buildConfigurations": ["watch-debug"]},
        "app-debug": {"buildSettings": {
            "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator macosx appletvos "
                                   "appletvsimulator xros xrsimulator",
            "TARGETED_DEVICE_FAMILY[sdk=iphone*]": "1,2"}},
        "watch-debug": {"buildSettings": {"SDKROOT": "watchos"}},
    }}


class XcodeProjectContractTests(unittest.TestCase):
    def test_native_multiplatform_app_and_separate_watch_are_accepted(self):
        CHECKER.validate_xcode_project(project_graph())

    def test_iphone_only_device_family_does_not_claim_ipados_support(self):
        project = project_graph()
        project["objects"]["app-debug"]["buildSettings"]["TARGETED_DEVICE_FAMILY[sdk=iphone*]"] = "1"
        with self.assertRaisesRegex(ValueError, "both iPhone and iPad"):
            CHECKER.validate_xcode_project(project)

    def test_watch_target_with_wrong_sdk_is_rejected(self):
        project = project_graph()
        project["objects"]["watch-debug"]["buildSettings"]["SDKROOT"] = "iphoneos"
        with self.assertRaisesRegex(ValueError, "native watchOS SDK"):
            CHECKER.validate_xcode_project(project)

    def test_watch_content_cannot_be_embedded_into_macos_tvos_and_visionos(self):
        project = project_graph()
        project["objects"]["app"]["dependencies"] = ["watch-dependency"]
        project["objects"]["watch-dependency"] = {"target": "watch"}
        with self.assertRaisesRegex(ValueError, "Do not embed the standalone Watch app"):
            CHECKER.validate_xcode_project(project)


class IdentityResearchArchiveTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        source = SCRIPT.parents[1]
        self.archive = self.root / 'references/licenses/device-identity'
        shutil.copytree(source / 'references/licenses/device-identity', self.archive)
        fixture = self.root / 'scripts/fixtures/device-identity'
        fixture.mkdir(parents=True)
        self.lock = fixture / 'Package.resolved'
        shutil.copy2(source / 'scripts/fixtures/device-identity/Package.resolved', self.lock)

    def test_reviewed_lock_and_original_notices_pass_offline(self):
        CHECKER.check_identity_research(self.root)

    def test_notice_change_is_rejected_without_rewriting_original(self):
        notice = self.archive / 'swift-certificates-NOTICE.txt'
        notice.write_bytes(notice.read_bytes() + b'changed')
        with self.assertRaisesRegex(ValueError, 'archive bytes changed'):
            CHECKER.check_identity_research(self.root)

    def test_extra_or_changed_resolution_is_rejected(self):
        original = self.lock.read_text()
        for duplicate in (False, True):
            lock = json.loads(original)
            if duplicate:
                lock['pins'].append(lock['pins'][0])
            else:
                lock['pins'][0]['state']['revision'] = '0' * 40
            self.lock.write_text(json.dumps(lock))
            with self.subTest(duplicate=duplicate), self.assertRaisesRegex(ValueError, 'lock does not match'):
                CHECKER.check_identity_research(self.root)


if __name__ == "__main__":
    unittest.main()
