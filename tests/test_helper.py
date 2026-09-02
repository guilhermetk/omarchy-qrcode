import base64
import contextlib
import importlib.util
import io
import json
import os
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


REPOSITORY = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HELPER_PATH = os.path.join(REPOSITORY, "qr-tools-helper.py")
SPEC = importlib.util.spec_from_file_location("qr_tools_helper", HELPER_PATH)
helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(helper)


class EnvironmentMixin:
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.runtime = os.path.join(self.temporary.name, "runtime")
        self.home = os.path.join(self.temporary.name, "home")
        os.mkdir(self.runtime, 0o700)
        os.mkdir(self.home, 0o700)
        os.mkdir(os.path.join(self.home, "Pictures"), 0o700)
        self.environment = mock.patch.dict(
            os.environ, {"XDG_RUNTIME_DIR": self.runtime}, clear=False
        )
        self.environment.start()
        self.addCleanup(self.environment.stop)


class DirectoryTests(EnvironmentMixin, unittest.TestCase):
    def test_runtime_root_is_private_and_descriptor_held(self):
        fd = helper.open_runtime_root()
        self.addCleanup(os.close, fd)
        info = os.fstat(fd)
        self.assertTrue(stat.S_ISDIR(info.st_mode))
        self.assertEqual(stat.S_IMODE(info.st_mode), 0o700)
        self.assertEqual(info.st_uid, os.getuid())

    def test_runtime_rejects_relative_symlink_and_bad_mode(self):
        with mock.patch.dict(os.environ, {"XDG_RUNTIME_DIR": "relative"}):
            with self.assertRaisesRegex(helper.HelperError, "unsafe_directory"):
                helper.open_runtime_root()

        link = os.path.join(self.temporary.name, "runtime-link")
        os.symlink(self.runtime, link)
        with mock.patch.dict(os.environ, {"XDG_RUNTIME_DIR": link}):
            with self.assertRaisesRegex(helper.HelperError, "unsafe_directory"):
                helper.open_runtime_root()

        os.chmod(self.runtime, 0o755)
        with self.assertRaisesRegex(helper.HelperError, "unsafe_directory"):
            helper.open_runtime_root()

    def test_pictures_rejects_symlink(self):
        os.rmdir(os.path.join(self.home, "Pictures"))
        os.symlink(self.runtime, os.path.join(self.home, "Pictures"))
        with mock.patch.object(helper, "home_directory", return_value=self.home):
            with self.assertRaisesRegex(helper.HelperError, "pictures_unavailable"):
                helper.open_pictures_directory()


class GenerationTests(unittest.TestCase):
    def run_helper(self, payload):
        environment = os.environ.copy()
        environment["XDG_RUNTIME_DIR"] = "/run/user/{}".format(os.getuid())
        return subprocess.run(
            ["/usr/bin/python3", HELPER_PATH, "generate-stdin", "17"],
            input=payload,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            timeout=10,
        )

    def test_real_qrencode_returns_square_bounded_matrix(self):
        result = self.run_helper(b"https://example.com/qr-tools\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, b"")
        response = json.loads(result.stdout)
        self.assertEqual(response["id"], 17)
        self.assertTrue(response["ok"])
        rows = response["matrix"]
        self.assertLessEqual(len(rows), helper.MAX_MATRIX_SIZE)
        self.assertTrue(all(len(row) == len(rows) and set(row) <= {"0", "1"}
                            for row in rows))

    def test_input_limit_is_checked_before_generation(self):
        accepted = self.run_helper(b"A" * helper.MAX_INPUT_BYTES + b"\n")
        self.assertEqual(accepted.returncode, 0)
        rejected = self.run_helper(b"A" * (helper.MAX_INPUT_BYTES + 1) + b"\n")
        self.assertEqual(rejected.returncode, 0)
        self.assertEqual(rejected.stderr, b"")
        self.assertEqual(json.loads(rejected.stdout)["error"], "input_too_large")

    def test_ambient_path_does_not_select_tools(self):
        with tempfile.TemporaryDirectory() as path:
            environment = os.environ.copy()
            environment["PATH"] = path
            result = subprocess.run(
                ["/usr/bin/python3", HELPER_PATH, "dependencies", "3"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=environment,
                timeout=5,
            )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout), {
            "id": 3, "ok": True, "qrencode": True, "zbar": True
        })


