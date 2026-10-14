#!/usr/bin/env python3
"""Wait for ASC build VALID, clear export compliance, note/assign TestFlight groups."""

from __future__ import annotations

import os
import sys
import time
import urllib.parse
from pathlib import Path

# Allow `python path/to/testflight_wait_assign.py` from CI
sys.path.insert(0, str(Path(__file__).resolve().parent))

from asc_client import api, format_asc_errors, mint_jwt, p8_path_for_key  # noqa: E402


def main() -> int:
    key_id = os.environ["APP_STORE_CONNECT_API_KEY_ID"]
    issuer = os.environ["APP_STORE_CONNECT_API_ISSUER_ID"]
    bundle_id = os.environ["BUNDLE_ID"]
    version_code = str(os.environ["VERSION_CODE"])
    version_name = os.environ.get("VERSION_NAME", "")
    group_filter = (os.environ.get("BETA_GROUP_NAME") or "").strip()
    upload_status = os.environ.get("UPLOAD_STATUS", "")
    p8 = p8_path_for_key(key_id)
    if not p8.is_file():
        print(f"::error::Missing API key file {p8}", file=sys.stderr)
        return 1

    token = mint_jwt(key_id, issuer, p8)
    q = urllib.parse.urlencode({"filter[bundleId]": bundle_id, "limit": 1})
    status, apps = api(
        "GET", f"https://api.appstoreconnect.apple.com/v1/apps?{q}", token
    )
    if status != 200 or not apps.get("data"):
        print(
            f"::error::ASC apps lookup failed status={status} body={apps}",
            file=sys.stderr,
        )
        return 1
    app_id = apps["data"][0]["id"]
    print(f"ASC app id={app_id} bundle={bundle_id}")

    build = None
    build_id = None
    deadline = time.time() + 30 * 60
    while time.time() < deadline:
        token = mint_jwt(key_id, issuer, p8)
        q = urllib.parse.urlencode(
            {
                "filter[app]": app_id,
                "filter[version]": version_code,
                "sort": "-uploadedDate",
                "limit": 5,
            }
        )
        status, builds = api(
            "GET", f"https://api.appstoreconnect.apple.com/v1/builds?{q}", token
        )
        if status != 200:
            print(f"::warning::builds poll status={status} body={builds}")
            time.sleep(30)
            continue
        rows = builds.get("data") or []
        if not rows:
            print(f"Build {version_code} not visible yet — waiting…")
            time.sleep(30)
            continue
        build = rows[0]
        build_id = build["id"]
        attrs = build.get("attributes") or {}
        state = attrs.get("processingState")
        uploaded = attrs.get("uploadedDate")
        print(
            f"Build {version_code} id={build_id} processingState={state} uploadedDate={uploaded}"
        )
        if state == "VALID":
            break
        if state == "INVALID":
            print(f"::error::ASC build {version_code} INVALID", file=sys.stderr)
            summary = os.environ.get("GITHUB_STEP_SUMMARY")
            if summary:
                with open(summary, "a", encoding="utf-8") as fh:
                    fh.write(
                        f"\n### ASC build INVALID\n\n- build: `{version_code}`\n- id: `{build_id}`\n"
                    )
            return 1
        time.sleep(30)
    else:
        print(
            f"::error::Timed out waiting for build {version_code} VALID",
            file=sys.stderr,
        )
        return 1

    attrs = build.get("attributes") or {}
    if attrs.get("usesNonExemptEncryption") is None:
        token = mint_jwt(key_id, issuer, p8)
        st, patched = api(
            "PATCH",
            f"https://api.appstoreconnect.apple.com/v1/builds/{build_id}",
            token,
            {
                "data": {
                    "type": "builds",
                    "id": build_id,
                    "attributes": {"usesNonExemptEncryption": False},
                }
            },
        )
        print(f"Export compliance PATCH status={st}")
        if st not in (200, 204, 409):
            print(
                f"::error::Export compliance PATCH failed status={st}\n{format_asc_errors(patched)}",
                file=sys.stderr,
            )
            return 1
        token = mint_jwt(key_id, issuer, p8)
        st2, builds2 = api(
            "GET",
            f"https://api.appstoreconnect.apple.com/v1/builds/{build_id}",
            token,
        )
        enc = ((builds2.get("data") or {}).get("attributes") or {}).get(
            "usesNonExemptEncryption"
        )
        if enc is None:
            print(
                "::error::Export compliance still unset after PATCH — ASC will show Missing Compliance",
                file=sys.stderr,
            )
            return 1
        attrs["usesNonExemptEncryption"] = enc

    token = mint_jwt(key_id, issuer, p8)
    q = urllib.parse.urlencode({"filter[app]": app_id, "limit": 50})
    status, groups = api(
        "GET", f"https://api.appstoreconnect.apple.com/v1/betaGroups?{q}", token
    )
    if status != 200:
        print(
            f"::error::betaGroups list failed status={status} body={groups}",
            file=sys.stderr,
        )
        return 1

    assigned: list[str] = []
    for g in groups.get("data") or []:
        gattrs = g.get("attributes") or {}
        name = gattrs.get("name") or ""
        is_internal = bool(gattrs.get("isInternalGroup"))
        if group_filter:
            if name != group_filter:
                continue
        elif not is_internal:
            continue
        if is_internal:
            assigned.append(f"{name} (internal — auto after VALID)")
            print(
                f"Internal group '{name}' receives VALID builds automatically "
                "(ASC forbids API assign to internal groups)"
            )
            continue
        gid = g["id"]
        token = mint_jwt(key_id, issuer, p8)
        st, body = api(
            "POST",
            f"https://api.appstoreconnect.apple.com/v1/betaGroups/{gid}/relationships/builds",
            token,
            {"data": [{"type": "builds", "id": build_id}]},
        )
        if st in (200, 201, 204, 409):
            assigned.append(f"{name} (external)")
            print(f"Assigned build {version_code} → beta group '{name}' (status={st})")
        else:
            print(f"::warning::Failed to assign group '{name}' status={st} body={body}")

    if not assigned:
        print(
            "::error::No TestFlight beta groups found "
            f"(filter={group_filter or 'all Internal'}). Create an Internal group in ASC.",
            file=sys.stderr,
        )
        return 1

    summary = [
        "",
        "### ASC / TestFlight assignment",
        "",
        f"- Marketing version: `{version_name}`",
        f"- Build number: `{version_code}`",
        f"- ASC build id: `{build_id}`",
        f"- uploadedDate: `{attrs.get('uploadedDate')}`",
        f"- processingState: `{attrs.get('processingState')}`",
        f"- altool: `{upload_status}`",
        f"- Beta groups: {', '.join(f'`{a}`' for a in assigned)}",
        "",
    ]
    step_summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if step_summary:
        with open(step_summary, "a", encoding="utf-8") as fh:
            fh.write("\n".join(summary) + "\n")
    print(
        f"::notice::TestFlight ready {version_name} ({version_code}) "
        f"uploaded={attrs.get('uploadedDate')} groups={', '.join(assigned)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
