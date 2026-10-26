#!/usr/bin/env python3
import html
import json
import re
import sys
import urllib.request
from urllib.parse import urlparse, urlunparse
from datetime import datetime, timedelta

try:
    from zoneinfo import ZoneInfo
except ImportError:
    ZoneInfo = None


ITEM_PATTERN = re.compile(r'<div id="itemheader[^"]*"class="list-group-item"[^>]*>')
ATTR_PATTERN = re.compile(r'(data-[a-zA-Z0-9]+)="([^"]*)"')
DATE_SEGMENT_PATTERN = re.compile(r"/\d{4}-\d{2}-\d{2}$")


def load_request():
    raw = sys.stdin.read()
    if not raw.strip():
        return {}
    return json.loads(raw)


def fetch_html(url):
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": "lanTV/1.0",
            "Accept": "text/html,*/*",
        },
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        return response.read().decode("utf-8", errors="replace")


def resolve_schedule_url(station_url, time_zone_name):
    time_zone = ZoneInfo(time_zone_name) if ZoneInfo else None
    schedule_date = datetime.now(time_zone).date() if time_zone else datetime.now().date()
    parsed = urlparse(station_url)
    path = parsed.path.rstrip("/")

    if DATE_SEGMENT_PATTERN.search(path):
        path = DATE_SEGMENT_PATTERN.sub(f"/{schedule_date.isoformat()}", path)
    else:
        path = f"{path}/{schedule_date.isoformat()}"

    return urlunparse(parsed._replace(path=path))


def parse_programmes(html_text, time_zone_name):
    time_zone = ZoneInfo(time_zone_name) if ZoneInfo else None
    programmes = []

    for tag in ITEM_PATTERN.findall(html_text):
        attributes = dict(ATTR_PATTERN.findall(tag))
        start_value = attributes.get("data-st")
        duration_value = attributes.get("data-duration")
        title_value = attributes.get("data-showName")
        if not start_value or not duration_value or not title_value:
            continue

        try:
            duration_minutes = float(duration_value)
        except ValueError:
            continue
        if duration_minutes <= 0:
            continue

        try:
            start = datetime.strptime(start_value, "%Y-%m-%d %H:%M:%S")
            if time_zone is not None:
                start = start.replace(tzinfo=time_zone)
        except ValueError:
            continue

        stop = start + timedelta(minutes=duration_minutes)
        episode_title = html.unescape(attributes.get("data-episodeTitle", "")).strip()
        title = html.unescape(title_value).strip()
        if episode_title:
            title = f"{title}: {episode_title}"

        detail = html.unescape(attributes.get("data-description", "")).strip()
        programmes.append(
            {
                "start": start.isoformat(),
                "stop": stop.isoformat(),
                "title": title,
                "detail": detail or None,
                "iconURL": None,
            }
        )

    return programmes


def main():
    request = load_request()
    arguments = request.get("arguments", {})
    station_url = arguments.get("station_url")
    time_zone = arguments.get("time_zone") or request.get("timeZoneIdentifier") or "UTC"

    if not station_url:
        raise SystemExit("Missing required argument: station_url")

    html_text = fetch_html(resolve_schedule_url(station_url, time_zone))
    programmes = parse_programmes(html_text, time_zone)
    print(json.dumps({"programmes": programmes}))


if __name__ == "__main__":
    main()
