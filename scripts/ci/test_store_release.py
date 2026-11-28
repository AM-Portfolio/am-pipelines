"""Contract checks for store release requests; no store credentials required."""

from __future__ import annotations

import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

CI_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(CI_DIR))
sys.path.insert(0, str(CI_DIR.parents[1] / ".github" / "workflows" / "ios"))

import _play_upload_bundle as play_upload  # noqa: E402
import appstore_submit as appstore  # noqa: E402


class PlayUploadTests(unittest.TestCase):
    def test_commit_omits_review_query_parameter(self) -> None:
        calls = []

        def request(method, url, token, data=None, content_type="application/json"):
            calls.append((method, url, data))
            if url.endswith("/edits"):
                return {"id": "edit-123"}
            if "/bundles?" in url:
                self.assertEqual(data, b"test-aab")
                return {"versionCode": 1411}
            return {}

        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory) / "app-release.aab"
            bundle.write_bytes(b"test-aab")
            env = {
                "PACKAGE_NAME": "com.asrax.aminvestment",
                "TRACK": "internal",
                "EXPECTED_VERSION_CODE": "1411",
                "AAB_PATH": str(bundle),
            }
            with patch.dict(os.environ, env), patch.object(
                play_upload, "_sa_json", return_value={}
            ), patch.object(play_upload, "_access_token", return_value="token"), patch.object(
                play_upload, "_request", side_effect=request
            ):
                play_upload.main()

        self.assertEqual([call[0] for call in calls], ["POST", "POST", "PUT", "POST"])
        commit_url = calls[-1][1]
        self.assertTrue(commit_url.endswith("/edits/edit-123:commit"))
        self.assertNotIn("?", commit_url)
        self.assertEqual(
            json.loads(calls[2][2]),
            {
                "track": "internal",
                "releases": [{"versionCodes": ["1411"], "status": "completed"}],
            },
        )

    def test_artifact_reuse_accepts_play_version_code(self) -> None:
        calls = []

        def request(method, url, token, data=None, content_type="application/json"):
            calls.append((method, url))
            if url.endswith("/edits"):
                return {"id": "edit-456"}
            if "/bundles?" in url:
                return {"versionCode": 2222}
            return {}

        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory) / "app-release.aab"
            bundle.write_bytes(b"test-aab")
            env = {
                "PACKAGE_NAME": "com.asrax.aminvestment",
                "TRACK": "production",
                "EXPECTED_VERSION_CODE": "",
                "AAB_PATH": str(bundle),
            }
            with patch.dict(os.environ, env), patch.object(
                play_upload, "_sa_json", return_value={}
            ), patch.object(play_upload, "_access_token", return_value="token"), patch.object(
                play_upload, "_request", side_effect=request
            ):
                play_upload.main()

        self.assertEqual(calls[-1][0], "POST")
        self.assertTrue(calls[-1][1].endswith("/edits/edit-456:commit"))
        self.assertNotIn("?", calls[-1][1])


class AppStoreSubmitTests(unittest.TestCase):
    def test_unresolved_submission_stops_before_attaching_build(self) -> None:
        calls = []

        def api(method, url, token, data=None):
            calls.append((method, url))
            if "/v1/apps?" in url:
                return 200, {"data": [{"id": "app-id"}]}
            if "/v1/builds?" in url:
                return 200, {
                    "data": [{"id": "build-id", "attributes": {"processingState": "VALID"}}]
                }
            if "/appStoreVersions?" in url:
                return 200, {"data": [{"id": "version-id"}]}
            if "/reviewSubmissions?" in url:
                return 200, {
                    "data": [
                        {"id": "rejected-id", "attributes": {"state": "UNRESOLVED_ISSUES"}}
                    ]
                }
            self.fail(f"Unexpected request: {method} {url}")

        with tempfile.TemporaryDirectory() as directory:
            key = Path(directory) / "AuthKey_TEST.p8"
            key.write_text("test", encoding="utf-8")
            env = {
                "APP_STORE_CONNECT_API_KEY_ID": "TEST",
                "APP_STORE_CONNECT_API_ISSUER_ID": "issuer",
                "BUNDLE_ID": "com.asrax.aminvestment",
                "VERSION_CODE": "1411",
                "VERSION_NAME": "2.0.2",
            }
            with patch.dict(os.environ, env), patch.object(
                appstore, "p8_path_for_key", return_value=key
            ), patch.object(appstore, "mint_jwt", return_value="token"), patch.object(
                appstore, "api", side_effect=api
            ), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(appstore.main(), 1)

        self.assertEqual([method for method, _ in calls], ["GET"] * 3)

    def test_ready_submission_attaches_and_submits_build(self) -> None:
        calls = []

        def api(method, url, token, data=None):
            calls.append((method, url))
            if "/v1/apps?" in url:
                return 200, {"data": [{"id": "app-id"}]}
            if "/v1/builds?" in url:
                return 200, {
                    "data": [{"id": "build-id", "attributes": {"processingState": "VALID"}}]
                }
            if "/reviewSubmissions?" in url:
                return 200, {
                    "data": [{"id": "draft-id", "attributes": {"state": "READY_FOR_REVIEW"}}]
                }
            if "/appStoreVersions?" in url:
                return 200, {"data": [{"id": "version-id"}]}
            if method == "PATCH" and "/relationships/build" in url:
                return 204, {}
            if method == "POST" and "/reviewSubmissionItems" in url:
                return 201, {"data": {"id": "item-id"}}
            if method == "PATCH" and "/reviewSubmissions/draft-id" in url:
                return 200, {"data": {"attributes": {"state": "WAITING_FOR_REVIEW"}}}
            if method == "GET" and "/appStoreVersions/version-id" in url:
                return 200, {"data": {"attributes": {"appStoreState": "WAITING_FOR_REVIEW"}}}
            self.fail(f"Unexpected request: {method} {url}")

        with tempfile.TemporaryDirectory() as directory:
            key = Path(directory) / "AuthKey_TEST.p8"
            key.write_text("test", encoding="utf-8")
            env = {
                "APP_STORE_CONNECT_API_KEY_ID": "TEST",
                "APP_STORE_CONNECT_API_ISSUER_ID": "issuer",
                "BUNDLE_ID": "com.asrax.aminvestment",
                "VERSION_CODE": "1411",
                "VERSION_NAME": "2.0.2",
            }
            with patch.dict(os.environ, env), patch.object(
                appstore, "p8_path_for_key", return_value=key
            ), patch.object(appstore, "mint_jwt", return_value="token"), patch.object(
                appstore, "api", side_effect=api
            ), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(appstore.main(), 0)

        self.assertEqual(
            [method for method, _ in calls],
            ["GET", "GET", "GET", "GET", "PATCH", "POST", "PATCH", "GET"],
        )


if __name__ == "__main__":
    unittest.main()
