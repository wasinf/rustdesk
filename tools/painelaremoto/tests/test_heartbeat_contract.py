"""Tests to be copied into PainelAremoto repo.

Expected target imports after copying:
- from app.heartbeat_contract import HeartbeatIn, compute_status, validate_api_key
"""

import unittest


class HeartbeatContractTests(unittest.TestCase):
    def test_new_payload_with_version_and_timestamp(self):
        from tools.painelaremoto.heartbeat_reference import HeartbeatIn

        hb = HeartbeatIn(client_id="123", version="1.4.6", timestamp=1732666405)
        self.assertEqual(hb.version, "1.4.6")
        self.assertEqual(hb.timestamp, 1732666405)

    def test_legacy_payload_with_client_version_only(self):
        from tools.painelaremoto.heartbeat_reference import HeartbeatIn

        hb = HeartbeatIn(client_id="123", client_version="1.4.5")
        self.assertEqual(hb.version, "1.4.5")
        self.assertIsNotNone(hb.timestamp)

    def test_missing_api_key_is_rejected(self):
        from tools.painelaremoto.heartbeat_reference import validate_api_key

        with self.assertRaises(Exception):
            validate_api_key(None)

    def test_invalid_api_key_is_rejected(self):
        from tools.painelaremoto.heartbeat_reference import validate_api_key

        with self.assertRaises(Exception):
            validate_api_key("invalid")


if __name__ == "__main__":
    unittest.main()
