#!/usr/bin/env python3
"""
IPPanelReceiver receives signed IP change reports from ippanelbot and updates
local easynftables forwarding targets through the local `nf` command.
"""

from __future__ import annotations

import argparse
import hmac
import ipaddress
import json
import secrets
import shlex
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from hashlib import sha256
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit


DEFAULT_CONFIG_PATH = "/etc/ippanelreceiver/config.json"
SIGNATURE_HEADERS = (
    "X-IPPanelReceiver-Signature",
    "X-Relay-Signature",
    "X-Report-Signature",
)


def utc_now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


class ConfigError(ValueError):
    pass


@dataclass(frozen=True)
class ReporterConfig:
    reporter_id: str
    secret: str
    allowed_sources: tuple[ipaddress._BaseNetwork | ipaddress._BaseAddress, ...]


@dataclass(frozen=True)
class TargetConfig:
    target_name: str
    allowed_reporters: tuple[str, ...]
    match_modes: tuple[str, ...]
    remark: str


@dataclass(frozen=True)
class AppConfig:
    listen_host: str
    listen_port: int
    report_path: str
    max_body_bytes: int
    timestamp_window_seconds: int
    nonce_ttl_seconds: int
    nf_command: tuple[str, ...]
    nf_timeout_seconds: int
    allow_private_target_ips: bool
    reporters: dict[str, ReporterConfig]
    targets: dict[str, TargetConfig]


class NonceCache:
    def __init__(self, ttl_seconds: int) -> None:
        self.ttl_seconds = ttl_seconds
        self._lock = threading.Lock()
        self._nonces: dict[str, dict[str, float]] = {}

    def seen_or_add(self, namespace: str, nonce: str, now: float) -> bool:
        expires_at = now + self.ttl_seconds
        with self._lock:
            self._cleanup_locked(now)
            bucket = self._nonces.setdefault(namespace, {})
            if nonce in bucket:
                return True
            bucket[nonce] = expires_at
            return False

    def _cleanup_locked(self, now: float) -> None:
        empty_namespaces: list[str] = []
        for namespace, bucket in self._nonces.items():
            for nonce in [key for key, expires_at in bucket.items() if expires_at <= now]:
                del bucket[nonce]
            if not bucket:
                empty_namespaces.append(namespace)
        for namespace in empty_namespaces:
            del self._nonces[namespace]


class ReceiverServer(ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, server_address: tuple[str, int], config: AppConfig) -> None:
        super().__init__(server_address, ReceiverHandler)
        self.config = config
        self.nonce_cache = NonceCache(config.nonce_ttl_seconds)


