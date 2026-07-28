import json
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from app import build_server


class CommunityApiTests(unittest.TestCase):
    admin_token = "test-admin-token-that-is-longer-than-32-characters"

    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.server = build_server(
            "127.0.0.1",
            0,
            Path(cls.temp.name) / "test.sqlite3",
            cls.admin_token,
        )
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = f"http://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.temp.cleanup()

    def request(self, path, *, method="GET", payload=None, token=None):
        body = None if payload is None else json.dumps(payload).encode()
        headers = {}
        if body is not None:
            headers["Content-Type"] = "application/json"
        if token:
            headers["Authorization"] = f"Bearer {token}"
        request = urllib.request.Request(self.base + path, data=body, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as error:
            return error.code, json.load(error)

    def test_install_is_unique_and_events_increment(self):
        install_id = str(uuid.uuid4())
        for _ in range(2):
            status, body = self.request(
                "/api/v1/installations",
                method="POST",
                payload={"install_id": install_id, "version": "4.0.0"},
            )
            self.assertEqual(status, 200)
            self.assertTrue(body["ok"])
        self.assertGreaterEqual(body["stats"]["unique_installs"], 1)
        self.assertGreaterEqual(body["stats"]["install_events"], 2)

    def test_player_prefix_is_server_controlled(self):
        client_id = str(uuid.uuid4())
        status, body = self.request(
            "/api/v1/messages",
            method="POST",
            payload={"client_id": client_id, "nickname": "玩家·Test", "message": "<b>hello</b>"},
        )
        self.assertEqual(status, 201)
        status, listing = self.request("/api/v1/messages?limit=100")
        self.assertEqual(status, 200)
        item = next(entry for entry in listing["messages"] if entry["id"] == body["id"])
        self.assertEqual(item["display_name"], "玩家·Test")
        self.assertEqual(item["message"], "<b>hello</b>")

    def test_admin_requires_token_and_uses_admin_role(self):
        status, _ = self.request("/api/v1/admin/overview")
        self.assertEqual(status, 401)
        status, posted = self.request(
            "/api/v1/admin/messages",
            method="POST",
            payload={"message": "Maintenance notice"},
            token=self.admin_token,
        )
        self.assertEqual(status, 201)
        status, listing = self.request("/api/v1/messages")
        item = next(entry for entry in listing["messages"] if entry["id"] == posted["id"])
        self.assertEqual(item["display_name"], "管理员")
        self.assertEqual(item["role"], "admin")

    def test_board_can_be_closed_without_blocking_admin_posts(self):
        status, body = self.request(
            "/api/v1/admin/settings",
            method="POST",
            payload={"board_open": False},
            token=self.admin_token,
        )
        self.assertEqual(status, 200)
        self.assertFalse(body["board_open"])
        try:
            status, listing = self.request("/api/v1/messages")
            self.assertEqual(status, 200)
            self.assertFalse(listing["board_open"])

            status, error = self.request(
                "/api/v1/messages",
                method="POST",
                payload={
                    "client_id": str(uuid.uuid4()),
                    "nickname": "Closed",
                    "message": "blocked",
                },
            )
            self.assertEqual(status, 423)
            self.assertEqual(error["error"], "board_closed")

            status, _ = self.request(
                "/api/v1/admin/messages",
                method="POST",
                payload={"message": "Board is temporarily closed"},
                token=self.admin_token,
            )
            self.assertEqual(status, 201)
        finally:
            status, body = self.request(
                "/api/v1/admin/settings",
                method="POST",
                payload={"board_open": True},
                token=self.admin_token,
            )
            self.assertEqual(status, 200)
            self.assertTrue(body["board_open"])

    def test_clear_all_messages_requires_admin(self):
        status, _ = self.request("/api/v1/admin/messages", method="DELETE")
        self.assertEqual(status, 401)
        status, body = self.request(
            "/api/v1/admin/messages",
            method="DELETE",
            token=self.admin_token,
        )
        self.assertEqual(status, 200)
        self.assertGreaterEqual(body["deleted"], 1)
        status, listing = self.request("/api/v1/messages")
        self.assertEqual(status, 200)
        self.assertEqual(listing["messages"], [])

    def test_rate_limit(self):
        client_id = str(uuid.uuid4())
        statuses = []
        for index in range(4):
            status, _ = self.request(
                "/api/v1/messages",
                method="POST",
                payload={"client_id": client_id, "nickname": "Rate", "message": f"message {index}"},
            )
            statuses.append(status)
        self.assertEqual(statuses, [201, 201, 201, 429])

    def test_reply_metadata_round_trips(self):
        client_id = str(uuid.uuid4())
        status, parent = self.request(
            "/api/v1/messages",
            method="POST",
            payload={"client_id": client_id, "nickname": "Parent", "message": "Original"},
        )
        self.assertEqual(status, 201)
        status, child = self.request(
            "/api/v1/messages",
            method="POST",
            payload={
                "client_id": client_id,
                "nickname": "Reply",
                "message": "Answer",
                "reply_to_id": parent["id"],
            },
        )
        self.assertEqual(status, 201)

        status, listing = self.request("/api/v1/messages")
        self.assertEqual(status, 200)
        item = next(entry for entry in listing["messages"] if entry["id"] == child["id"])
        self.assertEqual(item["reply_to_id"], parent["id"])
        self.assertEqual(item["reply_to_display_name"], "玩家·Parent")
        self.assertEqual(item["reply_to_message"], "Original")

        status, error = self.request(
            "/api/v1/messages",
            method="POST",
            payload={
                "client_id": str(uuid.uuid4()),
                "nickname": "Missing",
                "message": "No target",
                "reply_to_id": 999999,
            },
        )
        self.assertEqual(status, 400)
        self.assertEqual(error["error"], "invalid_input")


if __name__ == "__main__":
    unittest.main()
