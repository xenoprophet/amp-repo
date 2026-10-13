import copy
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import tomllib
import unittest


ROOT = Path(__file__).resolve().parents[1]


def load_json(name):
    return json.loads((ROOT / name).read_text(encoding="utf-8"))


class ConfigurationTests(unittest.TestCase):
    def setUp(self):
        scratch = ROOT / ".test-tmp"
        scratch.mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="s1 amp config ", dir=scratch)
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.userdata = self.base / "UserData"
        self.userdata.mkdir()
        self.target = self.userdata / "server_config.toml"
        self.defaults = load_json("schedule1settings.json")
        self.settings = copy.deepcopy(self.defaults)
        # Model AMP writing UI strings into its JSON AutoMap configuration.
        for control in load_json("schedule1config.json"):
            path = control.get("ParamFieldName")
            if path and "DefaultValue" in control:
                section, key = path.split(".", 1)
                self.settings[section][key] = control["DefaultValue"]
        shutil.copyfile(ROOT / "schedule1settings.json", self.base / "AMP_server_settings.default.json")
        shutil.copyfile(ROOT / "schedule1server_config.toml", self.base / "AMP_server_config.default.toml")

    def run_converter(self, success=True):
        (self.base / "AMP_server_settings.json").write_text(
            json.dumps(self.settings, ensure_ascii=False), encoding="utf-8"
        )
        result = subprocess.run(
            ["powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
             "-File", str(ROOT / "schedule1writeconfig.ps1"), "-BaseDirectory", str(self.base)],
            text=True, capture_output=True, timeout=30,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return tomllib.loads(self.target.read_text(encoding="utf-8-sig"))
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_first_start_creates_typed_toml_with_amp_ports(self):
        self.settings["server"]["serverPort"] = "39001"
        self.settings["authentication"]["steamGameServerQueryPort"] = "28001"
        self.settings["gameplay"]["timeProgressionMultiplier"] = "1.25"
        data = self.run_converter()
        self.assertEqual(data["server"]["serverPort"], 39001)
        self.assertEqual(data["authentication"]["steamGameServerQueryPort"], 28001)
        self.assertEqual(data["gameplay"]["timeProgressionMultiplier"], 1.25)
        self.assertIs(data["autosave"]["autoSaveEnabled"], True)
        self.assertEqual(data["logging"]["enabledLoggingOptions"], ["logPlayerActions", "logAdminCommands"])
        self.assertFalse(self.target.read_bytes().startswith(b"\xef\xbb\xbf"))
        self.assertFalse((self.userdata / "permissions.toml").exists())
        self.assertFalse(self.target.with_suffix(".toml.before-amp.bak").exists())
        self.assertTrue((self.base / "AMP_server_config.initialized").exists())

    def test_quotes_paths_unicode_and_empty_logging(self):
        name = 'James\' "Schedule" # server — café'
        password = 'a\'"\\$`#\n\tpassword'
        save = r"C:\Users\James\Saved Games\Schedule I\SaveGame_1"
        self.settings["server"]["serverName"] = name
        self.settings["server"]["serverPassword"] = password
        self.settings["storage"]["saveGamePath"] = save
        self.settings["logging"]["enabledLoggingOptions"] = ""
        data = self.run_converter()
        self.assertEqual(data["server"]["serverName"], name)
        self.assertEqual(data["server"]["serverPassword"], password)
        self.assertEqual(data["storage"]["saveGamePath"], save)
        self.assertEqual(data["logging"]["enabledLoggingOptions"], [])

    def test_existing_config_backup_permissions_and_unknown_keys_survive(self):
        original = ((ROOT / "schedule1server_config.toml").read_text(encoding="utf-8")
                    .replace("enabledLoggingOptions = ['logPlayerActions', 'logAdminCommands']",
                             "enabledLoggingOptions = [\n  'logPlayerActions',\n  'logAdminCommands',\n]")
                    + "\n# Future mod settings\n[futureMod]\ncustomValue = 'keep me'\n")
        self.target.write_text(original, encoding="utf-8")
        original_bytes = self.target.read_bytes()
        permissions = self.userdata / "permissions.toml"
        permission_bytes = b"[user.76561198012345678]\ngroups = ['administrator']\n"
        permissions.write_bytes(permission_bytes)
        data = self.run_converter()
        self.assertEqual(data["futureMod"]["customValue"], "keep me")
        self.assertIn("# Future mod settings", self.target.read_text(encoding="utf-8"))
        backup = Path(str(self.target) + ".before-amp.bak")
        self.assertEqual(backup.read_bytes(), original_bytes)
        self.settings["server"]["serverName"] = "Second launch"
        data = self.run_converter()
        self.assertEqual(data["server"]["serverName"], "Second launch")
        self.assertEqual(backup.read_bytes(), original_bytes)
        self.assertEqual(permissions.read_bytes(), permission_bytes)

    def test_missing_managed_sections_and_keys_are_added(self):
        self.target.write_text("[server]\nserverName = 'old'\ncustomFlag = true\n", encoding="utf-8")
        data = self.run_converter()
        self.assertIs(data["server"]["customFlag"], True)
        self.assertEqual(set(data), set(self.defaults))
        for section, entries in self.defaults.items():
            self.assertTrue(set(entries).issubset(data[section]))

    def test_invalid_values_leave_original_untouched(self):
        original = b"[server]\nserverName = 'do not replace'\n"
        self.target.write_bytes(original)
        bad_values = [
            ("server", "serverPort", "70000"),
            ("server", "maxPlayers", "0"),
            ("autosave", "autoSaveEnabled", "yes"),
            ("autosave", "autoSaveIntervalMinutes", "NaN"),
            ("gameplay", "timeProgressionMultiplier", "1,5"),
            ("performance", "targetFrameRate", "1.2"),
            ("logging", "enabledLoggingOptions", "notALogOption"),
        ]
        baseline = copy.deepcopy(self.settings)
        for section, key, value in bad_values:
            with self.subTest(setting=f"{section}.{key}"):
                self.settings = copy.deepcopy(baseline)
                self.settings[section][key] = value
                self.run_converter(success=False)
                self.assertEqual(self.target.read_bytes(), original)
                self.assertFalse((self.base / "AMP_server_config.initialized").exists())
                self.assertFalse(Path(str(self.target) + ".amp.tmp").exists())

    def test_support_files_are_required(self):
        (self.base / "AMP_server_settings.default.json").unlink()
        self.run_converter(success=False)
        self.assertFalse(self.target.exists())

    def test_template_mappings_and_downloads_are_complete(self):
        config = load_json("schedule1config.json")
        fields = [item["FieldName"] for item in config]
        self.assertEqual(len(fields), len(set(fields)))
        paths = {item["ParamFieldName"] for item in config if "ParamFieldName" in item}
        self.assertEqual(paths, {f"{section}.{key}" for section, entries in self.defaults.items() for key in entries})
        source = tomllib.loads((ROOT / "schedule1server_config.toml").read_text(encoding="utf-8"))
        self.assertEqual(paths, {f"{section}.{key}" for section, entries in source.items() for key in entries})
        ports = {"$" + p["Ref"] for p in load_json("schedule1ports.json")}
        self.assertEqual(ports, {f for f in fields if f.startswith("$")})
        downloads = {}
        for stage in load_json("schedule1updates.json"):
            if stage["UpdateSource"] == "FetchURL":
                file = stage["UpdateSourceData"].rsplit("/", 1)[1]
                self.assertTrue((ROOT / file).is_file(), file)
                downloads[stage["UpdateSourceArgs"]] = stage
        self.assertFalse(downloads["AMP_server_settings.json"]["OverwriteExistingFiles"])
        for required in ["AMP_server_settings.default.json", "AMP_server_config.default.toml", "AMP_WriteServerConfig.ps1"]:
            self.assertIn(required, downloads)
        kvp = (ROOT / "schedule1.kvp").read_text(encoding="utf-8")
        self.assertIn("Meta.MetaConfigManifest=schedule1metaconfig.json", kvp)
        self.assertIn("App.PreStartStages=@IncludeJson[schedule1prestart.json]", kvp)
        self.assertNotIn('--server-name', kvp)


if __name__ == "__main__":
    unittest.main()
