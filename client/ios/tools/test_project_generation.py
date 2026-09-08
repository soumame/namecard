import copy
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

import generate_project as generator


class ProjectGenerationTests(unittest.TestCase):
    def test_regeneration_preserves_signing_and_inherits_release_for_new_beta(self):
        existing = generator.project_data()
        release = existing["objects"][generator.ref("NamecardRelease")]["buildSettings"]
        release.update(DEVELOPMENT_TEAM="EXAMPLE123", CODE_SIGN_STYLE="Manual", CURRENT_PROJECT_VERSION="42", MARKETING_VERSION="0.2.0")
        release["CODE_SIGN_IDENTITY[sdk=iphoneos*]"] = "Apple Distribution"
        del existing["objects"][generator.ref("NamecardBeta")]
        updated = generator.project_data(existing)
        for config in ["Release", "Beta"]:
            settings = updated["objects"][generator.ref("Namecard" + config)]["buildSettings"]
            for key in ["DEVELOPMENT_TEAM", "CODE_SIGN_STYLE", "CURRENT_PROJECT_VERSION", "MARKETING_VERSION", "CODE_SIGN_IDENTITY[sdk=iphoneos*]"]:
                self.assertEqual(settings[key], release[key])
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "project.pbxproj"
            path.write_text(generator.render(updated))
            self.assertEqual(generator.canonical(generator.read_project(path)), generator.canonical(updated))

    def test_check_accepts_xcode_formatting_but_rejects_distribution_flag_changes(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(generator, "ROOT", Path(directory)):
            with patch.object(sys, "argv", ["generate_project.py"]):
                generator.main()
            path = Path(directory) / "Namecard.xcodeproj/project.pbxproj"
            data = generator.read_project(path)
            for obj in data["objects"].values():
                if obj["isa"] == "PBXFileSystemSynchronizedRootGroup":
                    obj.pop("explicitFileTypes")
                    obj.pop("explicitFolders")
            settings = data["objects"][generator.ref("NamecardRelease")]["buildSettings"]
            settings["DEVELOPMENT_TEAM"] = "LOCALTEAM1"
            path.write_text("// Xcode formatting\n" + generator.render(data).replace("\n", "\n\n"))
            with patch.object(sys, "argv", ["generate_project.py", "--check"]):
                generator.main()
                settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] += " NAMECARD_BETA"
                path.write_text(generator.render(data))
                with self.assertRaises(SystemExit):
                    generator.main()

    def test_beta_archive_and_optimized_flags_are_separate_from_store_and_hardware(self):
        data = generator.project_data()
        for scheme_config in ["Debug", "HardwareTest", "Beta"]:
            scheme = generator.ET.fromstring(generator.scheme(scheme_config))
            self.assertEqual(scheme.find("ArchiveAction").get("buildConfiguration"),
                             "Beta" if scheme_config == "Beta" else "Release")
        for config in generator.configs:
            settings = data["objects"][generator.ref("Namecard" + config)]["buildSettings"]
            flags = settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"].split()
            self.assertEqual("NAMECARD_BETA" in flags, config == "Beta")
            self.assertEqual("HARDWARE_TESTING" in flags, config == "HardwareTest")
            if config in {"Release", "Beta"}:
                self.assertNotIn("DEBUG", flags)
                self.assertEqual(settings["SWIFT_OPTIMIZATION_LEVEL"], "-O")
        altered = copy.deepcopy(data)
        altered["objects"][generator.ref("NamecardBeta")]["buildSettings"]["NAMECARD_DISTRIBUTION_CHANNEL"] = "app-store"
        self.assertNotEqual(generator.canonical(altered), generator.canonical(generator.project_data(altered)))


if __name__ == "__main__":
    unittest.main()
