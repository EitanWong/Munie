import importlib.util
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


if __name__ == "__main__":
    unittest.main()
