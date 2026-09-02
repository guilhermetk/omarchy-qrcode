#!/usr/bin/python3

import base64
import binascii
import ctypes
import datetime
import errno
import fcntl
import hashlib
import json
import math
import os
import pwd
import re
import resource
import secrets
import selectors
import signal
import stat
import struct
import subprocess
import sys
import time
import zlib


MAX_INPUT_BYTES = 2048
MAX_MATRIX_SIZE = 185
MAX_QR_OUTPUT = 96 * 1024
MAX_SCREENSHOT_BYTES = 64 * 1024 * 1024
MAX_IMAGE_DIMENSION = 10_000
MAX_IMAGE_PIXELS = 40_000_000
MAX_DECODED_BYTES = 4096
MAX_POLYGON_POINTS = 64
MAX_SCAN_OUTPUT = 16 * 1024
MAX_STDERR = 4096
MAX_EXPORT_BYTES = 8 * 1024 * 1024
MIN_EXPORT_SIZE = 256
MAX_EXPORT_SIZE = 2048

QR_TIMEOUT = 8.0
CLIPBOARD_READ_TIMEOUT = 3.0
CAPTURE_FULLSCREEN_TIMEOUT = 20.0
CAPTURE_REGION_TIMEOUT = 60.0
DECODE_TIMEOUT = 10.0
CLIPBOARD_OWNER_TIMEOUT = 300.0
NOTIFY_TIMEOUT = 3.0

