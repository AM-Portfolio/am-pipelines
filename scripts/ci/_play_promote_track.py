#!/usr/bin/env python3
"""Promote Play versionCodes from one track to another (no AAB re-upload).

Env:
  PLAY_STORE_SERVICE_ACCOUNT_JSON or GCLOUD_SERVICE_ACCOUNT_CREDENTIALS
  PACKAGE_NAME (default com.asrax.aminvestment)
  FROM_TRACK (default internal)
  TO_TRACK (default production)
  VERSION_CODE (optional pin; else use max versionCode on FROM_TRACK)
  RELEASE_STATUS (default completed)
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
FROM_TRACK = (os.environ.get("FROM_TRACK") or "internal").strip()
TO_TRACK = (os.environ.get("TO_TRACK") or "production").strip()
RELEASE_STATUS = (os.environ.get("RELEASE_STATUS") or "completed").strip()


def _sa_json() -> dict:
    raw = (
        os.environ.get("PLAY_STORE_SERVICE_ACCOUNT_JSON")
        or os.environ.get("GCLOUD_SERVICE_ACCOUNT_CREDENTIALS")
        or ""
    ).strip()
    if not raw:
        raise SystemExit("error=no_play_credentials")
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return json.loads(base64.b64decode(raw).decode("utf-8"))


def _access_token(sa: dict) -> str:
    try:
        import jwt  # PyJWT
    except ImportError:
        subprocess.check_call(
            [sys.executable, "-m", "pip", "install", "PyJWT", "cryptography", "-q"]
        )
        import jwt

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
        return json.load(resp)["access_token"]


def main() -> None:
    sa = _sa_json()
    access = _access_token(sa)

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

    pin_raw = (os.environ.get("VERSION_CODE") or "").strip()
    pin: int | None = None
    if pin_raw:
        try:
            pin = int(pin_raw)
        except ValueError as e:
            raise SystemExit(f"error=invalid_VERSION_CODE:{pin_raw}") from e

    edit = api("POST", f"/applications/{PACKAGE}/edits", data=b"{}")
    edit_id = edit["id"]
    print(f"edit_id={edit_id}")
    print(f"from_track={FROM_TRACK} to_track={TO_TRACK}")

    try:
        src = api(
            "GET",
            f"/applications/{PACKAGE}/edits/{edit_id}/tracks/{FROM_TRACK}",
        )
        src_codes: list[int] = []
        for rel in src.get("releases") or []:
            for vc in rel.get("versionCodes") or []:
                try:
                    src_codes.append(int(vc))
                except Exception:
                    continue
        print(json.dumps({"from_track_versionCodes": src_codes}))

        if pin is not None:
            if pin not in src_codes:
                # Bundle may already be on the app even if track listing lags;
                # still allow explicit pin when Internal just uploaded it.
                print(f"warn=VERSION_CODE_{pin}_not_listed_on_{FROM_TRACK}_using_pin")
            codes = [pin]
        else:
            if not src_codes:
                raise SystemExit(
                    f"error=no_versionCodes_on_track:{FROM_TRACK}"
                )
            codes = [max(src_codes)]

        codes_str = [str(c) for c in codes]
        body = {
            "track": TO_TRACK,
            "releases": [
                {
                    "versionCodes": codes_str,
                    "status": RELEASE_STATUS,
                }
            ],
        }
        print(json.dumps({"promote": body}))
        api(
            "PUT",
            f"/applications/{PACKAGE}/edits/{edit_id}/tracks/{TO_TRACK}",
            data=json.dumps(body).encode(),
        )
        committed = api(
            "POST",
            f"/applications/{PACKAGE}/edits/{edit_id}:commit",
            data=b"{}",
        )
        print(json.dumps({"committed": True, "versionCodes": codes_str}))
        print(f"PROMOTED={'/'.join(codes_str)}")
        if committed.get("id"):
            print(f"committed_edit_id={committed.get('id')}")
    except Exception:
        try:
            api("DELETE", f"/applications/{PACKAGE}/edits/{edit_id}")
        except SystemExit:
            pass
        raise


if __name__ == "__main__":
    main()
