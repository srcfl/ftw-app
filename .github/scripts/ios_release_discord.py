"""Announce a new FTW for iPhone build on Discord, as Core's betas are.

The words are the release notes' own paragraph for the version, from
appleApp/store/en-US/release-notes.txt at the commit the build came from, so
Discord says what TestFlight's What to Test says. The webhook is the
repository's secret; this never prints it.
"""

import argparse
import json
import os
from pathlib import Path
import re
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit
from urllib.request import Request, urlopen

# FTW's public beta, the TestFlight group Pilot (.github/workflows/ios-pilot.yml).
JOIN = "https://testflight.apple.com/join/E4Japad7"


def paragraph(notes, version):
    """The release notes' paragraph for this version, without its lead-in."""
    lead = f"New in {version}:"
    for block in re.split(r"\n\s*\n", notes):
        block = " ".join(block.split())
        if block.startswith(lead):
            text = block[len(lead):].strip()
            if text:
                return text[0].upper() + text[1:]
    raise ValueError(f"The release notes have no paragraph for {version}")


def payload(version, build, notes, xcconfig):
    if not re.fullmatch(r"0\.\d+\.\d+", version):
        raise ValueError("The version must be 0.X.Y")
    if not re.fullmatch(r"\d{8}\.\d{1,4}", build):
        raise ValueError("The build must be the release script's YYYYMMDD.HHMM")
    marketing = re.search(r"^MARKETING_VERSION\s*=\s*(\S+)\s*$", xcconfig, re.M)
    if not marketing or marketing[1] != version:
        raise ValueError("FTW.xcconfig does not name this version")
    body = paragraph(notes, version)
    # Discord's embed limit, counted in UTF-16 units as Core's announcement does.
    if len(body.encode("utf-16-le")) > 3500 * 2:
        body = body.encode("utf-16-le")[:3500 * 2].decode("utf-16-le", errors="ignore").rstrip() + "…"
    return {
        "username": "FTW",
        "allowed_mentions": {"parse": []},
        "embeds": [{
            "title": f"FTW for iPhone {version}",
            "url": JOIN,
            "description": body + f"\n\nIt reaches TestFlight once Apple has reviewed the build. [Join the beta]({JOIN})",
            "color": 16753920,
            "footer": {"text": f"iPhone beta · build {build}"},
        }],
    }


def send(message, webhook):
    if not webhook:
        raise ValueError("DISCORD_WEBHOOK is not set")
    parts = urlsplit(webhook)
    if (parts.scheme != "https" or parts.hostname not in ("discord.com", "discordapp.com")
            or any(c.isspace() for c in webhook)
            or not re.fullmatch(r"/api/(?:v\d+/)?webhooks/\d+/[A-Za-z0-9_.-]+", parts.path)):
        raise ValueError("DISCORD_WEBHOOK must be a Discord webhook URL")
    query = dict(parse_qsl(parts.query))
    query["wait"] = "true"
    url = urlunsplit(parts._replace(query=urlencode(query)))
    request = Request(url, data=json.dumps(message).encode(), method="POST",
                      headers={"Content-Type": "application/json", "User-Agent": "FTW-ios-release"})
    try:
        with urlopen(request, timeout=30) as response:
            result = json.load(response)
    except HTTPError as error:
        raise ValueError(f"Discord rejected the announcement (HTTP {error.code})") from None
    except (URLError, TimeoutError):
        raise ValueError("Could not confirm delivery to Discord") from None
    if not result.get("id"):
        raise ValueError("Discord did not confirm a saved message")
    return result["id"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version")
    parser.add_argument("build")
    parser.add_argument("--app", type=Path, default=Path("appleApp"))
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    try:
        notes = (args.app / "store/en-US/release-notes.txt").read_text(encoding="utf-8")
        xcconfig = (args.app / "FTW.xcconfig").read_text(encoding="utf-8")
        message = payload(args.version, args.build, notes, xcconfig)
        if args.dry_run:
            print(json.dumps(message, ensure_ascii=False, indent=2))
        else:
            message_id = send(message, os.environ.get("DISCORD_WEBHOOK"))
            print(f"Discord saved the announcement {message_id}")
    except (ValueError, OSError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
