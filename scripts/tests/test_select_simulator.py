import importlib.util
from pathlib import Path
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "select-simulator.py"
SPEC = importlib.util.spec_from_file_location("select_simulator", SCRIPT)
SELECTOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SELECTOR)


def runtime(value):
    return "com.apple.CoreSimulator.SimRuntime.iOS-" + value


def phone(identifier, available=True, state="Shutdown", name="iPhone 17"):
    return {"udid": identifier, "name": name, "isAvailable": available, "state": state}


class SimulatorSelectionTests(unittest.TestCase):
    def test_newest_supported_runtime_wins_over_old_or_future_runtime(self):
        devices = {
            runtime("18-5"): [phone("old")],
            runtime("26-2"): [phone("matching")],
            runtime("27-0"): [phone("future")],
        }
        self.assertEqual(SELECTOR.select_device(devices, "26.2"), "matching")

    def test_unavailable_and_non_phone_devices_are_excluded(self):
        devices = {
            runtime("26-2"): [phone("missing", False), phone("ipad", name="iPad Pro")],
            runtime("26-1"): [phone("valid")],
            "com.apple.CoreSimulator.SimRuntime.watchOS-26-2": [phone("watch")],
        }
        self.assertEqual(SELECTOR.select_device(devices, "26.2"), "valid")

    def test_booted_device_is_preferred_within_the_same_runtime(self):
        devices = {runtime("26-2"): [phone("z-shutdown"), phone("a-booted", state="Booted")]}
        self.assertEqual(SELECTOR.select_device(devices, "26.2.0"), "a-booted")

    def test_missing_compatible_device_is_a_failure(self):
        with self.assertRaisesRegex(ValueError, "No available iPhone simulator"):
            SELECTOR.select_device({runtime("27-0"): [phone("future")]}, "26.2")


if __name__ == "__main__":
    unittest.main()
