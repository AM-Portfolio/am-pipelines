"""Shared App Store Connect API helpers for Mobile CI iOS jobs."""

from __future__ import annotations

import base64
import json
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def mint_jwt(key_id: str, issuer: str, p8_path: Path) -> str:
    now = int(time.time())
    header = b64url(
        json.dumps(
            {"alg": "ES256", "kid": key_id, "typ": "JWT"}, separators=(",", ":")
        ).encode()
    )
    payload = b64url(
        json.dumps(
            {
                "iss": issuer,
                "iat": now,
                "exp": now + 20 * 60,
                "aud": "appstoreconnect-v1",
            },
            separators=(",", ":"),
        ).encode()
    )
    signing_input = f"{header}.{payload}".encode()
    with tempfile.NamedTemporaryFile(suffix=".sig", delete=False) as sigf:
        sig_path = sigf.name
    try:
        subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", str(p8_path), "-out", sig_path],
            input=signing_input,
            check=True,
        )
        der = Path(sig_path).read_bytes()
    finally:
        Path(sig_path).unlink(missing_ok=True)

    i = 0
    assert der[i] == 0x30
    i += 1
    if der[i] & 0x80:
        i += 1 + (der[i] & 0x7F)
    else:
        i += 1

    def read_int() -> bytes:
        nonlocal i
        assert der[i] == 0x02
        i += 1
        ln = der[i]
        i += 1
        val = der[i : i + ln]
        i += ln
        return val

    r = read_int().lstrip(b"\x00").rjust(32, b"\x00")[-32:]
    s = read_int().lstrip(b"\x00").rjust(32, b"\x00")[-32:]
    return f"{header}.{payload}.{b64url(r + s)}"


def api(method: str, url: str, token: str, body: Any = None) -> tuple[int, dict]:
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=90) as resp:
            raw = resp.read().decode()
            return resp.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            parsed = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            parsed = {"raw": raw}
        return e.code, parsed


def p8_path_for_key(key_id: str, cwd: Path | None = None) -> Path:
    root = cwd or Path.cwd()
    return root / "private_keys" / f"AuthKey_{key_id}.p8"


def format_asc_errors(body: dict) -> str:
    """Flatten ASC error payloads (including associatedErrors) for CI logs."""
    lines: list[str] = []
    for err in body.get("errors") or []:
        detail = err.get("detail") or err.get("title") or str(err)
        lines.append(f"- {detail}")
        meta = (err.get("meta") or {}).get("associatedErrors") or {}
        for path, elist in meta.items():
            lines.append(f"  path: {path}")
            for e in elist:
                lines.append(f"    - {e.get('detail') or e.get('title') or e}")
    return "\n".join(lines) if lines else json.dumps(body)[:2000]