class ReceiverHandler(BaseHTTPRequestHandler):
    server: ReceiverServer

    def log_message(self, fmt: str, *args: Any) -> None:
        return

    def do_GET(self) -> None:
        path = urlsplit(self.path).path
        if path == "/health":
            self._send_json(200, {"ok": True, "service": "ippanelreceiver"})
            return
        self._send_json(404, {"ok": False, "error": "not_found"})

    def do_POST(self) -> None:
        request_path = urlsplit(self.path).path
        if request_path != self.server.config.report_path:
            self._send_json(404, {"ok": False, "error": "not_found"})
            return

        try:
            raw_body = self._read_body()
            payload = parse_payload(raw_body)
            reporter_id = require_string(payload, "reporter")
            target_name = require_string(payload, "target_name")
            match_mode = require_string(payload, "match_mode")
            new_ip = require_string(payload, "ip")
            timestamp_value = require_int(payload, "ts")
            nonce = require_string(payload, "nonce")
        except ValueError as exc:
            self._send_json(400, {"ok": False, "error": "invalid_request", "detail": str(exc)})
            return

        reporter = self.server.config.reporters.get(reporter_id)
        if reporter is None:
            self._send_json(403, {"ok": False, "error": "unknown_reporter"})
            return

        source_ip = self.client_address[0]
        if not source_is_allowed(source_ip, reporter.allowed_sources):
            self._log(f"source_denied reporter={reporter_id} source={source_ip}")
            self._send_json(403, {"ok": False, "error": "source_denied"})
            return

        signature = first_header(self.headers, SIGNATURE_HEADERS)
        if not verify_signature(reporter.secret, raw_body, signature):
            self._log(f"bad_signature reporter={reporter_id} source={source_ip}")
            self._send_json(403, {"ok": False, "error": "bad_signature"})
            return

        now = int(time.time())
        if abs(now - timestamp_value) > self.server.config.timestamp_window_seconds:
            self._send_json(400, {"ok": False, "error": "timestamp_out_of_window"})
            return

        if self.server.nonce_cache.seen_or_add(reporter_id, nonce, float(now)):
            self._send_json(409, {"ok": False, "error": "replayed_nonce"})
            return

        target = self.server.config.targets.get(target_name)
        if target is None:
            self._send_json(403, {"ok": False, "error": "unknown_target"})
            return

        if reporter_id not in target.allowed_reporters:
            self._send_json(403, {"ok": False, "error": "reporter_not_allowed_for_target"})
            return

        if match_mode not in target.match_modes:
            self._send_json(403, {"ok": False, "error": "match_mode_not_allowed"})
            return

        try:
            validate_target_ipv4(new_ip, self.server.config.allow_private_target_ips)
            nf_args = build_nf_args(target, match_mode, payload, new_ip, self.server.config.allow_private_target_ips)
        except ValueError as exc:
            self._send_json(400, {"ok": False, "error": "invalid_target", "detail": str(exc)})
            return

        success, detail, stdout, stderr = run_nf_command(
            self.server.config.nf_command,
            nf_args,
            self.server.config.nf_timeout_seconds,
        )
        if not success:
            self._log(
                f"update_failed reporter={reporter_id} target_name={target_name} mode={match_mode} "
                f"source={source_ip} ip={new_ip} detail={detail}"
            )
            self._send_json(
                500,
                {
                    "ok": False,
                    "error": "nf_update_failed",
                    "detail": detail,
                    "stdout": stdout,
                    "stderr": stderr,
                },
            )
            return

        self._log(
            f"updated reporter={reporter_id} target_name={target_name} mode={match_mode} "
            f"source={source_ip} ip={new_ip}"
        )
        self._send_json(
            200,
            {
                "ok": True,
                "reporter": reporter_id,
                "target_name": target_name,
                "match_mode": match_mode,
                "ip": new_ip,
                "stdout": stdout,
            },
        )

    def _read_body(self) -> bytes:
        content_length = self.headers.get("Content-Length", "")
        try:
            body_length = int(content_length)
        except ValueError as exc:
            raise ValueError("invalid Content-Length") from exc
        if body_length < 0:
            raise ValueError("invalid Content-Length")
        if body_length > self.server.config.max_body_bytes:
            raise ValueError("body too large")
        return self.rfile.read(body_length)

    def _send_json(self, status_code: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    @staticmethod
    def _log(message: str) -> None:
        print(f"[{utc_now()}] {message}", flush=True)


def first_header(headers: Any, names: tuple[str, ...]) -> str:
    for name in names:
        value = headers.get(name)
        if value:
            return value
    return ""


def parse_payload(raw_body: bytes) -> dict[str, Any]:
    try:
        payload = json.loads(raw_body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError(f"body is not valid JSON: {exc}") from exc
    if not isinstance(payload, dict):
        raise ValueError("JSON body must be an object")
    return payload


def require_string(payload: dict[str, Any], key: str) -> str:
    value = payload.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"field '{key}' must be a non-empty string")
    return value.strip()


def require_int(payload: dict[str, Any], key: str) -> int:
    value = payload.get(key)
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError(f"field '{key}' must be an integer")
    return value


def verify_signature(secret: str, raw_body: bytes, signature_header: str) -> bool:
    signature = signature_header.strip()
    if signature.startswith("sha256="):
        signature = signature[len("sha256=") :]
    if not signature:
        return False
    expected = hmac.new(secret.encode("utf-8"), raw_body, sha256).hexdigest()
    return hmac.compare_digest(expected, signature.lower())


def parse_allowed_source(value: str) -> ipaddress._BaseNetwork | ipaddress._BaseAddress:
    value = value.strip()
    if not value:
        raise ConfigError("allowed source must not be empty")
    try:
        if "/" in value:
            return ipaddress.ip_network(value, strict=False)
        return ipaddress.ip_address(value)
    except ValueError as exc:
        raise ConfigError(f"invalid allowed source: {value}") from exc


def source_is_allowed(source_ip: str, allowed_sources: tuple[ipaddress._BaseNetwork | ipaddress._BaseAddress, ...]) -> bool:
    try:
        parsed_source = ipaddress.ip_address(source_ip)
    except ValueError:
        return False
    for allowed in allowed_sources:
        if isinstance(allowed, ipaddress._BaseNetwork):
            if parsed_source in allowed:
                return True
        elif parsed_source == allowed:
            return True
    return False


def validate_target_ipv4(value: str, allow_private: bool) -> None:
    try:
        parsed = ipaddress.ip_address(value)
    except ValueError as exc:
        raise ValueError(f"invalid IPv4 address: {value}") from exc

    if parsed.version != 4:
        raise ValueError("only IPv4 is supported")
    if parsed.is_unspecified or parsed.is_loopback or parsed.is_multicast or parsed.is_reserved:
        raise ValueError(f"unusable IPv4 address: {value}")
    if not allow_private and (parsed.is_private or parsed.is_link_local):
        raise ValueError(f"private/link-local target IP is not allowed: {value}")


def build_nf_args(
    target: TargetConfig,
    match_mode: str,
    payload: dict[str, Any],
    new_ip: str,
    allow_private: bool,
) -> list[str]:
    if match_mode == "remark":
        return ["--set-dest-ip-by-remark", target.remark, new_ip]
    if match_mode == "old_ip":
        old_ip = require_string(payload, "old_ip")
        validate_target_ipv4(old_ip, allow_private)
        return ["--set-dest-ip-by-current-ip", old_ip, new_ip]
    if match_mode == "old_ip_unique":
        old_ip = require_string(payload, "old_ip")
        validate_target_ipv4(old_ip, allow_private)
        return ["--set-dest-ip-by-current-ip-unique", old_ip, new_ip]
    raise ValueError(f"unsupported match mode: {match_mode}")


def run_nf_command(
    nf_command: tuple[str, ...],
    nf_args: list[str],
    timeout_seconds: int,
) -> tuple[bool, str, str, str]:
    command = [*nf_command, *nf_args]
    try:
        completed = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=timeout_seconds,
            check=False,
        )
    except OSError as exc:
        return False, f"execute_failed: {exc}", "", str(exc)
    except subprocess.TimeoutExpired as exc:
        stdout = exc.stdout if isinstance(exc.stdout, str) else ""
        stderr = exc.stderr if isinstance(exc.stderr, str) else ""
        return False, f"timeout_after_{timeout_seconds}s", stdout, stderr

    stdout = (completed.stdout or "").strip()
    stderr = (completed.stderr or "").strip()
    if completed.returncode != 0:
        return False, f"exit_code={completed.returncode}", stdout, stderr
    return True, f"exit_code={completed.returncode}", stdout, stderr


