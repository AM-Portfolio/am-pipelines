#!/usr/bin/env python3
"""Print PLAY_MAX versionCode for a Play package (last line PLAY_MAX=N).

Uses PLAY_STORE_SERVICE_ACCOUNT_JSON or GCLOUD_SERVICE_ACCOUNT_CREDENTIALS
(raw or base64-wrapped Play API service-account JSON).
"""
from __future__ import annotations

import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

PACKAGE = os.environ.get("PACKAGE_NAME", "com.asrax.aminvestment")


def main() -> None:
    try:
        import jwt  # PyJWT
    except ImportError:
        subprocess.check_call(
            [sys.executable, "-m", "pip", "install", "PyJWT", "cryptography", "-q"]
        )
        import jwt

    raw = (
        os.environ.get("PLAY_STORE_SERVICE_ACCOUNT_JSON")
        or os.environ.get("GCLOUD_SERVICE_ACCOUNT_CREDENTIALS")
        or ""
    ).strip()
    if not raw:
        print("PLAY_MAX=0")
        print("NEXT=1")
        print("warn=no_play_credentials")
        return

    try:
        sa = json.loads(raw)
    except json.JSONDecodeError:
        sa = json.loads(base64.b64decode(raw).decode("utf-8"))

    now = int(time.time())
    assertion = jwt.encode(
        {
            "iss": sa["client_email"],
            "scope": "https://www.googleapis.com/auth/androidpublisher",
            "aud": "https://oauth2.googleapis.com/token",
            "iat": now,
            "exp": now + 3500,
        },
        sa["private_key"],
        algorithm="RS256",
    )
    if isinstance(assertion, bytes):
        assertion = assertion.decode()

    token_body = urllib.parse.urlencode(
        {
            "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
            "assertion": assertion,
        }
    ).encode()
    tok_req = urllib.request.Request(
        "https://oauth2.googleapis.com/token",
        data=token_body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    with urllib.request.urlopen(tok_req) as resp:
        access = json.load(resp)["access_token"]

    def api(method: str, path: str, data: bytes | None = None):
        url = f"https://androidpublisher.googleapis.com/androidpublisher/v3{path}"
        req = urllib.request.Request(
            url,
            data=data,
            method=method,
            headers={
                "Authorization": f"Bearer {access}",
                "Accept": "application/json",
                "Content-Type": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(req) as r:
                body = r.read().decode()
                return json.loads(body) if body else {}
        except urllib.error.HTTPError as e:
            err = e.read().decode()
            raise SystemExit(f"Play API {method} {path} -> {e.code}: {err}") from e

    edit = api("POST", f"/applications/{PACKAGE}/edits", data=b"{}")
    edit_id = edit["id"]
    print(f"edit_id={edit_id}")

    nums: list[int] = []
    try:
        tracks = api("GET", f"/applications/{PACKAGE}/edits/{edit_id}/tracks")
        for track in tracks.get("tracks") or []:
            tname = track.get("track")
            for rel in track.get("releases") or []:
                for vc in rel.get("versionCodes") or []:
                    try:
                        n = int(vc)
                    except Exception:
                        continue
                    nums.append(n)
                    print(
                        json.dumps(
                            {
                                "track": tname,
                                "status": rel.get("status"),
                                "versionCode": n,
                                "name": rel.get("name"),
                            }
                        )
                    )

        bundles = api("GET", f"/applications/{PACKAGE}/edits/{edit_id}/bundles")
        for b in bundles.get("bundles") or []:
            try:
                n = int(b.get("versionCode"))
            except Exception:
                continue
            nums.append(n)
            print(json.dumps({"bundle": n, "sha1": b.get("sha1")}))
    finally:
        try:
            api("DELETE", f"/applications/{PACKAGE}/edits/{edit_id}")
        except SystemExit:
            pass

    play_max = max(nums) if nums else 0
    print(f"PLAY_MAX={play_max}")
    print(f"NEXT={play_max + 1}")


if __name__ == "__main__":
    main()
