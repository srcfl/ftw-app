import json
from pathlib import Path
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ios_release_discord as d  # noqa: E402

NOTES = """New in 0.6.9: when a device does not do what FTW asked, the status line says so in red.

New in 0.6.8: the plan's clock shows the twelve hours from now again.
"""
XCCONFIG = "APP_GROUP = group.energy.ftw.app\nMARKETING_VERSION = 0.6.9\n"


class Payload(unittest.TestCase):
    def test_the_versions_own_paragraph_is_the_message(self):
        m = d.payload("0.6.9", "20261105.1530", NOTES, XCCONFIG)
        embed = m["embeds"][0]
        self.assertEqual(embed["title"], "FTW for iPhone 0.6.9")
        self.assertTrue(embed["description"].startswith("When a device does not do what FTW asked"))
        self.assertNotIn("0.6.8", embed["description"])
        self.assertIn(d.JOIN, embed["description"])
        self.assertEqual(embed["footer"]["text"], "iPhone beta · build 20261105.1530")
        self.assertEqual(m["allowed_mentions"], {"parse": []})

    def test_the_whole_repository_agrees_with_itself(self):
        app = Path(__file__).resolve().parents[2] / "appleApp"
        xcconfig = (app / "FTW.xcconfig").read_text(encoding="utf-8")
        version = next(line.split("=")[1].strip() for line in xcconfig.splitlines() if line.startswith("MARKETING_VERSION"))
        notes = (app / "store/en-US/release-notes.txt").read_text(encoding="utf-8")
        d.payload(version, "20261105.1530", notes, xcconfig)

    def test_refuses_what_it_cannot_stand_behind(self):
        for version, build, notes, xcconfig in [
            ("0.7.0", "20261105.1530", NOTES, XCCONFIG),  # not the xcconfig's
            ("0.6.9", "16", NOTES, XCCONFIG),  # not the release script's build
            ("1.0", "20261105.1530", NOTES, XCCONFIG),
            ("0.6.9", "20261105.1530", "New in 0.6.8: older.\n", XCCONFIG),  # no paragraph
        ]:
            with self.assertRaises(ValueError):
                d.payload(version, build, notes, xcconfig)


class Send(unittest.TestCase):
    def test_only_a_discord_webhook(self):
        for hook in ["", "http://discord.com/api/webhooks/1/x", "https://example.com/api/webhooks/1/x",
                     "https://discord.com/api/webhooks/1/x y"]:
            with self.assertRaises(ValueError):
                d.send({}, hook)

    def test_waits_for_discord_to_save_it(self):
        class Answer:
            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

            def read(self):
                return json.dumps({"id": "42"}).encode()

        with mock.patch.object(d, "urlopen", return_value=Answer()) as opened:
            self.assertEqual(d.send({"x": 1}, "https://discord.com/api/webhooks/1/abc"), "42")
        self.assertIn("wait=true", opened.call_args[0][0].full_url)


if __name__ == "__main__":
    unittest.main()
