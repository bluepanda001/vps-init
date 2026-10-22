#!/usr/bin/env python3
import importlib.util
import json
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("vpsinit_xui_api", ROOT / "modules/3x-ui/xui_api.py")
api = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(api)


def sample_payload(strategy="AsIs"):
    return {
        "xraySetting": {
            "log": {"loglevel": "warning"},
            "outbounds": [
                {"tag": "direct", "protocol": "freedom", "settings": {"domainStrategy": strategy}},
                {"tag": "block", "protocol": "blackhole", "settings": {}},
            ],
            "routing": {"rules": []},
        },
        "outboundTestUrl": "https://example.org/generate_204",
        "inboundTags": [],
    }


class FreedomStrategyTests(unittest.TestCase):
    def test_sets_ipv4v6_and_preserves_unrelated_template(self):
        state = {"payload": sample_payload()}
        saved_fields = []

        def fake_get_obj(base, token, method, path, body=None):
            self.assertEqual(method, "POST")
            self.assertEqual(path, "panel/api/xray/")
            return json.dumps(state["payload"])

        def fake_req_form(base, token, path, fields):
            self.assertEqual(path, "panel/api/xray/update")
            saved_fields.append(fields)
            state["payload"]["xraySetting"] = json.loads(fields["xraySetting"])
            return {"success": True}

        with patch.object(api, "get_obj", side_effect=fake_get_obj), patch.object(api, "req_form", side_effect=fake_req_form):
            result = api.set_freedom_strategy("http://127.0.0.1:2053/zhg/", "test-token")

        self.assertTrue(result["changed"])
        self.assertEqual(result["strategy"], "UseIPv4v6")
        self.assertEqual(len(saved_fields), 1)
        self.assertEqual(saved_fields[0]["outboundTestUrl"], "https://example.org/generate_204")
        template = state["payload"]["xraySetting"]
        direct = template["outbounds"][0]
        self.assertEqual(direct["settings"]["domainStrategy"], "UseIPv4v6")
        self.assertEqual(direct["streamSettings"]["sockopt"]["domainStrategy"], "UseIPv4v6")
        self.assertEqual(template["outbounds"][1], {"tag": "block", "protocol": "blackhole", "settings": {}})
        self.assertEqual(template["routing"], {"rules": []})

    def test_is_idempotent(self):
        state = {"payload": sample_payload("UseIPv4v6")}
        state["payload"]["xraySetting"]["outbounds"][0]["streamSettings"] = {
            "sockopt": {"domainStrategy": "UseIPv4v6"}
        }

        with patch.object(api, "get_obj", side_effect=lambda *args, **kwargs: json.dumps(state["payload"])), patch.object(api, "req_form") as save:
            result = api.set_freedom_strategy("http://127.0.0.1:2053/zhg/", "test-token")

        self.assertFalse(result["changed"])
        save.assert_not_called()

    def test_refuses_template_without_freedom_outbound(self):
        payload = {"xraySetting": {"outbounds": [{"tag": "block", "protocol": "blackhole"}]}}
        with patch.object(api, "get_obj", return_value=json.dumps(payload)):
            with self.assertRaisesRegex(RuntimeError, "no freedom outbound"):
                api.set_freedom_strategy("http://127.0.0.1:2053/zhg/", "test-token")


if __name__ == "__main__":
    unittest.main()
