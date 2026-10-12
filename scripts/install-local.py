#!/usr/bin/env python3
"""Install a signed OpenDente GUI without updating its registered daemon.

Never launches/quits an app, invokes SMAppService, or changes preferences/hardware.
Only the already installed, compatible helper and LaunchDaemon plist are retained.
A changed daemon/protocol requires a separate canonical async-unregister upgrade.
"""
from __future__ import annotations

import argparse
import base64
import ctypes
from dataclasses import dataclass
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import struct
import subprocess
import sys
import tempfile

APP_ID = "com.opendente.app"
HELPER_ID = "com.opendente.helper"
HELPER = Path("Contents/Library/HelperTools/com.opendente.helper")
DAEMON = Path("Contents/Library/LaunchDaemons/com.opendente.helper.plist")
RELEASE = Path("Contents/Resources/opendente-release.json")
SHARED_INPUTS = {"OpenDente/Services/SMCService.swift", "OpenDente/Models/BatteryState.swift"}


class InstallError(RuntimeError):
    def __init__(self, message: str, report: dict | None = None):
        super().__init__(message)
        self.report = report


def require(condition: bool, message: str) -> None:
    if not condition:
        raise InstallError(message)


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def version(text: str) -> tuple[int, int, int]:
    require(isinstance(text, str) and re.fullmatch(r"\d{1,6}\.\d{1,6}(?:\.\d{1,6})?", text) is not None,
            f"Invalid numeric version: {text!r}")
    values = tuple(int(x) for x in text.split("."))
    return values + (0,) * (3 - len(values))


def tree_manifest(root: Path) -> dict:
    result = {}
    for current, directories, files in os.walk(root, followlinks=False):
        links = [name for name in directories if (Path(current) / name).is_symlink()]
        directories[:] = [name for name in directories if name not in links]
        for name in files + links:
            path = Path(current) / name
            key = path.relative_to(root).as_posix()
            entry = {"mode": stat.S_IMODE(path.lstat().st_mode)}
            if path.is_symlink():
                require(path.resolve().is_relative_to(root.resolve()), f"Bundle link escapes its root: {path}")
                entry.update(type="symlink", target=os.readlink(path))
            else:
                require(path.is_file(), f"Unexpected bundle entry: {path}")
                entry.update(type="file", size=path.stat().st_size, sha256=sha256(path))
            result[key] = entry
    return result


def embedded_helper_info(path: Path) -> dict:
    """Read __TEXT,__info_plist in every Mach-O architecture; never execute helper.

    Layouts: local SDK mach-o/{fat.h,loader.h}. Section offsets are slice-relative.
    """
    data = path.read_bytes()
    require(len(data) >= 32, "Helper is not a complete Mach-O executable")
    slices = []
    fat = {b"\xca\xfe\xba\xbe": (">", False), b"\xbe\xba\xfe\xca": ("<", False),
           b"\xca\xfe\xba\xbf": (">", True), b"\xbf\xba\xfe\xca": ("<", True)}
    if data[:4] in fat:
        endian, wide = fat[data[:4]]
        count = struct.unpack_from(endian + "I", data, 4)[0]
        require(1 <= count <= 16, "Invalid Mach-O architecture count")
        width = 32 if wide else 20
        require(8 + count * width <= len(data), "Truncated universal Mach-O header")
        for index in range(count):
            values = struct.unpack_from(endian + ("IIQQII" if wide else "IIIII"), data, 8 + index * width)
            offset, length = values[2:4]
            require(length >= 32 and offset + length <= len(data), "Invalid Mach-O slice bounds")
            slices.append(data[offset:offset + length])
    else:
        slices = [data]
    infos = []
    for binary in slices:
        endian = {b"\xcf\xfa\xed\xfe": "<", b"\xfe\xed\xfa\xcf": ">"}.get(binary[:4])
        require(endian is not None, "Only 64-bit Mach-O helpers are supported")
        count, size = struct.unpack_from(endian + "II", binary, 16)
        require(count <= 4096 and 32 + size <= len(binary), "Invalid Mach-O load command bounds")
        cursor, info = 32, None
        for _ in range(count):
            require(cursor + 8 <= 32 + size, "Truncated Mach-O load command")
            command, length = struct.unpack_from(endian + "II", binary, cursor)
            require(length >= 8 and cursor + length <= 32 + size, "Invalid Mach-O load command size")
            if command == 0x19:  # LC_SEGMENT_64; segment_command_64 + section_64[]
                require(length >= 72, "Truncated Mach-O segment")
                sections = struct.unpack_from(endian + "I", binary, cursor + 64)[0]
                require(72 + sections * 80 <= length, "Truncated Mach-O section table")
                for section in range(sections):
                    start = cursor + 72 + section * 80
                    section_name = binary[start:start + 16].split(b"\0", 1)[0]
                    segment_name = binary[start + 16:start + 32].split(b"\0", 1)[0]
                    if section_name == b"__info_plist" and segment_name == b"__TEXT":
                        require(info is None, "Duplicate embedded helper Info.plist")
                        info_size = struct.unpack_from(endian + "Q", binary, start + 40)[0]
                        offset = struct.unpack_from(endian + "I", binary, start + 48)[0]
                        require(0 < info_size <= 65536 and offset + info_size <= len(binary), "Invalid embedded Info.plist bounds")
                        info = plistlib.loads(binary[offset:offset + info_size].rstrip(b"\0"))
            cursor += length
        require(isinstance(info, dict), "Helper has no embedded Info.plist")
        infos.append(info)
    require(all(info == infos[0] for info in infos), "Helper metadata differs between architectures")
    return infos[0]


