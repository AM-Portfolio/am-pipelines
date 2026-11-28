#!/usr/bin/env python3
"""Upload one AAB to a Play track and commit without review query parameters.

Env: PLAY_STORE_SERVICE_ACCOUNT_JSON, PACKAGE_NAME, AAB_PATH, TRACK,
EXPECTED_VERSION_CODE (optional). The AAB_PATH value may contain a glob.
"""

from __future__ import annotations

import glob
import json
import os
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from _play_promote_track import _access_token, _sa_json


API_ROOT = "https://androidpublisher.googleapis.com"


def _request(
    method: str,
    url: str,
    token: str,
    data: bytes | None = None,
    content_type: str = "application/json",
) -> dict:
    request = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/json",
            "Content-Type": content_type,
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=300) as response:
            body = response.read()
            return json.loads(body) if body else {}
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", "replace")
        raise RuntimeError(f"Play API {method} failed ({error.code}): {detail}") from error


def _bundle_path() -> Path:
    pattern = os.environ.get("AAB_PATH", "").strip()
    matches = [Path(path) for path in glob.glob(pattern)] if pattern else []
    if len(matches) != 1 or not matches[0].is_file():
        raise SystemExit(f"Expected exactly one AAB at AAB_PATH={pattern!r}")
    if matches[0].suffix.lower() != ".aab":
        raise SystemExit("AAB_PATH must point to an .aab file")
    return matches[0]


def main() -> None:
    package = os.environ.get("PACKAGE_NAME", "").strip()
    track = os.environ.get("TRACK", "").strip()
    expected = os.environ.get("EXPECTED_VERSION_CODE", "").strip()
    if not package or track not in ("internal", "production"):
        raise SystemExit("PACKAGE_NAME and TRACK are required")
    if expected and not expected.isdigit():
        raise SystemExit("EXPECTED_VERSION_CODE must be numeric when set")

    bundle = _bundle_path()
    token = _access_token(_sa_json())
    package_path = urllib.parse.quote(package, safe="")
    track_path = urllib.parse.quote(track, safe="")
    edit_root = f"{API_ROOT}/androidpublisher/v3/applications/{package_path}/edits"
    edit = _request("POST", edit_root, token, b"{}")
    edit_id = edit["id"]
    committed = False
    try:
        print(f"Uploading {bundle.name} to Google Play {track}")
        upload_url = (
            f"{API_ROOT}/upload/androidpublisher/v3/applications/"
            f"{package_path}/edits/{edit_id}/bundles?uploadType=media"
        )
        uploaded = _request(
            "POST", upload_url, token, bundle.read_bytes(), "application/octet-stream"
        )
        version_code = str(uploaded.get("versionCode", ""))
        if not version_code.isdigit():
            raise RuntimeError("Play upload response did not include a versionCode")
        if expected and version_code != expected:
            raise RuntimeError(
                f"Uploaded versionCode {version_code!r} did not match build {expected}"
            )

        track_url = f"{edit_root}/{edit_id}/tracks/{track_path}"
        release = {
            "track": track,
            "releases": [{"versionCodes": [version_code], "status": "completed"}],
        }
        _request("PUT", track_url, token, json.dumps(release).encode("utf-8"))

        # This app sends changes for review automatically. Do not include
        # changesNotSentForReview in the URL, even with a false value.
        _request("POST", f"{edit_root}/{edit_id}:commit", token, b"")
        committed = True
        print(f"Committed Play {track} release versionCode={version_code}")
    finally:
        if not committed:
            try:
                _request("DELETE", f"{edit_root}/{edit_id}", token)
            except Exception:
                pass


if __name__ == "__main__":
    main()
