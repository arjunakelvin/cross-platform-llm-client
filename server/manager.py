#!/usr/bin/env python3
"""Server Manager — daemon ringan untuk mengelola beberapa AI server di satu VPS.

Daemon ini adalah backend dari layar "Server manager" di web client
PiercingBlow. Dia:

  * mendaftar beberapa AI server (Ollama, llama.cpp, vLLM, …) lewat
    `servers.json`,
  * menyalakan / mematikan beberapa AI sekaligus,
  * melaporkan status CPU, RAM, penyimpanan, dan jaringan,
  * menyimpan log sederhana (siapa nyala kapan, output runtime terakhir),
  * melindungi semua endpoint dengan secret key (`X-Secret-Key`).

Hanya pakai standard library Python 3 — tidak perlu pip install.

Jalankan:
    python3 server/manager.py --config server/servers.json

Endpoint (semua butuh header `X-Secret-Key`):
    GET  /manager/health
    GET  /manager/servers
    GET  /manager/servers/<id>
    GET  /manager/servers/<id>/status
    GET  /manager/servers/<id>/logs?lines=100
    POST /manager/servers/<id>/start
    POST /manager/servers/<id>/stop
    GET  /manager/models
"""

from __future__ import annotations

import argparse
import hmac
import json
import os
import shutil
import signal
import socket
import subprocess
import threading
import time
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import parse_qs, urlparse

CONFIG_PATH = os.environ.get(
    "PB_MANAGER_CONFIG",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "servers.json"),
)
SECRET_HEADER = "X-Secret-Key"
LOG_LINES = 500


# ── Config ───────────────────────────────────────────────────────────────


class Config:
    """Config file yang di-reload kalau berubah di disk."""

    def __init__(self, path: str) -> None:
        self.path = path
        self._mtime = 0.0
        self._lock = threading.Lock()
        self.data: dict[str, Any] = {"servers": []}
        self.reload()

    def reload(self) -> None:
        try:
            mtime = os.path.getmtime(self.path)
        except OSError:
            return
        if mtime == self._mtime:
            return
        with self._lock:
            try:
                # utf-8-sig: file config yang diedit di Windows sering punya
                # BOM, dan json.load akan gagal kalau BOM ikut kebaca.
                with open(self.path, "r", encoding="utf-8-sig") as handle:
                    self.data = json.load(handle)
                self._mtime = mtime
            except (OSError, ValueError) as exc:
                print(f"[manager] config tidak bisa dibaca: {exc}", flush=True)

    @property
    def secret(self) -> str:
        return str(self.data.get("secretKey") or "")

    @property
    def servers(self) -> list[dict[str, Any]]:
        servers = self.data.get("servers")
        return servers if isinstance(servers, list) else []


# ── Utilitas sistem ──────────────────────────────────────────────────────


def port_open(port: int, host: str = "127.0.0.1", timeout: float = 0.4) -> bool:
    if port <= 0:
        return False
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def find_pid(needle: str) -> int | None:
    """Cari pid proses yang cmdline-nya mengandung `needle`."""
    if not needle:
        return None
    try:
        for entry in os.listdir("/proc"):
            if not entry.isdigit():
                continue
            try:
                with open(f"/proc/{entry}/cmdline", "rb") as handle:
                    cmdline = handle.read().replace(b"\x00", b" ").decode(
                        "utf-8", "replace")
            except OSError:
                continue
            if needle in cmdline and "manager.py" not in cmdline:
                return int(entry)
    except OSError:
        return None
    return None


def read_cpu_times() -> tuple[int, int] | None:
    """(idle, total) dalam jiffy."""
    try:
        with open("/proc/stat", "r", encoding="utf-8") as handle:
            parts = handle.readline().split()
    except OSError:
        return None
    if len(parts) < 5:
        return None
    values = [int(p) for p in parts[1:8]]
    idle = values[3] + (values[4] if len(values) > 4 else 0)
    return idle, sum(values)


