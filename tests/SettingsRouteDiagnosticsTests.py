"""Compile-only privacy guard for the explicitly enabled local route trace."""
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "native/Omnibar/Omnibar"


class SettingsRouteDiagnosticsTests(unittest.TestCase):
    def compile_probe(self, directory, definition):
        source = directory / "probe.m"
        source.write_text('#import "OmnibarSettingsRouteDiagnostics.h"\n'
                          'int main(void) { unsigned value = 0; '
                          'OmnibarTraceSettingsRoute(++value); return (int)value; }\n')
        binary = directory / ("probe-" + (definition or "default"))
        command = ["xcrun", "--sdk", "macosx", "clang", "-fobjc-arc", "-fblocks",
                   "-Wall", "-Wextra", "-Werror", "-mmacosx-version-min=13.0",
                   "-framework", "Foundation", "-I", str(APP), str(source), "-o", str(binary)]
        if definition is not None:
            command.append("-DOMNIBAR_SETTINGS_ROUTE_DIAGNOSTICS=" + definition)
        subprocess.run(command, check=True, capture_output=True)
        symbols = subprocess.run(["nm", "-u", str(binary)], check=True,
                                 capture_output=True, text=True).stdout
        return binary, symbols

    def test_default_and_explicitly_disabled_trace_compile_out(self):
        with tempfile.TemporaryDirectory(prefix="omnibar-route-guard-") as temporary:
            directory = Path(temporary)
            for definition in (None, "0"):
                binary, symbols = self.compile_probe(directory, definition)
                self.assertNotIn(b"com.dkaluta.omnibar.settings-route", binary.read_bytes())
                self.assertNotIn("_os_log_create", symbols)
                self.assertNotIn("_os_log_impl", symbols)
                # Even argument evaluation disappears when the trace is off.
                self.assertEqual(subprocess.run([str(binary)]).returncode, 0)

    def test_explicit_diagnostic_binary_contains_only_fixed_numeric_format(self):
        with tempfile.TemporaryDirectory(prefix="omnibar-route-guard-") as temporary:
            binary, symbols = self.compile_probe(Path(temporary), "1")
            data = binary.read_bytes()
            self.assertIn(b"com.dkaluta.omnibar.settings-route", data)
            self.assertIn(b"stage=%{public}u", data)
            self.assertIn("_os_log_create", symbols)
            self.assertIn("_os_log_impl", symbols)
            # The enabled fixture is deliberately never run or logged.


if __name__ == "__main__":
    unittest.main()
