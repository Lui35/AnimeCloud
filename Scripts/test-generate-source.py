import importlib.util
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
import zipfile

sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location("source", Path(__file__).with_name("generate-source.py"))
source = importlib.util.module_from_spec(spec)
spec.loader.exec_module(source)


class SourceTests(unittest.TestCase):
    def test_source_matches_ipa_and_release_urls(self):
        with tempfile.TemporaryDirectory() as directory:
            ipa = Path(directory) / "AnimeCloud-v1.2.3-unsigned.ipa"
            info = {"CFBundleIdentifier": "com.animecloud.reborn", "CFBundleShortVersionString": "1.2.3",
                    "CFBundleVersion": "42", "MinimumOSVersion": "17.0",
                    "NSPhotoLibraryUsageDescription": "Choose an avatar."}
            with zipfile.ZipFile(ipa, "w") as archive:
                archive.writestr("Payload/AnimeCloud.app/Info.plist", plistlib.dumps(info))
            feed = source.generate_source(ipa, "v1.2.3", "Lui35/AnimeCloud", "2026-11-21")
            app = feed["apps"][0]
            version = app["versions"][0]
            self.assertEqual(version["version"], "1.2.3")
            self.assertEqual(version["buildVersion"], "42")
            self.assertEqual(version["size"], ipa.stat().st_size)
            self.assertEqual(version["minOSVersion"], "17.0")
            self.assertEqual(version["downloadURL"], "https://github.com/Lui35/AnimeCloud/releases/download/v1.2.3/AnimeCloud-v1.2.3-unsigned.ipa")
            self.assertEqual(app["downloadURL"], version["downloadURL"])
            self.assertEqual(feed["sourceURL"], "https://github.com/Lui35/AnimeCloud/releases/latest/download/source.json")
            with self.assertRaisesRegex(ValueError, "tag"):
                source.generate_source(ipa, "v9.0.0", "Lui35/AnimeCloud", "2026-11-21")
            info["CFBundleIdentifier"] = "wrong.app"
            with zipfile.ZipFile(ipa, "w") as archive:
                archive.writestr("Payload/AnimeCloud.app/Info.plist", plistlib.dumps(info))
            with self.assertRaisesRegex(ValueError, "bundle identifier"):
                source.generate_source(ipa, "v1.2.3", "Lui35/AnimeCloud", "2026-11-21")

    def test_rejects_archive_without_an_app(self):
        with tempfile.TemporaryDirectory() as directory:
            ipa = Path(directory) / "invalid.ipa"
            with zipfile.ZipFile(ipa, "w") as archive:
                archive.writestr("README.txt", "Not an app")
            with self.assertRaisesRegex(ValueError, "Info.plist"):
                source.generate_source(ipa, "v1.0.0", "Lui35/AnimeCloud", "2026-11-21")


if __name__ == "__main__":
    unittest.main()