def read_memory() -> tuple[float, float]:
    """(used_mb, total_mb) dari /proc/meminfo (Linux) atau Windows API."""
    if os.name == "nt":
        return _read_memory_windows()
    total_kb = 0
    available_kb = 0
    try:
        with open("/proc/meminfo", "r", encoding="utf-8") as handle:
            for line in handle:
                if line.startswith("MemTotal:"):
                    total_kb = int(line.split()[1])
                elif line.startswith("MemAvailable:"):
                    available_kb = int(line.split()[1])
                    break
    except OSError:
        return 0.0, 0.0
    if total_kb <= 0:
        return 0.0, 0.0
    used_kb = max(total_kb - available_kb, 0)
    return used_kb / 1024.0, total_kb / 1024.0


def _read_memory_windows() -> tuple[float, float]:
    """Fallback Windows supaya dashboard tidak menampilkan RAM 0 MB."""
    try:
        import ctypes

        class MemoryStatusEx(ctypes.Structure):
            _fields_ = [
                ("dwLength", ctypes.c_ulong),
                ("dwMemoryLoad", ctypes.c_ulong),
                ("ullTotalPhys", ctypes.c_ulonglong),
                ("ullAvailPhys", ctypes.c_ulonglong),
                ("ullTotalPageFile", ctypes.c_ulonglong),
                ("ullAvailPageFile", ctypes.c_ulonglong),
                ("ullTotalVirtual", ctypes.c_ulonglong),
                ("ullAvailVirtual", ctypes.c_ulonglong),
                ("ullAvailExtendedVirtual", ctypes.c_ulonglong),
            ]

        status = MemoryStatusEx()
        status.dwLength = ctypes.sizeof(MemoryStatusEx)
        ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(status))
        total = status.ullTotalPhys / (1024 * 1024)
        used = (status.ullTotalPhys - status.ullAvailPhys) / (1024 * 1024)
        return used, total
    except Exception:  # noqa: BLE001 - best effort
        return 0.0, 0.0


def read_network() -> tuple[int, int]:
    """(rx_bytes, tx_bytes) total dari semua interface."""
    rx = 0
    tx = 0
    try:
        with open("/proc/net/dev", "r", encoding="utf-8") as handle:
            lines = handle.readlines()[2:]
    except OSError:
        return 0, 0
    for line in lines:
        if ":" not in line:
            continue
        name, _, values = line.partition(":")
        if name.strip() == "lo":
            continue
        fields = values.split()
        if len(fields) < 9:
            continue
        try:
            rx += int(fields[0])
            tx += int(fields[8])
        except ValueError:
            continue
    return rx, tx