def load_config(path: Path) -> AppConfig:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise ConfigError(f"failed to read config: {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise ConfigError(f"config is not valid JSON: {exc}") from exc

    if not isinstance(raw, dict):
        raise ConfigError("config root must be an object")

    listen = raw.get("listen", {})
    if not isinstance(listen, dict):
        raise ConfigError("listen must be an object")

    listen_host = str(listen.get("host", "127.0.0.1")).strip()
    if not listen_host:
        raise ConfigError("listen.host must not be empty")
    listen_port = read_int(listen, "port", 8787, minimum=1, maximum=65535)
    report_path = str(listen.get("path", "/report")).strip() or "/report"
    if not report_path.startswith("/"):
        raise ConfigError("listen.path must start with /")

    nf_command_raw = raw.get("nf_command", "/usr/local/sbin/nf")
    if isinstance(nf_command_raw, str):
        nf_command = tuple(shlex.split(nf_command_raw))
    elif isinstance(nf_command_raw, list) and all(isinstance(item, str) for item in nf_command_raw):
        nf_command = tuple(nf_command_raw)
    else:
        raise ConfigError("nf_command must be a string or string array")
    if not nf_command:
        raise ConfigError("nf_command must not be empty")

    reporters = load_reporters(raw.get("reporters"))
    targets = load_targets(raw.get("targets"))
    validate_target_reporters(targets, reporters)

    return AppConfig(
        listen_host=listen_host,
        listen_port=listen_port,
        report_path=report_path,
        max_body_bytes=read_int(raw, "max_body_bytes", 4096, minimum=1),
        timestamp_window_seconds=read_int(raw, "timestamp_window_seconds", 120, minimum=1),
        nonce_ttl_seconds=read_int(raw, "nonce_ttl_seconds", 600, minimum=1),
        nf_command=nf_command,
        nf_timeout_seconds=read_int(raw, "nf_timeout_seconds", 30, minimum=1),
        allow_private_target_ips=read_bool(raw, "allow_private_target_ips", False),
        reporters=reporters,
        targets=targets,
    )


def read_int(raw: dict[str, Any], key: str, default: int, *, minimum: int | None = None, maximum: int | None = None) -> int:
    value = raw.get(key, default)
    if isinstance(value, bool) or not isinstance(value, int):
        raise ConfigError(f"{key} must be an integer")
    if minimum is not None and value < minimum:
        raise ConfigError(f"{key} must be >= {minimum}")
    if maximum is not None and value > maximum:
        raise ConfigError(f"{key} must be <= {maximum}")
    return value


def read_bool(raw: dict[str, Any], key: str, default: bool) -> bool:
    value = raw.get(key, default)
    if not isinstance(value, bool):
        raise ConfigError(f"{key} must be a boolean")
    return value


def load_reporters(raw_reporters: Any) -> dict[str, ReporterConfig]:
    if not isinstance(raw_reporters, dict) or not raw_reporters:
        raise ConfigError("reporters must be a non-empty object")

    reporters: dict[str, ReporterConfig] = {}
    for reporter_id, raw in raw_reporters.items():
        if not isinstance(reporter_id, str) or not reporter_id.strip():
            raise ConfigError("reporter id must be a non-empty string")
        if not isinstance(raw, dict):
            raise ConfigError(f"reporter '{reporter_id}' must be an object")

        secret = str(raw.get("secret", "") or "").strip()
        if len(secret) < 24:
            raise ConfigError(f"reporter '{reporter_id}' secret must be at least 24 characters")

        allowed_raw = raw.get("allowed_ips", raw.get("allowed_sources"))
        if not isinstance(allowed_raw, list) or not allowed_raw:
            raise ConfigError(f"reporter '{reporter_id}' allowed_ips must be a non-empty array")
        allowed_sources = tuple(parse_allowed_source(str(item)) for item in allowed_raw)

        reporter_key = reporter_id.strip()
        reporters[reporter_key] = ReporterConfig(
            reporter_id=reporter_key,
            secret=secret,
            allowed_sources=allowed_sources,
        )

    return reporters


def load_targets(raw_targets: Any) -> dict[str, TargetConfig]:
    if not isinstance(raw_targets, dict) or not raw_targets:
        raise ConfigError("targets must be a non-empty object")

    allowed_modes = {"remark", "old_ip", "old_ip_unique"}
    targets: dict[str, TargetConfig] = {}
    for target_name, raw in raw_targets.items():
        if not isinstance(target_name, str) or not target_name.strip():
            raise ConfigError("target_name must be a non-empty string")
        if not isinstance(raw, dict):
            raise ConfigError(f"target '{target_name}' must be an object")

        allowed_reporters_raw = raw.get("allowed_reporters")
        if not isinstance(allowed_reporters_raw, list) or not allowed_reporters_raw:
            raise ConfigError(f"target '{target_name}' allowed_reporters must be a non-empty array")
        allowed_reporters = tuple(str(item).strip() for item in allowed_reporters_raw if str(item).strip())
        if not allowed_reporters:
            raise ConfigError(f"target '{target_name}' allowed_reporters must not be empty")

        match_modes_raw = raw.get("match_modes", ["remark"])
        if not isinstance(match_modes_raw, list) or not match_modes_raw:
            raise ConfigError(f"target '{target_name}' match_modes must be a non-empty array")
        match_modes = tuple(str(item).strip() for item in match_modes_raw if str(item).strip())
        invalid_modes = [mode for mode in match_modes if mode not in allowed_modes]
        if invalid_modes:
            raise ConfigError(f"target '{target_name}' has invalid match_modes: {', '.join(invalid_modes)}")

        target_key = target_name.strip()
        remark = str(raw.get("remark", "") or "").strip()
        if not remark:
            raise ConfigError(f"target '{target_name}' remark must be a non-empty string")
        targets[target_key] = TargetConfig(
            target_name=target_key,
            allowed_reporters=allowed_reporters,
            match_modes=match_modes,
            remark=remark,
        )
    return targets


def validate_target_reporters(targets: dict[str, TargetConfig], reporters: dict[str, ReporterConfig]) -> None:
    for target in targets.values():
        for reporter_id in target.allowed_reporters:
            if reporter_id not in reporters:
                raise ConfigError(f"target '{target.target_name}' references unknown reporter '{reporter_id}'")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Receive signed ippanelbot reports and update easynftables.")
    parser.add_argument("--config", default=DEFAULT_CONFIG_PATH, help="Path to receiver JSON config.")
    parser.add_argument("--check-config", action="store_true", help="Validate config and exit.")
    parser.add_argument("--make-secret", action="store_true", help="Generate a random reporter secret and exit.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.make_secret:
        print(secrets.token_urlsafe(32))
        return 0

    try:
        config = load_config(Path(args.config))
    except ConfigError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    if args.check_config:
        print(
            f"ok: config loaded reporters={len(config.reporters)} targets={len(config.targets)} "
            f"listen={config.listen_host}:{config.listen_port}{config.report_path}"
        )
        return 0

    server = ReceiverServer((config.listen_host, config.listen_port), config)
    print(
        f"[{utc_now()}] ippanelreceiver listening on "
        f"{config.listen_host}:{config.listen_port}{config.report_path} "
        f"reporters={len(config.reporters)} targets={len(config.targets)}",
        flush=True,
    )

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print(f"\n[{utc_now()}] shutting down", flush=True)
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
