"""Exercise installation ordering and rollback using disposable bundles."""
import importlib.util
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import Mock

spec = importlib.util.spec_from_file_location("install_local", Path(__file__).with_name("install-local.py"))
installer = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = installer
spec.loader.exec_module(installer)


@unittest.skipUnless(sys.platform == "darwin", "Requires macOS atomic bundle exchange")
class StagingTests(unittest.TestCase):
    def setUp(self):
        temp = TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name).resolve()
        self.stage = root / "stage"
        self.stage.mkdir(mode=0o700)
        self.target = root / "installed" / "OpenDente.app"
        self.candidate = root / "candidate" / "OpenDente.app"
        for bundle, content in [(self.target, "old"), (self.candidate, "new")]:
            for path in [installer.HELPER, installer.DAEMON]:
                (bundle / path).parent.mkdir(parents=True, exist_ok=True)
                (bundle / path).write_text(path.name)
            (bundle / "version").write_text(content)
        config = installer.Configuration(self.candidate, self.target, self.stage, root, root / "baseline",
            "test", "test", "1.1", "2", "1.0", "1",
            installer.sha256(self.target / installer.HELPER), installer.sha256(self.target / installer.DAEMON))
        self.app = installer.Installer(config)
        self.app.preflight = Mock(return_value=self.stage)
        self.app.previous_tree = installer.tree_manifest(self.target)
        self.app.candidate_tree = installer.tree_manifest(self.candidate)
        self.app.compatible_sources = Mock(return_value={})
        self.app.report["helperSourceSHA256"] = {}
        self.app.system.gui_processes = Mock(return_value=[])
        self.app.system.sign_app = Mock()
        self.verified = {"helperSHA256": config.installed_helper_sha256,
                         "daemonPlistSHA256": config.installed_plist_sha256}

    def test_private_staging_required(self):
        self.app.verify_staging_directory(self.stage)
        self.stage.chmod(0o755)
        with self.assertRaises(installer.InstallError):
            self.app.verify_staging_directory(self.stage)

    def test_signature_failure_stops_before_retention_or_signing(self):
        self.app.verify_bundle = Mock(side_effect=installer.InstallError("invalid original signature"))
        self.app.retain_file = Mock()
        with self.assertRaisesRegex(installer.InstallError, "invalid original signature"):
            self.app.install()
        verified_path = self.app.verify_bundle.call_args.args[0]
        self.assertTrue(verified_path.is_relative_to(self.stage))
        self.app.retain_file.assert_not_called()
        self.app.system.sign_app.assert_not_called()
        self.assertEqual(installer.tree_manifest(self.target), self.app.previous_tree)

    def test_exchange_retains_backup(self):
        self.app.verify_bundle = Mock(return_value=self.verified)
        result = self.app.install()
        self.assertTrue(result["installed"])
        self.assertEqual((self.target / "version").read_text(), "new")
        self.assertEqual(installer.tree_manifest(Path(result["backupBundle"])), self.app.previous_tree)

    def test_failed_postflight_restores_original_bundle(self):
        self.app.verify_bundle = Mock(side_effect=[self.verified, self.verified,
                                                    installer.InstallError("postflight"), self.verified])
        with self.assertRaisesRegex(installer.InstallError, "original app restored"):
            self.app.install()
        self.assertEqual(installer.tree_manifest(self.target), self.app.previous_tree)


if __name__ == "__main__":
    unittest.main()