class HostStats:
    """Statistik host dengan delta antar-request (untuk hitung % CPU & Mbps)."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._cpu = read_cpu_times()
        self._net = read_network()
        self._time = time.time()
        self._cpu_percent = 0.0
        self._net_down = 0.0
        self._net_up = 0.0

    def sample(self) -> dict[str, float]:
        with self._lock:
            now = time.time()
            elapsed = max(now - self._time, 0.001)

            cpu = read_cpu_times()
            if cpu and self._cpu:
                idle_delta = cpu[0] - self._cpu[0]
                total_delta = cpu[1] - self._cpu[1]
                if total_delta > 0:
                    self._cpu_percent = max(
                        0.0, min(100.0, (1.0 - idle_delta / total_delta) * 100.0))
            self._cpu = cpu

            net = read_network()
            if net and self._net:
                down = max(net[0] - self._net[0], 0) * 8 / elapsed / 1_000_000
                up = max(net[1] - self._net[1], 0) * 8 / elapsed / 1_000_000
                self._net_down = down
                self._net_up = up
            self._net = net
            self._time = now

            used_mb, total_mb = read_memory()
            try:
                disk = shutil.disk_usage("/")
                disk_used = disk.used / (1024 ** 3)
                disk_total = disk.total / (1024 ** 3)
            except OSError:
                disk_used = disk_total = 0.0

            return {
                "cpuPercent": round(self._cpu_percent, 1),
                "ramUsedMb": round(used_mb, 1),
                "ramTotalMb": round(total_mb, 1),
                "diskUsedGb": round(disk_used, 2),
                "diskTotalGb": round(disk_total, 2),
                "netDownMbps": round(self._net_down, 2),
                "netUpMbps": round(self._net_up, 2),
            }


# ── Proses AI ────────────────────────────────────────────────────────────


class ManagedProcess:
    """Satu AI server: proses runtime + log + status."""

    def __init__(self, spec: dict[str, Any]) -> None:
        self.spec = spec
        self.id = str(spec.get("id") or "")
        self.name = str(spec.get("name") or self.id)
        self.runtime = str(spec.get("runtime") or "")
        self.model = str(spec.get("model") or "")
        self.port = int(spec.get("port") or 0)
        self.api_url = str(spec.get("apiUrl") or "")
        self.models: list[str] = list(spec.get("models") or [])
        self.start_command: list[str] = list(spec.get("startCommand") or [])
        self.stop_command: list[str] = list(spec.get("stopCommand") or [])
        self.env: dict[str, str] = dict(spec.get("env") or {})
        self.workdir = str(spec.get("workdir") or "")
        self.log_file = str(spec.get("logFile") or "")

        self.process: subprocess.Popen | None = None
        self.started_at: float | None = None
        self.logs: deque[str] = deque(maxlen=LOG_LINES)
        self._lock = threading.Lock()

    # -- status -----------------------------------------------------------

    def pid(self) -> int | None:
        if self.process is not None and self.process.poll() is None:
            return self.process.pid
        return find_pid(self._match_needle())

    def _match_needle(self) -> str:
        if not self.start_command:
            return ""
        return os.path.basename(self.start_command[0])

    def is_running(self) -> bool:
        if self.process is not None:
            return self.process.poll() is None
        if self.port and port_open(self.port):
            return True
        return self.pid() is not None

    def uptime_seconds(self) -> int:
        if self.started_at is None:
            return 0
        return int(max(time.time() - self.started_at, 0))

    # -- log --------------------------------------------------------------

    def append_log(self, line: str) -> None:
        stamp = time.strftime("%Y-%m-%d %H:%M:%S")
        text = f"[{stamp}] {line.rstrip()}"
        with self._lock:
            self.logs.append(text)
        if self.log_file:
            try:
                with open(self.log_file, "a", encoding="utf-8") as handle:
                    handle.write(text + "\n")
            except OSError:
                pass

    def log_lines(self, count: int = 80) -> list[str]:
        with self._lock:
            lines = list(self.logs)
        return lines[-max(count, 1):]

    # -- kontrol ----------------------------------------------------------

    def start(self) -> dict[str, Any]:
        if self.is_running():
            self.append_log(f"sudah jalan (port {self.port})")
            return {"ok": True, "alreadyRunning": True}

        if not self.start_command:
            raise RuntimeError("startCommand belum diisi di servers.json")

        env = os.environ.copy()
        env.update(self.env)
        command = [str(part) for part in self.start_command]
        self.append_log("menyalakan: " + " ".join(command))
        try:
            self.process = subprocess.Popen(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                env=env,
                cwd=self.workdir or None,
                start_new_session=True,
                text=True,
                bufsize=1,
            )
        except OSError as exc:
            self.append_log(f"gagal start: {exc}")
            raise RuntimeError(str(exc)) from exc

        self.started_at = time.time()
        threading.Thread(target=self._pump, args=(self.process,), daemon=True).start()
        return {"ok": True, "pid": self.process.pid}

    def _pump(self, process: subprocess.Popen) -> None:
        stream = process.stdout
        if stream is None:
            return
        for line in stream:
            self.append_log(line)
        code = process.wait()
        self.append_log(f"proses berhenti (exit {code})")

    def stop(self) -> dict[str, Any]:
        if self.stop_command:
            try:
                subprocess.run(
                    [str(part) for part in self.stop_command],
                    check=False,
                    timeout=20,
                )
                self.append_log("dihentikan lewat stopCommand")
                return {"ok": True}
            except (OSError, subprocess.SubprocessError) as exc:
                self.append_log(f"stopCommand gagal: {exc}")

        pid = self.pid()
        if pid is None:
            self.append_log("tidak ada proses untuk dihentikan")
            return {"ok": True, "stopped": False}

        self._signal(pid, signal.SIGTERM)
        for _ in range(20):
            time.sleep(0.25)
            if not port_open(self.port) and self.pid() is None:
                break
        if self.pid() is not None:
            self._signal(pid, getattr(signal, "SIGKILL", signal.SIGTERM))
        self.process = None
        self.started_at = None
        self.append_log("server dimatikan")
        return {"ok": True, "stopped": True}

    @staticmethod
    def _signal(pid: int, sig: int) -> None:
        """Kirim sinyal ke proses (dan group-nya kalau di Linux)."""
        try:
            if hasattr(os, "killpg") and hasattr(os, "getpgid"):
                try:
                    os.killpg(os.getpgid(pid), sig)
                    return
                except (OSError, ProcessLookupError):
                    pass
            os.kill(pid, sig)
        except (OSError, ProcessLookupError):
            pass

    # -- serialisasi ------------------------------------------------------

    def to_dict(self, stats: dict[str, float], with_logs: bool = False,
               log_count: int = 80) -> dict[str, Any]:
        pid = self.pid()
        data: dict[str, Any] = {
            "id": self.id,
            "name": self.name,
            "runtime": self.runtime,
            "model": self.model,
            "apiUrl": self.api_url,
            "port": self.port,
            "running": self.is_running(),
            "pid": pid,
            "uptimeSeconds": self.uptime_seconds(),
            "models": self.models,
            "stats": stats,
        }
        if with_logs:
            data["logs"] = self.log_lines(log_count)
        return data


# ── Manajer ──────────────────────────────────────────────────────────────


class Manager:
    def __init__(self, config: Config) -> None:
        self.config = config
        self.stats = HostStats()
        self._lock = threading.Lock()
        self._processes: dict[str, ManagedProcess] = {}

    def processes(self) -> list[ManagedProcess]:
        self.config.reload()
        with self._lock:
            result: list[ManagedProcess] = []
            for spec in self.config.servers:
                server_id = str(spec.get("id") or "")
                if not server_id:
                    continue
                existing = self._processes.get(server_id)
                if existing is None or existing.spec != spec:
                    existing = ManagedProcess(spec)
                    self._processes[server_id] = existing
                result.append(existing)
            # Buang entry yang sudah tidak ada di config.
            alive = {p.id for p in result}
            for server_id in list(self._processes.keys()):
                if server_id not in alive:
                    del self._processes[server_id]
            return result

    def find(self, server_id: str) -> ManagedProcess | None:
        for process in self.processes():
            if process.id == server_id:
                return process
        return None

    def list_servers(self, with_logs: bool = False,
                     log_count: int = 80) -> list[dict[str, Any]]:
        stats = self.stats.sample()
        return [p.to_dict(stats, with_logs=with_logs, log_count=log_count)
                for p in self.processes()]

    def models(self) -> list[str]:
        models: list[str] = []
        for process in self.processes():
            models.extend(process.models)
        return sorted(set(models))


# ── HTTP ─────────────────────────────────────────────────────────────────


class Handler(BaseHTTPRequestHandler):
    manager: Manager  # diisi setelah instance dibuat
    server_version = "PiercingBlowManager/1.0"

    # -- utilitas ---------------------------------------------------------

    def log_message(self, fmt: str, *args: Any) -> None:  # noqa: A003
        print(f"[manager] {self.address_string()} {fmt % args}", flush=True)

    def _cors(self) -> None:
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header(
            "Access-Control-Allow-Headers",
            "content-type, authorization, x-secret-key, x-admin-key")
        self.send_header(
            "Access-Control-Allow-Methods",
            "GET, POST, PUT, PATCH, DELETE, OPTIONS")
        self.send_header("Access-Control-Max-Age", "86400")

    def _send(self, status: int, payload: Any) -> None:
        if status == 204:
            # 204 tidak boleh punya body — kalaubody dikirim, browser
            # membalas ERR_EMPTY_RESPONSE.
            self.send_response(204)
            self._cors()
            self.end_headers()
            return
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self._cors()
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self) -> bool:
        expected = self.manager.config.secret
        if not expected:
            self._send(503, {
                "error": "secretKey belum diisi di servers.json "
                         "(isi secretKey lalu restart daemon).",
            })
            return False
        provided = self.headers.get(SECRET_HEADER, "")
        # Bandingkan sebagai bytes supaya header non-ASCII tidak bikin error.
        if not hmac.compare_digest(provided.encode("utf-8"),
                                    expected.encode("utf-8")):
            self._send(403, {"error": "Secret key salah."})
            return False
        return True

    def _path(self) -> tuple[str, dict[str, list[str]]]:
        parsed = urlparse(self.path)
        path = parsed.path
        if path.startswith("/manager"):
            path = path[len("/manager"):] or "/"
        return path, parse_qs(parsed.query)

    # -- routing ----------------------------------------------------------

    def do_OPTIONS(self) -> None:  # noqa: N802
        self._send(204, {})

    def do_GET(self) -> None:  # noqa: N802
        try:
            self._handle_get()
        except Exception as exc:  # noqa: BLE001 - jangan sampai koneksi mati
            self._send(500, {"error": f"{type(exc).__name__}: {exc}"})

    def do_POST(self) -> None:  # noqa: N802
        try:
            self._handle_post()
        except Exception as exc:  # noqa: BLE001 - jangan sampai koneksi mati
            self._send(500, {"error": f"{type(exc).__name__}: {exc}"})

    def _handle_get(self) -> None:
        if not self._authorized():
            return
        path, query = self._path()
        manager = self.manager

        if path in ("/", "/health"):
            self._send(200, {
                "ok": True,
                "service": "piercingblow-server-manager",
                "host": socket.gethostname(),
                "servers": len(manager.processes()),
            })
            return

        if path == "/servers":
            self._send(200, {"servers": manager.list_servers()})
            return

        if path == "/models":
            self._send(200, {"models": manager.models()})
            return

        parts = [p for p in path.split("/") if p]
        if len(parts) >= 2 and parts[0] == "servers":
            process = manager.find(parts[1])
            if process is None:
                self._send(404, {"error": f"Server '{parts[1]}' tidak dikenal."})
                return
            if len(parts) == 2:
                self._send(200, process.to_dict(manager.stats.sample(),
                                                with_logs=True))
                return
            action = parts[2]
            if action == "status":
                self._send(200, process.to_dict(manager.stats.sample()))
                return
            if action == "logs":
                lines = query.get("lines", ["80"])
                try:
                    count = int(lines[0])
                except (TypeError, ValueError):
                    count = 80
                self._send(200, {"lines": process.log_lines(count)})
                return
        self._send(404, {"error": "Endpoint tidak dikenal."})

    def _handle_post(self) -> None:
        if not self._authorized():
            return
        path, _ = self._path()
        parts = [p for p in path.split("/") if p]
        if len(parts) == 3 and parts[0] == "servers":
            process = self.manager.find(parts[1])
            if process is None:
                self._send(404, {"error": f"Server '{parts[1]}' tidak dikenal."})
                return
            action = parts[2]
            try:
                if action == "start":
                    result = process.start()
                elif action == "stop":
                    result = process.stop()
                else:
                    self._send(404, {"error": "Endpoint tidak dikenal."})
                    return
            except RuntimeError as exc:
                self._send(500, {"error": str(exc)})
                return
            self._send(200, result)
            return
        self._send(404, {"error": "Endpoint tidak dikenal."})


def main() -> None:
    parser = argparse.ArgumentParser(description="PiercingBlow server manager")
    parser.add_argument("--config", default=CONFIG_PATH,
                        help="path ke servers.json")
    parser.add_argument("--host", default=None,
                        help="bind address (default dari config)")
    parser.add_argument("--port", type=int, default=None,
                        help="port listener (default dari config)")
    args = parser.parse_args()

    config = Config(args.config)
    manager = Manager(config)
    Handler.manager = manager

    listen = config.data.get("listen") or {}
    host = args.host or str(listen.get("host") or "127.0.0.1")
    port = args.port or int(listen.get("port") or 8788)

    server = ThreadingHTTPServer((host, port), Handler)
    print(f"[manager] listen di http://{host}:{port} "
          f"({len(config.servers)} server terdaftar)", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[manager] berhenti", flush=True)
        server.shutdown()


if __name__ == "__main__":
    main()
