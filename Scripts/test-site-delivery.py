#!/usr/bin/env python3
"""Check the public HTTP contract against a running Wrangler Pages preview."""

import sys
import unittest
import urllib.error
import urllib.request
import urllib.robotparser
import xml.etree.ElementTree as ET
from pathlib import Path


SITE = Path(__file__).resolve().parents[1] / "site"
BASE_URL = sys.argv.pop(1).rstrip("/") if len(sys.argv) > 1 else "http://127.0.0.1:8788"


def fetch(path):
    try:
        response = urllib.request.urlopen(BASE_URL + path, timeout=15)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        return response.status, response.headers, response.read(), response.url


class SiteDeliveryTests(unittest.TestCase):
    def test_robots_and_sitemap(self):
        status, headers, body, _ = fetch("/robots.txt")
        self.assertEqual(status, 200)
        self.assertEqual(headers.get_content_type(), "text/plain")
        robots = urllib.robotparser.RobotFileParser()
        robots.parse(body.decode().splitlines())
        self.assertTrue(robots.can_fetch("Googlebot", "https://justnow.tk.sg/privacy"))
        self.assertEqual(robots.site_maps(), ["https://justnow.tk.sg/sitemap.xml"])

        status, headers, body, _ = fetch("/sitemap.xml")
        self.assertEqual(status, 200)
        self.assertEqual(headers.get_content_type(), "application/xml")
        root = ET.fromstring(body)
        namespace = "{http://www.sitemaps.org/schemas/sitemap/0.9}"
        self.assertEqual(root.tag, namespace + "urlset")
        urls = [loc.text for loc in root.findall(f"{namespace}url/{namespace}loc")]
        self.assertCountEqual(urls, [
            "https://justnow.tk.sg/",
            "https://justnow.tk.sg/privacy",
            "https://justnow.tk.sg/releases/",
        ])
        for url in urls:
            with self.subTest(url=url):
                status, headers, _, final_url = fetch(url.removeprefix("https://justnow.tk.sg"))
                self.assertEqual(status, 200)
                self.assertEqual(headers.get_content_type(), "text/html")
                self.assertEqual(final_url, BASE_URL + url.removeprefix("https://justnow.tk.sg"))

    def test_unknown_paths_are_not_homepage(self):
        for path in ("/crawl-check-missing-20261029", "/releases/missing", "/assets/missing.png",
                     "/sitemap-index.xml", "/missing/deep/path/"):
            with self.subTest(path=path):
                status, headers, body, _ = fetch(path)
                self.assertEqual(status, 404)
                self.assertEqual(headers.get_content_type(), "text/html")
                self.assertIn(b"Page not found", body)
                self.assertNotIn(b'rel="canonical"', body)

    def test_existing_pages_and_update_assets_are_unchanged(self):
        for file in sorted(SITE.rglob("*")):
            if not file.is_file() or file.name.startswith((".", "_")) or file.name == "404.html":
                continue
            path = "/" + file.relative_to(SITE).as_posix()
            with self.subTest(path=path):
                status, _, body, _ = fetch(path)
                self.assertEqual(status, 200)
                self.assertEqual(body, file.read_bytes())
        for path, target in (("/privacy", "privacy.html"), ("/privacy/", "privacy.html"),
                             ("/releases", "releases/index.html"), ("/releases/", "releases/index.html")):
            with self.subTest(path=path):
                status, _, body, _ = fetch(path)
                self.assertEqual(status, 200)
                self.assertEqual(body, (SITE / target).read_bytes())
        status, headers, _, _ = fetch("/appcast.xml")
        self.assertEqual(status, 200)
        self.assertEqual(headers.get_content_type(), "application/xml")
        self.assertEqual(headers["Cache-Control"], "public, max-age=300, must-revalidate")


if __name__ == "__main__":
    unittest.main()