class MacSystem:
    def run(self, *command: str) -> subprocess.CompletedProcess:
        result = subprocess.run(command, text=True, capture_output=True, timeout=120)
        require(result.returncode == 0, f"Command failed: {command[0]}: {result.stderr.strip()}")
        return result

    def gui_processes(self, context: str) -> list[dict]:
        result = self.run("/bin/ps", "-axww", "-o", "pid=,comm=")
        found = []
        for line in result.stdout.splitlines():
            match = re.match(r"\s*(\d+)\s+(.+)$", line)
            if match and Path(match[2].strip()).name == "OpenDente":
                found.append({"pid": int(match[1]), "executable": match[2].strip()})
        return found

    def verify_signature(self, path: Path, identifier: str, team: str, deep: bool) -> dict:
        requirement = f'identifier "{identifier}" and anchor apple generic and certificate leaf[subject.OU] = "{team}"'
        command = ["/usr/bin/codesign", "--verify", "--strict", "-R", "=" + requirement]
        if deep:
            command.append("--deep")  # Verification only; never deep signing.
        self.run(*command, str(path))
        detail = self.run("/usr/bin/codesign", "-dv", "--verbose=4", str(path)).stderr
        fields = dict(re.findall(r"^(Identifier|TeamIdentifier|CDHash|Authority)=(.*)$", detail, flags=re.MULTILINE))
        require(fields.get("Identifier") == identifier and fields.get("TeamIdentifier") == team,
                f"Code identity mismatch: {path}")
        return fields

    def verify_signing_identity(self, identity: str, team: str) -> dict:
        identities = self.run("/usr/bin/security", "find-identity", "-v", "-p", "codesigning").stdout
        require(identity.upper() in identities.upper(), "Requested signing identity is not valid in the keychain")
        certificates = self.run("/usr/bin/security", "find-certificate", "-a", "-p", "-c", "Apple Development").stdout
        for certificate in re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", certificates, re.DOTALL):
            body = certificate.removeprefix("-----BEGIN CERTIFICATE-----").removesuffix("-----END CERTIFICATE-----")
            der = base64.b64decode(body)
            if hashlib.sha1(der).hexdigest().upper() == identity.upper():
                result = subprocess.run(["/usr/bin/openssl", "x509", "-noout", "-subject", "-nameopt", "RFC2253"],
                                        input=certificate, text=True, capture_output=True, timeout=15)
                require(result.returncode == 0 and re.search(r"(?:^|,)OU=" + team + r"(?:,|$)", result.stdout) is not None,
                        "Selected Apple Development signing identity has a different Team ID")
                return {"identitySHA1": identity.upper(), "team": team}
        raise InstallError("Selected signing identity is not an available Apple Development certificate")

    def sign_app(self, path: Path, identity: str) -> None:
        # codesign(1): explicit preservation avoids losing entitlements on re-sign.
        self.run("/usr/bin/codesign", "--force", "--sign", identity, "--options", "runtime",
                 "--timestamp=none", "--preserve-metadata=identifier,entitlements,flags,runtime", str(path))

    def swap(self, first: Path, second: Path) -> None:
        require(sys.platform == "darwin", "Atomic installation requires macOS renameatx_np")
        # SDK sys/stdio.h: RENAME_SWAP=2, RENAME_NOFOLLOW_ANY=16. No two-rename fallback.
        function = ctypes.CDLL(None, use_errno=True).renameatx_np
        function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        function.restype = ctypes.c_int
        first_fd = os.open(first.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            second_fd = os.open(second.parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                if function(first_fd, os.fsencode(first.name), second_fd, os.fsencode(second.name), 2 | 16) != 0:
                    error = ctypes.get_errno()
                    raise InstallError(f"Atomic bundle exchange failed: {os.strerror(error)}")
            finally:
                os.close(second_fd)
        finally:
            os.close(first_fd)


@dataclass(frozen=True)
class Configuration:
    candidate: Path
    target: Path
    staging_parent: Path
    source_root: Path
    baseline_manifest: Path
    team: str
    identity: str
    expected_version: str
    expected_build: str
    installed_version: str
    installed_build: str
    installed_helper_sha256: str
    installed_plist_sha256: str


class Installer:
    def __init__(self, configuration: Configuration, system: MacSystem | None = None):
        self.config = configuration
        self.system = system or MacSystem()
        self.report = {"schemaVersion": 1, "startedAtUTC": datetime.now(timezone.utc).isoformat(),
                       "mode": "retain-identical-installed-daemon", "installed": False,
                       "rolledBack": False, "guiGuards": []}

    def no_gui(self, context: str) -> None:
        active = self.system.gui_processes(context)
        require(not active, f"OpenDente must be closed before {context}: {active}")
        self.report["guiGuards"].append(context)

    def verify_bundle(self, path: Path, expected_version: str, expected_build: str) -> dict:
        require(path.is_dir() and not path.is_symlink(), f"Expected a regular app directory: {path}")
        info = plistlib.loads((path / "Contents/Info.plist").read_bytes())
        require(info.get("CFBundleIdentifier") == APP_ID and info.get("CFBundleExecutable") == "OpenDente"
                and info.get("CFBundlePackageType") == "APPL", f"Unexpected application identity: {path}")
        require(info.get("CFBundleShortVersionString") == expected_version and str(info.get("CFBundleVersion")) == expected_build,
                f"Unexpected app version/build: {path}")
        app_signature = self.system.verify_signature(path, APP_ID, self.config.team, deep=True)
        helper = path / HELPER
        daemon = path / DAEMON
        require(helper.is_file() and not helper.is_symlink() and daemon.is_file() and not daemon.is_symlink(),
                f"Missing or symlinked helper/plist: {path}")
        helper_signature = self.system.verify_signature(helper, HELPER_ID, self.config.team, deep=False)
        helper_info = embedded_helper_info(helper)
        require(helper_info.get("CFBundleIdentifier") == HELPER_ID, "Unexpected embedded helper identity")
        helper_version = helper_info.get("CFBundleShortVersionString")
        version(helper_version)
        plist = plistlib.loads(daemon.read_bytes())
        require(plist.get("Label") == HELPER_ID and plist.get("BundleProgram") == str(HELPER)
                and plist.get("MachServices") == {HELPER_ID: True}, "Unexpected daemon configuration")
        return {"version": expected_version, "build": expected_build, "appSignature": app_signature,
                "appExecutableSHA256": sha256(path / "Contents/MacOS/OpenDente"),
                "helperSignature": helper_signature, "helperVersion": helper_version,
                "helperBuild": str(helper_info.get("CFBundleVersion")), "helperSHA256": sha256(helper),
                "daemonPlistSHA256": sha256(daemon)}

    def compatible_sources(self) -> dict:
        baseline = json.loads(self.config.baseline_manifest.read_text())
        required = {name for name in baseline if name.startswith(("OpenDenteHelper/", "Shared/"))} | SHARED_INPUTS
        require({"Shared/HelperProtocol.swift", "Shared/HelperConstants.swift", "OpenDenteHelper/main.swift",
                 "OpenDenteHelper/com.opendente.helper.plist"}.issubset(required), "Incomplete helper source baseline")
        actual = {path.relative_to(self.config.source_root).as_posix()
                  for directory in ("OpenDenteHelper", "Shared")
                  for path in (self.config.source_root / directory).rglob("*") if path.is_file() or path.is_symlink()}
        require(actual == {name for name in required if name.startswith(("OpenDenteHelper/", "Shared/"))},
                "Daemon/shared source inventory changed; canonical async-unregister upgrade required")
        hashes = {}
        for name in sorted(required):
            path = self.config.source_root / name
            entry = baseline.get(name, {})
            require(path.is_file() and not path.is_symlink() and entry.get("type") == "file"
                    and sha256(path) == entry.get("sha256"),
                    f"Daemon/protocol input changed: {name}; canonical async-unregister upgrade required")
            hashes[name] = entry["sha256"]
        return hashes

    def preflight(self) -> None:
        c = self.config
        require(re.fullmatch(r"[A-Z0-9]{10}", c.team) is not None, "Invalid signing Team ID")
        require(re.fullmatch(r"[0-9A-Fa-f]{40}", c.identity) is not None, "Use an explicit 40-character signing identity SHA-1")
        require(all(re.fullmatch(r"[0-9a-f]{64}", value) for value in (c.installed_helper_sha256, c.installed_plist_sha256)),
                "Expected installed helper/plist hashes must be explicit SHA-256 values")
        require(c.expected_build.isdigit() and c.installed_build.isdigit() and int(c.expected_build) > int(c.installed_build),
                "New numeric build must be greater than the installed build")
        require(version(c.expected_version) >= version(c.installed_version), "Cannot downgrade the app version")
        require(c.candidate.is_dir() and not c.candidate.is_symlink() and c.target.is_dir() and not c.target.is_symlink(),
                "Candidate and target must exist and cannot be symlinked bundles")
        require(all(path.is_absolute() for path in (c.candidate, c.target, c.staging_parent, c.source_root, c.baseline_manifest)),
                "Use absolute paths for candidate, target, staging and source provenance")
        require(c.candidate.name == "OpenDente.app" and c.target.name == "OpenDente.app", "Expected OpenDente.app bundle paths")
        require(c.candidate.resolve() != c.target.resolve() and not c.candidate.resolve().is_relative_to(c.target.resolve())
                and not c.target.resolve().is_relative_to(c.candidate.resolve()), "Candidate/target paths overlap")
        require(c.staging_parent.is_dir() and not c.staging_parent.is_symlink(), "Staging parent must already exist")
        stage_parent = c.staging_parent.resolve()
        require(not stage_parent.is_relative_to(Path("/Applications")) and not stage_parent.is_relative_to(c.target.resolve())
                and not stage_parent.is_relative_to(c.candidate.resolve()), "Staging must be outside /Applications and both bundles")
        require(stage_parent.stat().st_dev == c.target.parent.stat().st_dev, "Staging and destination must be on the same filesystem")
        self.no_gui("preflight")
        self.report["signingIdentity"] = self.system.verify_signing_identity(c.identity, c.team)
        self.report["helperSourceSHA256"] = self.compatible_sources()
        self.report["candidate"] = self.verify_bundle(c.candidate, c.expected_version, c.expected_build)
        self.report["previous"] = self.verify_bundle(c.target, c.installed_version, c.installed_build)
        require(self.report["previous"]["helperSHA256"] == c.installed_helper_sha256
                and self.report["previous"]["daemonPlistSHA256"] == c.installed_plist_sha256, "Installed helper/plist provenance changed")
        metadata = json.loads((c.candidate / RELEASE).read_text())
        require(metadata.get("schemaVersion") == 1 and metadata.get("appVersion") == c.expected_version, "Invalid bundled release metadata")
        retained_version = self.report["previous"]["helperVersion"]
        require(metadata.get("helperVersion") == retained_version and
                version(metadata["minimumCompatibleHelperVersion"]) <= version(retained_version) <
                version(metadata["maximumExclusiveCompatibleHelperVersion"]), "Installed helper is incompatible with candidate release")
        require(self.report["candidate"]["helperVersion"] == retained_version
                and self.report["candidate"]["helperBuild"] == self.report["previous"]["helperBuild"]
                and self.report["candidate"]["daemonPlistSHA256"] == c.installed_plist_sha256,
                "Candidate daemon definition differs; canonical async-unregister upgrade required")
        self.previous_tree = tree_manifest(c.target)
        self.candidate_tree = tree_manifest(c.candidate)
        self.report["candidateBeforeRetentionManifest"] = self.candidate_tree
        self.report["previousManifest"] = self.previous_tree

    def unchanged_inputs(self) -> None:
        require(tree_manifest(self.config.target) == self.previous_tree, "Installed bundle changed after preflight")
        require(tree_manifest(self.config.candidate) == self.candidate_tree, "Candidate changed after preflight")
        require(self.compatible_sources() == self.report["helperSourceSHA256"], "Helper source inputs changed after preflight")

    def retain_file(self, source: Path, target: Path, expected_hash: str, context: str) -> None:
        self.unchanged_inputs()
        temporary = target.with_name(target.name + ".retained")
        shutil.copy2(source, temporary)
        require(sha256(temporary) == expected_hash, f"Retained file changed while copying: {source}")
        self.no_gui(context)
        os.replace(temporary, target)

    def install(self, dry_run: bool = False) -> dict:
        self.preflight()  # All initial failures happen before any filesystem mutation.
        if dry_run:
            return self.report | {"dryRun": True, "ready": True}
        c = self.config
        self.no_gui("before-staging")
        lock_path = c.staging_parent / (".opendente-install-" + hashlib.sha256(str(c.target.resolve()).encode()).hexdigest()[:16] + ".lock")
        require(not lock_path.is_symlink(), "Refusing a symlinked installation lock")
        descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.unchanged_inputs()
            self.no_gui("before-copy")
            run = Path(tempfile.mkdtemp(prefix="opendente-install-", dir=c.staging_parent))
            stage = run / "OpenDente.app"
            self.report["stagingBundle"] = str(stage)
            self.report["destination"] = str(c.target)
            try:
                shutil.copytree(c.candidate, stage, symlinks=True)
                require(tree_manifest(stage) == self.candidate_tree, "Staged copy differs from candidate")
                self.retain_file(c.target / HELPER, stage / HELPER, c.installed_helper_sha256, "before-helper-replacement")
                self.retain_file(c.target / DAEMON, stage / DAEMON, c.installed_plist_sha256, "before-plist-replacement")
                self.no_gui("before-staging-signature")
                self.system.sign_app(stage, c.identity)  # No --deep; retained helper must not be re-signed.
                self.report["retained"] = self.verify_bundle(stage, c.expected_version, c.expected_build)
                require(self.report["retained"]["helperSHA256"] == c.installed_helper_sha256
                        and self.report["retained"]["daemonPlistSHA256"] == c.installed_plist_sha256,
                        "Signing modified the retained daemon; refusing installation")
                final_tree = tree_manifest(stage)
                self.report["installedManifest"] = final_tree
                self.unchanged_inputs()
                # Persist provenance before exchange, so interrupted installs retain recovery evidence.
                journal = run / "transaction.json"
                self.report["journal"] = str(journal)
                with journal.open("x") as stream:
                    json.dump(self.report | {"phase": "ready-for-atomic-exchange"}, stream, indent=2, sort_keys=True)
                    stream.write("\n")
                    stream.flush()
                    os.fsync(stream.fileno())
                self.no_gui("immediately-before-atomic-exchange")
                self.system.swap(stage, c.target)
                self.report["exchanged"] = True
                self.report["backupBundle"] = str(stage)  # Old signed app remains untouched at the exchange path.
                try:
                    require(tree_manifest(c.target) == final_tree and tree_manifest(stage) == self.previous_tree,
                            "Atomic exchange manifests did not match")
                    self.report["postflight"] = self.verify_bundle(c.target, c.expected_version, c.expected_build)
                    self.report["installed"] = True
                    self.report["requiresGUIPostflight"] = True  # PID stability, XPC version and native policy readback remain required.
                except Exception as error:
                    try:
                        require(tree_manifest(stage) == self.previous_tree, "Backup changed; automatic rollback refused")
                        self.verify_bundle(stage, c.installed_version, c.installed_build)
                        self.no_gui("immediately-before-rollback-exchange")
                        self.system.swap(stage, c.target)
                        require(tree_manifest(c.target) == self.previous_tree, "Rollback manifest did not match original")
                        self.report["rolledBack"] = True
                        self.report["backupBundle"] = None
                        self.report["failedCandidateBundle"] = str(stage)
                    except Exception as rollback_error:
                        self.report["rollbackBlocked"] = str(rollback_error)
                        raise InstallError(f"Postflight failed; rollback could not run safely: {error}; {rollback_error}", self.report) from rollback_error
                    raise InstallError(f"Postflight failed; original app restored: {error}", self.report) from error
            except Exception as error:
                self.report["error"] = str(error)
                raise InstallError(str(error), self.report) from error
        finally:
            os.close(descriptor)
        return self.report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ("candidate", "staging-parent", "source-root", "baseline-manifest", "report"):
        parser.add_argument("--" + option, type=Path, required=True)
    parser.add_argument("--target", type=Path, default=Path("/Applications/OpenDente.app"))
    for option in ("team", "identity", "expected-version", "expected-build", "installed-version", "installed-build",
                   "installed-helper-sha256", "installed-plist-sha256"):
        parser.add_argument("--" + option, required=True)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    completed_report = None
    try:
        require(sys.platform == "darwin", "This installer is macOS-only")
        report_path = args.report.absolute()
        require(report_path.parent.is_dir() and not report_path.is_symlink(), "Report parent must already exist, without symlinked report")
        require(not report_path.exists(), "Refusing to overwrite an existing report")
        for bundle in (args.candidate, args.target):
            require(not report_path.resolve().is_relative_to(bundle.resolve()), "Report cannot be inside app bundles")
        configuration = Configuration(**{key: value for key, value in vars(args).items() if key not in ("report", "dry_run")})
        report = Installer(configuration).install(dry_run=args.dry_run)
        completed_report = report
        # No preferences, app launches, process termination, or SMAppService operations occur here.
        with report_path.open("x") as stream:
            json.dump(report, stream, indent=2, sort_keys=True)
            stream.write("\n")
        print(json.dumps({"installed": report["installed"], "report": str(report_path),
                          "backupBundle": report.get("backupBundle"), "requiresGUIPostflight": report.get("requiresGUIPostflight", False)}))
        return 0
    except Exception as error:
        report = error.report if isinstance(error, InstallError) else completed_report
        report_write_error = None
        if report and not args.report.exists():
            try:
                with args.report.open("x") as stream:
                    json.dump(report, stream, indent=2, sort_keys=True)
                    stream.write("\n")
            except Exception as write_error:
                report_write_error = str(write_error)
        print(json.dumps({"installed": bool(report and report.get("installed")), "error": str(error),
                          "report": str(args.report) if report else None, "reportWriteError": report_write_error}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