class ExportTests(EnvironmentMixin, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self.home_patch = mock.patch.object(helper, "home_directory", return_value=self.home)
        self.home_patch.start()
        self.addCleanup(self.home_patch.stop)
        self.rows = helper.qr_matrix(b"https://example.com/export-test")

    def test_export_has_exact_size_digest_and_decodes(self):
        basename, digest = helper.export_matrix(self.rows, 513)
        path = os.path.join(self.home, "Pictures", basename)
        self.assertRegex(basename, helper.EXPORT_NAME)
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
        with open(path, "rb") as stream:
            contents = stream.read()
        self.assertEqual(helper.hashlib.sha256(contents).hexdigest(), digest)
        fd = os.open(path, os.O_RDONLY)
        try:
            self.assertEqual(helper.validate_png(fd, helper.MAX_EXPORT_BYTES)[:2], (513, 513))
        finally:
            os.close(fd)
        decoded = subprocess.run(
            ["/usr/bin/zbarimg", "--quiet", "--raw", path],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
        )
        self.assertEqual(decoded.stdout, b"https://example.com/export-test\n")

    def test_existing_symlink_is_never_replaced(self):
        timestamp = helper.datetime.datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
        occupied = "qr-code-{}-deadbeef.png".format(timestamp)
        target = os.path.join(self.temporary.name, "target")
        with open(target, "wb") as stream:
            stream.write(b"unchanged")
        os.symlink(target, os.path.join(self.home, "Pictures", occupied))
        tokens = iter(["a" * 24, "deadbeef", "cafebabe"])
        with mock.patch.object(helper.secrets, "token_hex", side_effect=lambda _size: next(tokens)):
            basename, _digest = helper.export_matrix(self.rows, 512)
        self.assertTrue(os.path.islink(os.path.join(self.home, "Pictures", occupied)))
        with open(target, "rb") as stream:
            self.assertEqual(stream.read(), b"unchanged")
        self.assertTrue(basename.endswith("-cafebabe.png"))

    def test_matrix_and_dense_minimum_are_enforced(self):
        with self.assertRaisesRegex(helper.HelperError, "export_invalid_matrix"):
            helper.parse_matrix_input(b"01,1x")
        dense = ["0" * helper.MAX_MATRIX_SIZE] * helper.MAX_MATRIX_SIZE
        with self.assertRaisesRegex(helper.HelperError, "export_invalid_size"):
            helper.export_matrix(dense, 256)


class ScanBoundaryTests(EnvironmentMixin, unittest.TestCase):
    def make_png(self):
        path = os.path.join(self.temporary.name, "fixture.png")
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            helper.render_png(fd, ["0"], 256)
        finally:
            os.close(fd)
        with open(path, "rb") as stream:
            return stream.read()

    def make_executable(self, name, contents):
        path = os.path.join(self.temporary.name, name)
        with open(path, "wb") as stream:
            stream.write(contents)
        os.chmod(path, 0o700)
        return path

    def test_scan_ignores_returned_path_and_preserves_payload_newline(self):
        png = base64.b64encode(self.make_png()).decode("ascii")
        capture = self.make_executable("capture", (
            "#!/usr/bin/python3\nimport base64,os\n"
            "open(os.environ['OMARCHY_SCREENSHOT_DIR'] + '/capture.png','wb').write(base64.b64decode(%r))\n"
            "print('/outside/untrusted.png')\n" % png
        ).encode())
        zbar = self.make_executable(
            "zbar", b"#!/usr/bin/python3\nimport sys\nsys.stdout.buffer.write(b'+1,+1 +9,+1 +9,+9 +1,+9:value:with:colon\\n')\n"
        )

        def tool(name, required=True):
            if name == "capture":
                return capture
            if name == "zbarimg":
                return zbar
            if name == "hyprctl":
                return None
            return helper.trusted_tool(name, required)

        original = helper.trusted_tool
        with mock.patch.object(helper, "trusted_tool", side_effect=tool):
            # The closure needs the original for names outside this scan.
            helper.trusted_tool.side_effect = lambda name, required=True: (
                capture if name == "capture" else
                zbar if name == "zbarimg" else
                None if name == "hyprctl" else
                original(name, required)
            )
            payload, highlight = helper.scan_screen("fullscreen")
        self.assertEqual(payload, b"value:with:colon\n")
        self.assertEqual(highlight["width"], 8)
        self.assertEqual(os.listdir(os.path.join(self.runtime, helper.RUNTIME_NAME)), [])

    def test_capture_cardinality_is_rejected(self):
        png = base64.b64encode(self.make_png()).decode("ascii")
        capture = self.make_executable("capture-two", (
            "#!/usr/bin/python3\nimport base64,os\n"
            "data=base64.b64decode(%r)\n"
            "open(os.environ['OMARCHY_SCREENSHOT_DIR'] + '/one.png','wb').write(data)\n"
            "open(os.environ['OMARCHY_SCREENSHOT_DIR'] + '/two.png','wb').write(data)\n" % png
        ).encode())
        original = helper.trusted_tool
        with mock.patch.object(helper, "trusted_tool", side_effect=lambda name, required=True: (
            capture if name == "capture" else
            "/usr/bin/zbarimg" if name == "zbarimg" else
            None if name == "hyprctl" else
            original(name, required)
        )):
            with self.assertRaisesRegex(helper.HelperError, "screenshot_invalid"):
                helper.scan_screen("fullscreen")

    def test_png_validator_rejects_symlink_fifo_and_oversize_header(self):
        directory_fd = os.open(self.temporary.name, os.O_RDONLY | os.O_DIRECTORY)
        self.addCleanup(os.close, directory_fd)
        os.symlink("/dev/zero", os.path.join(self.temporary.name, "image.png"))
        with self.assertRaises(OSError):
            os.open("image.png", os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW,
                    dir_fd=directory_fd)
        fifo = os.path.join(self.temporary.name, "image.fifo")
        os.mkfifo(fifo, 0o600)
        fifo_fd = os.open("image.fifo", os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW,
                          dir_fd=directory_fd)
        try:
            with self.assertRaisesRegex(helper.HelperError, "screenshot_invalid"):
                helper.validate_png(fifo_fd)
        finally:
            os.close(fifo_fd)


class ProcessTests(unittest.TestCase):
    def setUp(self):
        helper._cancelled = False

    def tearDown(self):
        helper._cancelled = False

    def test_stdout_is_stopped_at_producer_limit(self):
        with self.assertRaisesRegex(helper.ProcessFailure, "stdout_overflow"):
            helper.run_bounded(
                ["/usr/bin/yes"], timeout=2, stdout_limit=64, stderr_limit=64
            )

    def test_validated_executable_is_bound_to_open_inode(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = os.path.join(directory, "tool")
            with open(executable, "wb") as stream:
                stream.write(b"#!/usr/bin/bash\nprintf original\n")
            os.chmod(executable, 0o700)
            info = list(os.stat(executable))
            info[4] = 0
            root_owned = os.stat_result(info)
            helper.TOOLS["test-tool"] = executable
            try:
                with mock.patch.object(helper.os, "fstat", return_value=root_owned):
                    bound_path = helper.trusted_tool("test-tool")
                replacement = os.path.join(directory, "replacement")
                with open(replacement, "wb") as stream:
                    stream.write(b"#!/usr/bin/bash\nprintf replacement\n")
                os.chmod(replacement, 0o700)
                os.replace(replacement, executable)
                output, _ = helper.run_bounded(
                    [bound_path], timeout=2, stdout_limit=64, stderr_limit=64
                )
                self.assertEqual(output, b"original")
            finally:
                helper.close_trusted_tools()
                helper.TOOLS.pop("test-tool", None)

    def test_timeout_terminates_child_process_group(self):
        with tempfile.TemporaryDirectory() as directory:
            pid_file = os.path.join(directory, "pid")
            command = "sleep 30 & echo $! > \"$1\"; wait"
            with self.assertRaisesRegex(helper.ProcessFailure, "timeout"):
                helper.run_bounded(
                    ["/usr/bin/bash", "-c", command, "test", pid_file],
                    timeout=0.2,
                    stdout_limit=64,
                    stderr_limit=64,
                )
            with open(pid_file, "r", encoding="ascii") as stream:
                child_pid = int(stream.read())
            deadline = time.monotonic() + 1
            while time.monotonic() < deadline:
                try:
                    os.kill(child_pid, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.02)
            else:
                self.fail("grandchild survived process-group timeout")

    def test_timeout_terminates_descendant_that_changes_session(self):
        with tempfile.TemporaryDirectory() as directory:
            pid_file = os.path.join(directory, "pid")
            command = "setsid sleep 30 & echo $! > \"$1\"; wait"
            with self.assertRaisesRegex(helper.ProcessFailure, "timeout"):
                helper.run_bounded(
                    ["/usr/bin/bash", "-c", command, "test", pid_file],
                    timeout=0.2,
                    stdout_limit=64,
                    stderr_limit=64,
                )
            with open(pid_file, "r", encoding="ascii") as stream:
                child_pid = int(stream.read())
            deadline = time.monotonic() + 1
            while time.monotonic() < deadline:
                try:
                    os.kill(child_pid, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.02)
            else:
                self.fail("session-changing descendant survived timeout")


class ProtocolTests(unittest.TestCase):
    def test_zbar_parser_preserves_colons_and_trailing_newline(self):
        payload, highlight = helper.parse_zbar(
            b"+1,+2 +9,+2 +9,+8 +1,+8:a:b\n", 10, 10
        )
        self.assertEqual(payload, b"a:b\n")
        self.assertEqual(highlight["height"], 6)

    def test_base64_limit(self):
        valid = base64.b64encode(b"A" * helper.MAX_DECODED_BYTES)
        with mock.patch.object(sys, "stdin", io.TextIOWrapper(io.BytesIO(valid + b"\n"))):
            self.assertEqual(len(helper.decode_base64_line(helper.MAX_DECODED_BYTES)),
                             helper.MAX_DECODED_BYTES)
        invalid = base64.b64encode(b"A" * (helper.MAX_DECODED_BYTES + 1))
        with mock.patch.object(sys, "stdin", io.TextIOWrapper(io.BytesIO(invalid + b"\n"))):
            with self.assertRaises(helper.HelperError):
                helper.decode_base64_line(helper.MAX_DECODED_BYTES)


if __name__ == "__main__":
    unittest.main()