RUNTIME_NAME = "omarchy-qr-tools"
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
SAFE_COMPONENT = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
EXPORT_NAME = re.compile(r"^qr-code-[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9a-f]{8}\.png$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
MONITOR_NAME = re.compile(r"^[A-Za-z0-9_.:-]{1,128}$")
POLYGON_POINT = re.compile(rb"^([+-][0-9]{1,6}),([+-][0-9]{1,6})$")

TOOLS = {
    "qrencode": "/usr/bin/qrencode",
    "zbarimg": "/usr/bin/zbarimg",
    "wl-paste": "/usr/bin/wl-paste",
    "wl-copy": "/usr/bin/wl-copy",
    "capture": "/usr/bin/omarchy-capture-screenshot",
    "hyprctl": "/usr/bin/hyprctl",
    "notify": "/usr/bin/omarchy-notification-send",
}

SENSITIVE_CLIPBOARD_TYPES = {
    "x-kde-passwordmanagerhint",
    "application/x-libreoffice-internal-id-hint",
}

NOTIFICATIONS = {
    "scan-success": "QR/barcode data copied to the clipboard",
    "scan-no-code": "No QR code or barcode found",
    "scan-failed": "Could not scan the screen",
    "scan-copy-failed": "A code was found, but it could not be copied",
    "export-success": "QR code saved and copied to the clipboard",
    "export-copy-failed": "QR code saved, but it could not be copied",
}

_cancelled = False
_response_sent = False
_response_limit = MAX_SCAN_OUTPUT
_tool_fds = {}


class HelperError(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.code = code


class ProcessFailure(Exception):
    def __init__(self, reason, returncode=None):
        super().__init__(reason)
        self.reason = reason
        self.returncode = returncode


def _handle_signal(_signum, _frame):
    global _cancelled
    _cancelled = True


def emit(payload):
    global _response_sent
    encoded = json.dumps(payload, ensure_ascii=True, separators=(",", ":"))
    if len(encoded) > _response_limit:
        raise HelperError("response_too_large")
    sys.stdout.write(encoded + "\n")
    sys.stdout.flush()
    _response_sent = True


def emit_ok(request_id, **values):
    emit({"id": request_id, "ok": True, **values})


def emit_error(request_id, code):
    emit({"id": request_id, "ok": False, "error": code})


def try_emit_error(request_id, code):
    try:
        emit_error(request_id, code)
    except (BrokenPipeError, OSError, UnicodeError):
        pass


def parse_request_id(value):
    if not value or not value.isascii() or not value.isdigit():
        raise HelperError("invalid_request")
    request_id = int(value)
    if request_id < 1 or request_id > 2_147_483_647:
        raise HelperError("invalid_request")
    return request_id


def validate_component(name):
    return isinstance(name, str) and SAFE_COMPONENT.fullmatch(name) is not None


def open_directory_component(parent_fd, name):
    if not validate_component(name):
        raise HelperError("unsafe_directory")
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW
    try:
        fd = os.open(name, flags, dir_fd=parent_fd)
    except OSError as error:
        raise HelperError("unsafe_directory") from error
    if not stat.S_ISDIR(os.fstat(fd).st_mode):
        os.close(fd)
        raise HelperError("unsafe_directory")
    return fd


def open_absolute_directory(path):
    if not path or not os.path.isabs(path) or "\x00" in path:
        raise HelperError("unsafe_directory")
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW
    current = os.open("/", flags)
    try:
        for component in path.split("/"):
            if not component:
                continue
            next_fd = open_directory_component(current, component)
            os.close(current)
            current = next_fd
        return current
    except BaseException:
        os.close(current)
        raise


def validate_owned_directory(fd, exact_private=False):
    info = os.fstat(fd)
    mode = stat.S_IMODE(info.st_mode)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise HelperError("unsafe_directory")
    if mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise HelperError("unsafe_directory")
    if exact_private and mode != 0o700:
        raise HelperError("unsafe_directory")


def open_runtime_root():
    runtime_path = os.environ.get("XDG_RUNTIME_DIR", "")
    parent_fd = open_absolute_directory(runtime_path)
    try:
        validate_owned_directory(parent_fd, exact_private=True)
        try:
            os.mkdir(RUNTIME_NAME, 0o700, dir_fd=parent_fd)
        except FileExistsError:
            pass
        root_fd = open_directory_component(parent_fd, RUNTIME_NAME)
    finally:
        os.close(parent_fd)
    try:
        validate_owned_directory(root_fd, exact_private=True)
        return root_fd
    except BaseException:
        os.close(root_fd)
        raise


def home_directory():
    path = pwd.getpwuid(os.getuid()).pw_dir
    if not path or not os.path.isabs(path):
        raise HelperError("pictures_unavailable")
    return path


def open_pictures_directory():
    home_fd = open_absolute_directory(home_directory())
    try:
        validate_owned_directory(home_fd)
        try:
            os.mkdir("Pictures", 0o700, dir_fd=home_fd)
        except FileExistsError:
            pass
        pictures_fd = open_directory_component(home_fd, "Pictures")
    except HelperError as error:
        raise HelperError("pictures_unavailable") from error
    except OSError as error:
        raise HelperError("pictures_unavailable") from error
    finally:
        os.close(home_fd)
    try:
        validate_owned_directory(pictures_fd)
        return pictures_fd
    except BaseException:
        os.close(pictures_fd)
        raise HelperError("pictures_unavailable")


def trusted_tool(name, required=True):
    if name in _tool_fds:
        return "/proc/self/fd/{}".format(_tool_fds[name])
    path = TOOLS[name]
    try:
        resolved = os.path.realpath(path, strict=True)
        fd = os.open(resolved, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
        info = os.fstat(fd)
    except OSError:
        if required:
            raise HelperError(name.replace("-", "_") + "_missing")
        return None
    if (not os.path.isabs(resolved) or not stat.S_ISREG(info.st_mode)
            or info.st_uid != 0 or info.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
            or info.st_mode & 0o111 == 0):
        os.close(fd)
        if required:
            raise HelperError(name.replace("-", "_") + "_missing")
        return None
    _tool_fds[name] = fd
    return "/proc/self/fd/{}".format(fd)


def close_trusted_tools():
    for fd in _tool_fds.values():
        try:
            os.close(fd)
        except OSError:
            pass
    _tool_fds.clear()


def child_environment(extra=None):
    allowed = (
        "DBUS_SESSION_BUS_ADDRESS",
        "DISPLAY",
        "HYPRLAND_INSTANCE_SIGNATURE",
        "LANG",
        "LC_ALL",
        "WAYLAND_DISPLAY",
        "XDG_CONFIG_HOME",
        "XDG_CURRENT_DESKTOP",
        "XDG_RUNTIME_DIR",
    )
    environment = {key: os.environ[key] for key in allowed if key in os.environ}
    environment["PATH"] = "/usr/bin:/usr/sbin"
    environment["HOME"] = home_directory()
    environment.setdefault("LANG", "C.UTF-8")
    if extra:
        environment.update(extra)
    return environment


def child_limits(timeout, max_file_size=MAX_SCREENSHOT_BYTES):
    parent_pid = os.getpid()

    def apply_limits():
        libc = ctypes.CDLL(None, use_errno=True)
        if libc.prctl(1, signal.SIGTERM, 0, 0, 0) != 0:
            os._exit(127)
        if os.getppid() != parent_pid:
            os.kill(os.getpid(), signal.SIGTERM)
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        resource.setrlimit(resource.RLIMIT_NOFILE, (128, 128))
        resource.setrlimit(resource.RLIMIT_FSIZE, (max_file_size, max_file_size))
        memory = 2 * 1024 * 1024 * 1024
        resource.setrlimit(resource.RLIMIT_AS, (memory, memory))
        cpu = max(2, int(math.ceil(timeout)) + 2)
        resource.setrlimit(resource.RLIMIT_CPU, (cpu, cpu))
    return apply_limits


def descendant_pidfds(root_pid):
    pending = [root_pid]
    seen = set()
    descriptors = []
    while pending and len(seen) < 256:
        parent = pending.pop()
        try:
            with open("/proc/{}/task/{}/children".format(parent, parent),
                      "r", encoding="ascii") as stream:
                children = [int(value) for value in stream.read(8192).split()]
        except (OSError, ValueError):
            continue
        for child in children:
            if child in seen:
                continue
            seen.add(child)
            pending.append(child)
            try:
                descriptors.append(os.pidfd_open(child))
            except OSError:
                pass
    return descriptors


def signal_pidfds(descriptors, signum):
    for descriptor in descriptors:
        try:
            signal.pidfd_send_signal(descriptor, signum)
        except ProcessLookupError:
            pass


def terminate_process_group(process):
    descendants = descendant_pidfds(process.pid)
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    signal_pidfds(descendants, signal.SIGTERM)
    deadline = time.monotonic() + 0.35
    while time.monotonic() < deadline:
        alive = False
        for descriptor in descendants:
            try:
                signal.pidfd_send_signal(descriptor, 0)
                alive = True
            except ProcessLookupError:
                pass
        if not alive and process.poll() is not None:
            break
        time.sleep(0.02)
    if process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    signal_pidfds(descendants, signal.SIGKILL)
    try:
        process.wait(timeout=0.5)
    except subprocess.TimeoutExpired:
        try:
            process.kill()
        except ProcessLookupError:
            pass
        process.wait(timeout=0.5)
    for descriptor in descendants:
        os.close(descriptor)


def run_bounded(argv, *, timeout, stdout_limit, stderr_limit=MAX_STDERR,
                input_data=None, stdin_fd=None, pass_fds=(), environment=None,
                ready_callback=None, max_file_size=MAX_SCREENSHOT_BYTES,
                watch_directory_fd=None):
    if input_data is not None and stdin_fd is not None:
        raise ValueError("only one stdin source is allowed")
    stdin = subprocess.PIPE if input_data is not None else (
        stdin_fd if stdin_fd is not None else subprocess.DEVNULL)
    executable_fd = ()
    match = re.fullmatch(r"/proc/self/fd/([0-9]+)", argv[0])
    if match:
        executable_fd = (int(match.group(1)),)
    inherited = tuple(set(pass_fds + executable_fd
                          + ((stdin_fd,) if stdin_fd is not None else ())))
    process = subprocess.Popen(
        argv,
        stdin=stdin,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        close_fds=True,
        pass_fds=inherited,
        start_new_session=True,
        env=environment or child_environment(),
        preexec_fn=child_limits(timeout, max_file_size),
    )
    selector = selectors.DefaultSelector()
    output = {"stdout": bytearray(), "stderr": bytearray()}
    limits = {"stdout": stdout_limit, "stderr": stderr_limit}
    input_offset = 0
    callback_called = False
    deadline = time.monotonic() + timeout
    try:
        for name, stream in (("stdout", process.stdout), ("stderr", process.stderr)):
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, selectors.EVENT_READ, name)
        if input_data is not None:
            os.set_blocking(process.stdin.fileno(), False)
            selector.register(process.stdin, selectors.EVENT_WRITE, "stdin")
        elif ready_callback is not None:
            ready_callback()
            callback_called = True

        while selector.get_map() or process.poll() is None:
            if _cancelled:
                raise ProcessFailure("cancelled")
            remaining_time = deadline - time.monotonic()
            if remaining_time <= 0:
                raise ProcessFailure("timeout")
            if watch_directory_fd is not None:
                bounded_directory_entries(watch_directory_fd, 1)
            for key, _mask in selector.select(min(0.1, remaining_time)):
                stream = key.fileobj
                name = key.data
                if name == "stdin":
                    try:
                        written = os.write(stream.fileno(), input_data[input_offset:input_offset + 65536])
                        input_offset += written
                    except BrokenPipeError:
                        selector.unregister(stream)
                        stream.close()
                    if input_offset >= len(input_data) and not stream.closed:
                        selector.unregister(stream)
                        stream.close()
                        if ready_callback is not None and not callback_called and process.poll() is None:
                            ready_callback()
                            callback_called = True
                    continue

                remaining = limits[name] - len(output[name])
                try:
                    chunk = os.read(stream.fileno(), min(65536, remaining + 1))
                except BlockingIOError:
                    continue
                if not chunk:
                    selector.unregister(stream)
                    stream.close()
                    continue
                output[name].extend(chunk)
                if len(output[name]) > limits[name]:
                    raise ProcessFailure(name + "_overflow")

            if process.poll() is not None and not selector.get_map():
                break

        returncode = process.wait(timeout=0.5)
        # Trusted tools are not expected to leave descendants behind.
        try:
            os.killpg(process.pid, 0)
        except ProcessLookupError:
            pass
        else:
            terminate_process_group(process)
        if returncode != 0:
            raise ProcessFailure("exit", returncode)
        return bytes(output["stdout"]), bytes(output["stderr"])
    except BaseException:
        terminate_process_group(process)
        raise
    finally:
        selector.close()
        for stream in (process.stdin, process.stdout, process.stderr):
            if stream is not None:
                try:
                    stream.close()
                except OSError:
                    pass


def read_stdin_line(limit):
    value = sys.stdin.buffer.readline(limit + 2)
    if value.endswith(b"\n"):
        value = value[:-1]
    if len(value) > limit:
        raise HelperError("input_too_large")
    return value


def clipboard_payload():
    paste = trusted_tool("wl-paste")
    try:
        types, _ = run_bounded(
            [paste, "--list-types"],
            timeout=CLIPBOARD_READ_TIMEOUT,
            stdout_limit=4096,
        )
    except ProcessFailure as error:
        raise HelperError("clipboard_unavailable") from error
    advertised = {line.decode("ascii", "ignore").strip() for line in types.splitlines()}
    if advertised & SENSITIVE_CLIPBOARD_TYPES:
        raise HelperError("clipboard_sensitive")
    try:
        payload, _ = run_bounded(
            [paste, "--no-newline"],
            timeout=CLIPBOARD_READ_TIMEOUT,
            stdout_limit=MAX_INPUT_BYTES,
        )
    except ProcessFailure as error:
        if error.reason == "stdout_overflow":
            raise HelperError("input_too_large") from error
        raise HelperError("clipboard_unavailable") from error
    return payload


def qr_matrix(payload):
    if not payload:
        raise HelperError("input_empty")
    if len(payload) > MAX_INPUT_BYTES:
        raise HelperError("input_too_large")
    qrencode = trusted_tool("qrencode")
    try:
        output, _ = run_bounded(
            [qrencode, "--8bit", "--level", "M", "--type", "ASCII",
             "--margin", "4", "--output", "-"],
            timeout=QR_TIMEOUT,
            stdout_limit=MAX_QR_OUTPUT,
            input_data=payload,
            max_file_size=MAX_QR_OUTPUT,
        )
    except ProcessFailure as error:
        if error.reason == "stdout_overflow":
            raise HelperError("qr_output_too_large") from error
        raise HelperError("qrencode_failed") from error

    try:
        ascii_rows = output.decode("ascii").splitlines()
    except UnicodeDecodeError as error:
        raise HelperError("qr_matrix_invalid") from error
    if not ascii_rows or any(len(row) % 2 for row in ascii_rows):
        raise HelperError("qr_matrix_invalid")
    rows = []
    for row in ascii_rows:
        matrix_row = "".join("1" if "#" in row[index:index + 2] else "0"
                             for index in range(0, len(row), 2))
        rows.append(matrix_row)
    size = len(rows)
    if size < 1 or size > MAX_MATRIX_SIZE or any(len(row) != size for row in rows):
        raise HelperError("qr_matrix_invalid")
    return rows


def parse_matrix_input(raw):
    try:
        text = raw.decode("ascii")
    except UnicodeDecodeError as error:
        raise HelperError("export_invalid_matrix") from error
    rows = text.split(",") if text else []
    size = len(rows)
    if size < 1 or size > MAX_MATRIX_SIZE:
        raise HelperError("export_invalid_matrix")
    if any(len(row) != size or re.fullmatch(r"[01]+", row) is None for row in rows):
        raise HelperError("export_invalid_matrix")
    return rows


def write_all(fd, data):
    view = memoryview(data)
    while view:
        try:
            count = os.write(fd, view)
        except InterruptedError:
            continue
        if count < 1:
            raise HelperError("export_failed")
        view = view[count:]


def png_chunk(kind, data):
    checksum = binascii.crc32(kind + data) & 0xffffffff
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", checksum)


def render_png(fd, rows, pixel_size):
    total = 0
    digest = hashlib.sha256()

    def output(data):
        nonlocal total
        total += len(data)
        if total > MAX_EXPORT_BYTES:
            raise HelperError("export_too_large")
        write_all(fd, data)
        digest.update(data)

    output(PNG_SIGNATURE)
    ihdr = struct.pack(">IIBBBBB", pixel_size, pixel_size, 8, 0, 0, 0, 0)
    output(png_chunk(b"IHDR", ihdr))
    matrix_size = len(rows)
    module_size = pixel_size // matrix_size
    if module_size < 2:
        raise HelperError("export_invalid_size")
    rendered_size = module_size * matrix_size
    offset = (pixel_size - rendered_size) // 2
    compressor = zlib.compressobj(level=9)
    white_row = b"\xff" * pixel_size
    for y in range(pixel_size):
        matrix_y = (y - offset) // module_size
        if y < offset or matrix_y < 0 or matrix_y >= matrix_size:
            scanline = white_row
        else:
            source = rows[matrix_y]
            line = bytearray(white_row)
            for x in range(rendered_size):
                matrix_x = x // module_size
                if source[matrix_x] == "1":
                    target = offset + x
                    if target < pixel_size:
                        line[target] = 0
            scanline = bytes(line)
        compressed = compressor.compress(b"\x00" + scanline)
        if compressed:
            output(png_chunk(b"IDAT", compressed))
    compressed = compressor.flush()
    if compressed:
        output(png_chunk(b"IDAT", compressed))
    output(png_chunk(b"IEND", b""))
    return digest.hexdigest()


def export_matrix(rows, pixel_size):
    pictures_fd = open_pictures_directory()
    temporary = ".qr-tools-" + secrets.token_hex(12) + ".tmp"
    flags = os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC
    temporary_fd = -1
    try:
        temporary_fd = os.open(temporary, flags, 0o600, dir_fd=pictures_fd)
        digest = render_png(temporary_fd, rows, pixel_size)
        os.fsync(temporary_fd)
        timestamp = datetime.datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
        for _attempt in range(8):
            basename = "qr-code-{}-{}.png".format(timestamp, secrets.token_hex(4))
            try:
                os.link(
                    "/proc/self/fd/{}".format(temporary_fd),
                    basename,
                    dst_dir_fd=pictures_fd,
                    follow_symlinks=True,
                )
                break
            except FileExistsError:
                continue
        else:
            raise HelperError("export_failed")
        try:
            os.unlink(temporary, dir_fd=pictures_fd)
            temporary = ""
        except OSError:
            # Publication already succeeded. Never report a retryable failure that
            # could cause duplicate exports; final cleanup below retries the unlink.
            pass
        try:
            os.fsync(pictures_fd)
        except OSError:
            # The fully synced inode is already visible under its final name.
            pass
        return basename, digest
    except HelperError:
        raise
    except OSError as error:
        raise HelperError("export_failed") from error
    finally:
        if temporary_fd >= 0:
            os.close(temporary_fd)
        if temporary:
            try:
                os.unlink(temporary, dir_fd=pictures_fd)
            except OSError:
                pass
        os.close(pictures_fd)


def validate_png(fd, maximum_bytes=MAX_SCREENSHOT_BYTES, require_single_link=True):
    info = os.fstat(fd)
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
            or require_single_link and info.st_nlink != 1
            or info.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
            or info.st_size < 33 or info.st_size > maximum_bytes):
        raise HelperError("screenshot_invalid")
    header = os.pread(fd, 33, 0)
    if header[:8] != PNG_SIGNATURE or len(header) != 33:
        raise HelperError("screenshot_invalid")
    length = struct.unpack(">I", header[8:12])[0]
    if length != 13 or header[12:16] != b"IHDR":
        raise HelperError("screenshot_invalid")
    if (binascii.crc32(header[12:29]) & 0xffffffff) != struct.unpack(">I", header[29:33])[0]:
        raise HelperError("screenshot_invalid")
    width, height, depth, color, compression, filtering, interlace = struct.unpack(">IIBBBBB", header[16:29])
    if (width < 1 or height < 1 or width > MAX_IMAGE_DIMENSION
            or height > MAX_IMAGE_DIMENSION or width * height > MAX_IMAGE_PIXELS
            or depth not in (1, 2, 4, 8, 16) or color not in (0, 2, 3, 4, 6)
            or compression != 0 or filtering != 0 or interlace not in (0, 1)):
        raise HelperError("image_dimensions_invalid")
    return width, height, info.st_size


def sealed_copy(source_fd, size):
    if not hasattr(os, "memfd_create"):
        raise HelperError("screenshot_invalid")
    flags = os.MFD_CLOEXEC | getattr(os, "MFD_ALLOW_SEALING", 0x0002)
    target_fd = os.memfd_create("qr-tools-screenshot", flags)
    try:
        os.fchmod(target_fd, 0o600)
        offset = 0
        while offset < size:
            chunk = os.pread(source_fd, min(65536, size - offset), offset)
            if not chunk:
                raise HelperError("screenshot_invalid")
            write_all(target_fd, chunk)
            offset += len(chunk)
        if os.fstat(source_fd).st_size != size:
            raise HelperError("screenshot_invalid")
        seals = (fcntl.F_SEAL_WRITE | fcntl.F_SEAL_GROW | fcntl.F_SEAL_SHRINK
                 | fcntl.F_SEAL_SEAL)
        fcntl.fcntl(target_fd, fcntl.F_ADD_SEALS, seals)
        os.lseek(target_fd, 0, os.SEEK_SET)
        return target_fd
    except BaseException:
        os.close(target_fd)
        raise


def new_operation_directory(root_fd):
    for _attempt in range(16):
        name = "scan-" + secrets.token_hex(12)
        try:
            os.mkdir(name, 0o700, dir_fd=root_fd)
            fd = open_directory_component(root_fd, name)
            validate_owned_directory(fd, exact_private=True)
            return name, fd
        except FileExistsError:
            continue
    raise HelperError("runtime_unavailable")


def bounded_directory_entries(directory_fd, maximum):
    entries = []
    with os.scandir(directory_fd) as iterator:
        for entry in iterator:
            entries.append(entry.name)
            if len(entries) > maximum:
                raise ProcessFailure("file_cardinality")
    return entries


def cleanup_operation(root_fd, name, operation_fd):
    try:
        with os.scandir(operation_fd) as iterator:
            leaves = []
            for entry in iterator:
                leaves.append(entry.name)
                if len(leaves) >= 32:
                    break
        for leaf in leaves:
            if not validate_component(leaf):
                continue
            try:
                os.unlink(leaf, dir_fd=operation_fd)
            except IsADirectoryError:
                try:
                    os.rmdir(leaf, dir_fd=operation_fd)
                except OSError:
                    pass
            except OSError:
                pass
    finally:
        os.close(operation_fd)
        try:
            os.rmdir(name, dir_fd=root_fd)
        except OSError:
                pass


def focused_monitor():
    hyprctl = trusted_tool("hyprctl", required=False)
    if not hyprctl:
        return ""
    try:
        output, _ = run_bounded(
            [hyprctl, "monitors", "-j"],
            timeout=2.0,
            stdout_limit=64 * 1024,
        )
        monitors = json.loads(output.decode("utf-8"))
        for monitor in monitors:
            name = monitor.get("name", "")
            if monitor.get("focused") is True and MONITOR_NAME.fullmatch(name):
                return name
    except (ProcessFailure, UnicodeDecodeError, ValueError, TypeError):
        pass
    return ""


def parse_zbar(output, image_width, image_height):
    separator = output.find(b":")
    if separator < 1:
        raise HelperError("decoded_invalid")
    polygon_data = output[:separator]
    payload = output[separator + 1:]
    if not payload:
        raise HelperError("no_code")
    if len(payload) > MAX_DECODED_BYTES:
        raise HelperError("decoded_too_large")
    raw_points = polygon_data.split(b" ")
    if len(raw_points) < 2 or len(raw_points) > MAX_POLYGON_POINTS:
        raise HelperError("decoded_invalid")
    points = []
    for raw_point in raw_points:
        match = POLYGON_POINT.fullmatch(raw_point)
        if not match:
            raise HelperError("decoded_invalid")
        x = int(match.group(1))
        y = int(match.group(2))
        if x < -image_width or x > image_width * 2 or y < -image_height or y > image_height * 2:
            raise HelperError("decoded_invalid")
        points.append((x, y))
    left = max(0, min(image_width, min(point[0] for point in points)))
    top = max(0, min(image_height, min(point[1] for point in points)))
    right = max(0, min(image_width, max(point[0] for point in points)))
    bottom = max(0, min(image_height, max(point[1] for point in points)))
    highlight = None
    if right > left and bottom > top:
        highlight = {
            "imageWidth": image_width,
            "imageHeight": image_height,
            "x": left,
            "y": top,
            "width": right - left,
            "height": bottom - top,
        }
    return payload, highlight


def scan_screen(mode):
    if mode not in ("region", "fullscreen"):
        raise HelperError("invalid_request")
    capture = trusted_tool("capture")
    zbarimg = trusted_tool("zbarimg")
    monitor = focused_monitor() if mode == "fullscreen" else ""
    runtime_fd = open_runtime_root()
    operation_name = ""
    operation_fd = -1
    try:
        operation_name, operation_fd = new_operation_directory(runtime_fd)
        time.sleep(0.15)
        timeout = CAPTURE_REGION_TIMEOUT if mode == "region" else CAPTURE_FULLSCREEN_TIMEOUT
        environment = child_environment({
            "OMARCHY_SCREENSHOT_DIR": "/proc/self/fd/{}".format(operation_fd),
            # The trusted wrapper sources ~/.config/user-dirs.dirs when HOME points
            # at the real home. It does not need that file with an explicit output.
            "HOME": "/proc/self/fd/{}".format(operation_fd),
        })
        try:
            run_bounded(
                [capture, mode, "save"],
                timeout=timeout,
                stdout_limit=4096,
                stderr_limit=MAX_STDERR,
                pass_fds=(operation_fd,),
                environment=environment,
                watch_directory_fd=operation_fd,
            )
        except ProcessFailure as error:
            if error.reason == "exit" and error.returncode == 0:
                raise HelperError("scan_cancelled") from error
            raise HelperError("capture_failed") from error

        try:
            leaves = bounded_directory_entries(operation_fd, 1)
        except ProcessFailure as error:
            raise HelperError("screenshot_invalid") from error
        if not leaves:
            raise HelperError("scan_cancelled")
        if len(leaves) != 1 or not validate_component(leaves[0]):
            raise HelperError("screenshot_invalid")
        flags = os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC
        try:
            source_fd = os.open(leaves[0], flags, dir_fd=operation_fd)
        except OSError as error:
            raise HelperError("screenshot_invalid") from error
        try:
            width, height, size = validate_png(source_fd)
            image_fd = sealed_copy(source_fd, size)
        finally:
            os.close(source_fd)
        try:
            width, height, _size = validate_png(image_fd, require_single_link=False)
            try:
                output, _ = run_bounded(
                    [zbarimg, "--quiet", "--raw", "--polygon", "--oneshot",
                     "-Stest-inverted", "--", "/proc/self/fd/{}".format(image_fd)],
                    timeout=DECODE_TIMEOUT,
                    stdout_limit=MAX_SCAN_OUTPUT,
                    stderr_limit=MAX_STDERR,
                    pass_fds=(image_fd,),
                )
            except ProcessFailure as error:
                if error.reason == "exit" and error.returncode == 4:
                    raise HelperError("no_code") from error
                if error.reason == "stdout_overflow":
                    raise HelperError("decoded_too_large") from error
                raise HelperError("decode_failed") from error
            payload, highlight = parse_zbar(output, width, height)
        finally:
            os.close(image_fd)
        if highlight is not None:
            highlight["monitor"] = monitor
        return payload, highlight
    finally:
        if operation_fd >= 0:
            cleanup_operation(runtime_fd, operation_name, operation_fd)
        os.close(runtime_fd)


def decode_base64_line(maximum):
    raw = read_stdin_line(((maximum + 2) // 3) * 4)
    if not raw or len(raw) % 4 or re.fullmatch(rb"[A-Za-z0-9+/]*={0,2}", raw) is None:
        raise HelperError("clipboard_payload_invalid")
    try:
        decoded = base64.b64decode(raw, validate=True)
    except binascii.Error as error:
        raise HelperError("clipboard_payload_invalid") from error
    if not decoded or len(decoded) > maximum:
        raise HelperError("clipboard_payload_invalid")
    return decoded


def own_clipboard(request_id, *, mime_type, input_data=None, input_fd=None):
    wl_copy = trusted_tool("wl-copy")
    ready = False

    def report_ready():
        nonlocal ready
        if not ready:
            emit_ok(request_id, ready=True)
            ready = True

    try:
        run_bounded(
            [wl_copy, "--foreground", "--type", mime_type],
            timeout=CLIPBOARD_OWNER_TIMEOUT,
            stdout_limit=1024,
            stderr_limit=MAX_STDERR,
            input_data=input_data,
            stdin_fd=input_fd,
            ready_callback=report_ready,
            max_file_size=MAX_EXPORT_BYTES,
        )
    except ProcessFailure as error:
        if ready and error.reason in ("timeout", "cancelled"):
            return
        raise HelperError("clipboard_copy_failed") from error


def open_export_for_clipboard(basename, expected_digest):
    if EXPORT_NAME.fullmatch(basename) is None or SHA256.fullmatch(expected_digest) is None:
        raise HelperError("invalid_request")
    pictures_fd = open_pictures_directory()
    try:
        flags = os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC
        try:
            fd = os.open(basename, flags, dir_fd=pictures_fd)
        except OSError as error:
            raise HelperError("export_changed") from error
    finally:
        os.close(pictures_fd)
    try:
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or info.st_nlink != 1
                or info.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
                or info.st_size < 33 or info.st_size > MAX_EXPORT_BYTES):
            raise HelperError("export_changed")
        validate_png(fd, MAX_EXPORT_BYTES)
        sealed_fd = sealed_copy(fd, info.st_size)
        digest = hashlib.sha256()
        offset = 0
        while offset < info.st_size:
            chunk = os.pread(sealed_fd, min(65536, info.st_size - offset), offset)
            if not chunk:
                raise HelperError("export_changed")
            digest.update(chunk)
            offset += len(chunk)
        if digest.hexdigest() != expected_digest:
            os.close(sealed_fd)
            raise HelperError("export_changed")
        validate_png(sealed_fd, MAX_EXPORT_BYTES, require_single_link=False)
        os.close(fd)
        os.lseek(sealed_fd, 0, os.SEEK_SET)
        return sealed_fd
    except BaseException:
        os.close(fd)
        raise


def send_notification(event, basename=None):
    if event not in NOTIFICATIONS:
        raise HelperError("invalid_request")
    if basename is not None and EXPORT_NAME.fullmatch(basename) is None:
        raise HelperError("invalid_request")
    notify = trusted_tool("notify", required=False)
    if not notify:
        return
    message = NOTIFICATIONS[event]
    if basename and event.startswith("export-"):
        message += ": ~/Pictures/" + basename
    try:
        run_bounded(
            [notify, "-g", "QR", "--app-name", "QR Tools", message, "-t", "4500"],
            timeout=NOTIFY_TIMEOUT,
            stdout_limit=1024,
            stderr_limit=MAX_STDERR,
        )
    except ProcessFailure:
        # Notifications are best effort and never change the completed action.
        pass


def command_dependencies(request_id, arguments):
    if arguments:
        raise HelperError("invalid_request")
    emit_ok(
        request_id,
        qrencode=trusted_tool("qrencode", required=False) is not None,
        zbar=trusted_tool("zbarimg", required=False) is not None,
    )


def command_generate_stdin(request_id, arguments):
    if arguments:
        raise HelperError("invalid_request")
    emit_ok(request_id, matrix=qr_matrix(read_stdin_line(MAX_INPUT_BYTES)))


def command_generate_clipboard(request_id, arguments):
    if arguments:
        raise HelperError("invalid_request")
    emit_ok(request_id, matrix=qr_matrix(clipboard_payload()))


def command_scan(request_id, arguments):
    if len(arguments) != 1:
        raise HelperError("invalid_request")
    payload, highlight = scan_screen(arguments[0])
    emit_ok(request_id, payload=base64.b64encode(payload).decode("ascii"), highlight=highlight)


def command_export(request_id, arguments):
    if len(arguments) != 1 or not arguments[0].isascii() or not arguments[0].isdigit():
        raise HelperError("export_invalid_size")
    pixel_size = int(arguments[0])
    if pixel_size < MIN_EXPORT_SIZE or pixel_size > MAX_EXPORT_SIZE:
        raise HelperError("export_invalid_size")
    maximum = MAX_MATRIX_SIZE * (MAX_MATRIX_SIZE + 1)
    rows = parse_matrix_input(read_stdin_line(maximum))
    basename, digest = export_matrix(rows, pixel_size)
    emit_ok(request_id, basename=basename, sha256=digest)


def command_clipboard_text(request_id, arguments):
    if arguments:
        raise HelperError("invalid_request")
    own_clipboard(request_id, mime_type="text/plain;charset=utf-8",
                  input_data=decode_base64_line(MAX_DECODED_BYTES))


def command_clipboard_image(request_id, arguments):
    if len(arguments) != 2:
        raise HelperError("invalid_request")
    image_fd = open_export_for_clipboard(arguments[0], arguments[1])
    try:
        own_clipboard(request_id, mime_type="image/png", input_fd=image_fd)
    finally:
        os.close(image_fd)


def command_notify(request_id, arguments):
    if len(arguments) not in (1, 2):
        raise HelperError("invalid_request")
    send_notification(arguments[0], arguments[1] if len(arguments) == 2 else None)
    emit_ok(request_id)


COMMANDS = {
    "dependencies": command_dependencies,
    "generate-stdin": command_generate_stdin,
    "generate-clipboard": command_generate_clipboard,
    "scan": command_scan,
    "export": command_export,
    "clipboard-text": command_clipboard_text,
    "clipboard-image": command_clipboard_image,
    "notify": command_notify,
}


def main(argv=None):
    global _cancelled, _response_sent, _response_limit
    _cancelled = False
    _response_sent = False
    arguments = list(sys.argv[1:] if argv is None else argv)
    request_id = 0
    try:
        if len(arguments) < 2 or arguments[0] not in COMMANDS:
            raise HelperError("invalid_request")
        command = arguments.pop(0)
        _response_limit = MAX_QR_OUTPUT if command.startswith("generate-") else MAX_SCAN_OUTPUT
        request_id = parse_request_id(arguments.pop(0))
        COMMANDS[command](request_id, arguments)
        return 0
    except HelperError as error:
        if not _response_sent:
            try_emit_error(request_id, error.code)
        return 0
    except (OSError, ValueError, TypeError, ProcessFailure):
        if not _response_sent:
            try_emit_error(request_id, "internal_error")
        return 1
    finally:
        close_trusted_tools()


if __name__ == "__main__":
    os.umask(0o077)
    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)
    raise SystemExit(main())
