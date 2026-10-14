#!/usr/bin/env python3
"""Attach this run's IPA build to an App Store version and submit for review."""

from __future__ import annotations

import os
import sys
import time
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from asc_client import api, format_asc_errors, mint_jwt, p8_path_for_key  # noqa: E402


def main() -> int:
    key_id = os.environ["APP_STORE_CONNECT_API_KEY_ID"]
    issuer = os.environ["APP_STORE_CONNECT_API_ISSUER_ID"]
    bundle_id = os.environ["BUNDLE_ID"]
    version_code = str(os.environ["VERSION_CODE"])
    version_name = os.environ["VERSION_NAME"]
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
    print(f"ASC app id={app_id}")

    build = None
    build_id = None
    battrs: dict = {}
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
        battrs = build.get("attributes") or {}
        state = battrs.get("processingState")
        print(
            f"Build {version_code} id={build_id} state={state} "
            f"encryption={battrs.get('usesNonExemptEncryption')}"
        )
        if state == "VALID":
            break
        if state == "INVALID":
            print(
                f"::error::ASC build {version_code} INVALID — cannot submit",
                file=sys.stderr,
            )
            return 1
        time.sleep(30)
    else:
        print(
            f"::error::Timed out waiting for build {version_code} VALID",
            file=sys.stderr,
        )
        return 1

    token = mint_jwt(key_id, issuer, p8)
    q = urllib.parse.urlencode(
        {
            "filter[platform]": "IOS",
            "filter[versionString]": version_name,
            "limit": 5,
        }
    )
    status, vers = api(
        "GET",
        f"https://api.appstoreconnect.apple.com/v1/apps/{app_id}/appStoreVersions?{q}",
        token,
    )
    version_id = None
    if status == 200 and vers.get("data"):
        version_id = vers["data"][0]["id"]
        print(f"Using existing App Store version {version_name} id={version_id}")
    else:
        # Prefer editable version already in PREPARE_FOR_SUBMISSION (rename if needed)
        token = mint_jwt(key_id, issuer, p8)
        status, allv = api(
            "GET",
            f"https://api.appstoreconnect.apple.com/v1/apps/{app_id}/appStoreVersions?"
            + urllib.parse.urlencode({"filter[platform]": "IOS", "limit": 20}),
            token,
        )
        for v in allv.get("data") or []:
            state = (v.get("attributes") or {}).get("appStoreState")
            if state == "PREPARE_FOR_SUBMISSION":
                version_id = v["id"]
                cur = (v.get("attributes") or {}).get("versionString")
                if cur != version_name:
                    token = mint_jwt(key_id, issuer, p8)
                    st, renamed = api(
                        "PATCH",
                        f"https://api.appstoreconnect.apple.com/v1/appStoreVersions/{version_id}",
                        token,
                        {
                            "data": {
                                "type": "appStoreVersions",
                                "id": version_id,
                                "attributes": {"versionString": version_name},
                            }
                        },
                    )
                    print(
                        f"Renamed App Store version {cur} → {version_name} status={st}"
                    )
                    if st not in (200, 204):
                        print(format_asc_errors(renamed), file=sys.stderr)
                        return 1
                break
        if not version_id:
            token = mint_jwt(key_id, issuer, p8)
            st, created = api(
                "POST",
                "https://api.appstoreconnect.apple.com/v1/appStoreVersions",
                token,
                {
                    "data": {
                        "type": "appStoreVersions",
                        "attributes": {
                            "platform": "IOS",
                            "versionString": version_name,
                        },
                        "relationships": {
                            "app": {"data": {"type": "apps", "id": app_id}}
                        },
                    }
                },
            )
            if st not in (200, 201):
                print(
                    f"::error::Could not create App Store version {version_name}\n"
                    f"{format_asc_errors(created)}",
                    file=sys.stderr,
                )
                return 1
            version_id = created["data"]["id"]
            print(f"Created App Store version {version_name} id={version_id}")

    token = mint_jwt(key_id, issuer, p8)
    st, rel = api(
        "PATCH",
        f"https://api.appstoreconnect.apple.com/v1/appStoreVersions/{version_id}/relationships/build",
        token,
        {"data": {"type": "builds", "id": build_id}},
    )
    print(f"Attach build {version_code} → version {version_name} status={st}")
    if st not in (200, 204):
        print(format_asc_errors(rel), file=sys.stderr)
        return 1

    # Open or create review submission
    token = mint_jwt(key_id, issuer, p8)
    st, existing = api(
        "GET",
        "https://api.appstoreconnect.apple.com/v1/reviewSubmissions?"
        + urllib.parse.urlencode(
            {"filter[app]": app_id, "filter[platform]": "IOS", "limit": 10}
        ),
        token,
    )
    submission_id = None
    for s in existing.get("data") or []:
        state = (s.get("attributes") or {}).get("state")
        if state in ("READY_FOR_REVIEW", "UNRESOLVED_ISSUES"):
            submission_id = s["id"]
            print(f"Reusing reviewSubmission {submission_id} state={state}")
            break
    if not submission_id:
        token = mint_jwt(key_id, issuer, p8)
        st, rs = api(
            "POST",
            "https://api.appstoreconnect.apple.com/v1/reviewSubmissions",
            token,
            {
                "data": {
                    "type": "reviewSubmissions",
                    "attributes": {"platform": "IOS"},
                    "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
                }
            },
        )
        if st not in (200, 201):
            print(
                f"::error::Could not create reviewSubmission\n{format_asc_errors(rs)}",
                file=sys.stderr,
            )
            return 1
        submission_id = rs["data"]["id"]
        print(f"Created reviewSubmission {submission_id}")

    token = mint_jwt(key_id, issuer, p8)
    st, item = api(
        "POST",
        "https://api.appstoreconnect.apple.com/v1/reviewSubmissionItems",
        token,
        {
            "data": {
                "type": "reviewSubmissionItems",
                "relationships": {
                    "reviewSubmission": {
                        "data": {"type": "reviewSubmissions", "id": submission_id}
                    },
                    "appStoreVersion": {
                        "data": {"type": "appStoreVersions", "id": version_id}
                    },
                },
            }
        },
    )
    if st not in (200, 201):
        print(
            "::error::Cannot add App Store version to review submission. "
            "Fix ASC metadata (screenshots, App Privacy, etc.) then re-run.\n"
            f"{format_asc_errors(item)}",
            file=sys.stderr,
        )
        summary = os.environ.get("GITHUB_STEP_SUMMARY")
        if summary:
            with open(summary, "a", encoding="utf-8") as fh:
                fh.write(
                    "\n### App Store submit blocked\n\n"
                    "ASC rejected reviewSubmissionItems. Typical gaps: screenshots, "
                    "App Privacy, category, pricing.\n\n"
                    f"```\n{format_asc_errors(item)}\n```\n"
                )
        return 1

    token = mint_jwt(key_id, issuer, p8)
    st, submitted = api(
        "PATCH",
        f"https://api.appstoreconnect.apple.com/v1/reviewSubmissions/{submission_id}",
        token,
        {
            "data": {
                "type": "reviewSubmissions",
                "id": submission_id,
                "attributes": {"submitted": True},
            }
        },
    )
    if st not in (200, 204):
        print(
            f"::error::Submit for Review failed\n{format_asc_errors(submitted)}",
            file=sys.stderr,
        )
        return 1

    sattrs = (submitted.get("data") or {}).get("attributes") or {}
    print(
        f"::notice::Submitted {version_name} ({version_code}) for App Store review — {sattrs}"
    )

    token = mint_jwt(key_id, issuer, p8)
    st, v = api(
        "GET",
        f"https://api.appstoreconnect.apple.com/v1/appStoreVersions/{version_id}",
        token,
    )
    vattrs = (v.get("data") or {}).get("attributes") or {}
    lines = [
        "",
        "### App Store Submit for Review",
        "",
        f"- Marketing version: `{version_name}`",
        f"- Build number: `{version_code}`",
        f"- ASC version state: `{vattrs.get('appStoreState')}`",
        f"- reviewSubmission: `{submission_id}` state=`{sattrs.get('state')}`",
        "",
    ]
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
