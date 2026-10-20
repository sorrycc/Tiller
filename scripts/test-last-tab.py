#!/usr/bin/env python3
"""Exercise last-tab lifecycle against a real, isolated macOS app.

Build with TILLER_BUNDLE_ID=dev.sorrycc.tiller.last-tab-test and a separate
TILLER_OUT, then run: python3 scripts/test-last-tab.py /path/to/Tiller.app
Uses only Python's standard library; never connects to the everyday profile.
"""

import json
import os
from pathlib import Path
import plistlib
import socket
import subprocess
import sys
import tempfile
import time
import unittest


APP = Path(sys.argv.pop(1)).resolve()
with (APP / "Contents/Info.plist").open("rb") as source:
    BUNDLE_ID = plistlib.load(source)["CFBundleIdentifier"]
if not BUNDLE_ID.endswith(".last-tab-test"):
    raise SystemExit("Use a test bundle whose identifier ends in .last-tab-test")


class LastTabTests(unittest.TestCase):
    def setUp(self):
        # Keep Unix socket paths below macOS's length limit.
        self.directory = tempfile.TemporaryDirectory(prefix="tlt-", dir="/tmp")
        self.root = Path(self.directory.name).resolve()
        self.log = (self.root / "app.log").open("w+")
        self.process = None
        self.one = (self.root / "one.html").as_uri()
        self.two = (self.root / "two.html").as_uri()
        for name in ("one", "two", "home"):
            (self.root / f"{name}.html").write_text(
                f"<!doctype html><title>{name}</title><h1>{name}</h1>"
            )
        self.home = (self.root / "home.html").as_uri()

    def tearDown(self):
        if self.process is not None and self.process.poll() is None:
            try:
                self.call("app.quit")
                self.process.wait(timeout=10)
            finally:
                if self.process.poll() is None:
                    self.process.terminate()
                    self.process.wait(timeout=10)
        self.log.close()
        self.directory.cleanup()

    def start(self, new_tab="blank", restore=False, rail=False):
        args = [
            str(APP / "Contents/MacOS/Tiller"),
            "-askedDefaultBrowser", "YES",
            "-homepage", self.home,
            "-newTabPage", new_tab,
            "-launchTabs", "restore",
            "-profileTabs", "YES" if rail else "NO",
        ]
        if not restore:
            args += ["-url", self.one]
        self.process = subprocess.Popen(
            args, stdout=self.log, stderr=self.log,
            env={**os.environ, "TILLER_DATA_DIR": str(self.root),
                 "TILLER_PROFILE": "default",
                 "TILLER_SOCKET": str(self.root / "control.sock")},
        )
        self.wait(lambda: self.call("tabs.list"), "control socket to start")

    def call(self, method, params=None, profile=None):
        path = (self.root / "Profiles" / profile / "control.sock"
                if profile else self.root / "control.sock")
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(5)
            connection.connect(str(path))
            connection.sendall((json.dumps({
                "id": 1, "method": method, "params": params or {},
            }) + "\n").encode())
            response = json.loads(connection.makefile("rb").readline())
        if "error" in response:
            raise AssertionError(response["error"])
        return response["result"]

    def wait(self, condition, description):
        deadline = time.monotonic() + 15
        last = None
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                self.log.seek(0)
                self.fail(f"App exited ({self.process.returncode}): {self.log.read()[-4000:]}")
            try:
                last = condition()
                if last:
                    return last
            except (OSError, ValueError) as error:
                last = error
            time.sleep(0.1)
        self.fail(f"Timed out waiting for {description}: {last}")

    def tabs(self, profile=None):
        return self.call("tabs.list", profile=profile)["tabs"]

    def close(self, tab, profile=None):
        self.call("tabs.close", {"tab_id": tab["id"]}, profile)
        self.wait(lambda: all(t["id"] != tab["id"] for t in self.tabs(profile)),
                  "the old tab to close")
        # Let CEF finish its asynchronous close, then query the app again.
        time.sleep(0.3)
        return self.tabs(profile)

    def test_last_tab_replaced_saved_and_reopenable(self):
        self.start()
        original = self.tabs()[0]
        replacement, = self.close(original)
        self.assertEqual(replacement["url"], "about:blank")
        self.assertTrue(replacement["selected"])
        self.assertEqual(self.call("tabs.closed")["tabs"][0]["url"], self.one)
        session = self.root / "Profiles/default/session.json"
        self.wait(lambda: session.exists() and
                  [t["url"] for t in json.loads(session.read_text())["tabs"]] == ["about:blank"],
                  "replacement to be saved")
        reopened = self.call("tabs.reopen")
        self.assertEqual(reopened["url"], self.one)
        self.assertEqual([t["url"] for t in self.tabs()], [self.one, "about:blank"])

    def test_repeated_blank_close_keeps_one_tab(self):
        self.start()
        self.close(self.tabs()[0])
        for _ in range(10):
            tab, = self.close(self.tabs()[0])
            self.assertEqual(tab["url"], "about:blank")
        self.assertEqual(len(self.call("tabs.closed")["tabs"]), 1)

    def test_homepage_setting_and_ordinary_close(self):
        self.start(new_tab="homepage")
        original = self.tabs()[0]
        added = self.call("tabs.new", {"url": self.two})
        remaining, = self.close(added)
        self.assertEqual(remaining["id"], original["id"])
        replacement, = self.close(remaining)
        self.assertEqual(replacement["url"], self.home)
        self.assertTrue(replacement["selected"])

    def test_closing_all_tabs_individually_keeps_one_replacement(self):
        self.start()
        self.call("tabs.new", {"url": self.two})
        self.call("tabs.new", {"url": self.home})
        old_ids = {tab["id"] for tab in self.tabs()}
        for tab_id in old_ids:
            self.call("tabs.close", {"tab_id": tab_id})
        self.wait(lambda: not old_ids.intersection(t["id"] for t in self.tabs()),
                  "all requested tabs to close")
        time.sleep(2.2)
        replacement, = self.tabs()
        self.assertEqual(replacement["url"], "about:blank")
        self.assertEqual(len(self.call("tabs.closed")["tabs"]), 3)

    def test_hidden_profile_kept_and_explicit_profile_close(self):
        self.start(rail=True)
        self.assertTrue(self.call("app.status")["profile_tabs"])
        created = self.call("app.profile.new", {"name": "Other", "show": True})
        other = created["id"]
        self.wait(lambda: self.tabs(other), "second profile")
        self.wait(lambda: self.call("app.status")["last_used"] == other,
                  "second profile to come forward")
        self.close(self.tabs()[0])  # The default profile is behind Other.
        status = self.call("app.status")
        self.assertEqual(status["last_used"], other)
        self.assertTrue(all(p["open"] for p in status["profiles"]))
        self.assertEqual(len(self.tabs(other)), 1)
        self.call("app.profile.close", {"profile": other})
        self.wait(lambda: not next(p for p in self.call("app.profiles")["profiles"]
                                   if p["id"] == other)["open"], "explicit profile close")
        self.assertEqual(len(self.tabs()), 1)
        self.call("app.profile.close", {"profile": "default"})
        self.assertEqual(self.process.wait(timeout=15), 0)

    def test_quit_restores_tabs_and_closes_lazy_tab(self):
        self.start()
        self.call("tabs.new", {"url": self.two})
        self.call("app.quit")
        self.assertEqual(self.process.wait(timeout=15), 0)
        self.start(restore=True)
        tabs = self.tabs()
        self.assertEqual([t["url"] for t in tabs], [self.one, self.two])
        self.assertFalse(tabs[0]["loaded"])
        self.assertEqual(self.call("tabs.closed")["tabs"], [])
        self.close(tabs[0])
        replacement, = self.close(tabs[1])
        self.assertEqual(replacement["url"], "about:blank")
        self.assertEqual([t["url"] for t in self.call("tabs.closed")["tabs"]],
                         [self.two, self.one])


if __name__ == "__main__":
    unittest.main(verbosity=2)
