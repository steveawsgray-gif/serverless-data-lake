"""Fetch the USGS all-day earthquake feed and land it in S3, partitioned by UTC date.

Runs on a schedule (EventBridge, hourly). Standard library only, plus boto3
for the S3 put. No API key needed for the USGS feed.
"""

import json
import os
import urllib.request
from datetime import datetime, timezone

FEED_URL = os.environ.get(
    "FEED_URL",
    "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/all_day.geojson",
)
BUCKET_NAME = os.environ["BUCKET_NAME"]


def fetch_feed(url: str) -> dict:
    req = urllib.request.Request(url, headers={"User-Agent": "serverless-data-lake/1.0"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def main() -> dict:
    import boto3

    data = fetch_feed(FEED_URL)
    now = datetime.now(timezone.utc)
    key = (
        f"raw/earthquakes/year={now:%Y}/month={now:%m}/day={now:%d}/"
        f"feed-{now:%H%M%S}.json"
    )
    boto3.client("s3").put_object(
        Bucket=BUCKET_NAME,
        Key=key,
        Body=json.dumps(data).encode("utf-8"),
        ContentType="application/json",
    )
    return {"landed": key, "earthquakes": len(data.get("features", []))}


def handler(event, context):  # AWS Lambda entry point
    return main()


if __name__ == "__main__":
    print(main())
