# Serverless Data Lake — Design Brief

## Goal

A small, specific-scope AWS project: a working data lake built from serverless parts only, demonstrating the feed → S3 → catalogue → query pattern end to end. Portfolio piece, not production.

## Non-goals

- No streaming (no Kinesis) — the feed is pulled on a schedule, not pushed.
- No transformation step yet — raw files land as-is; a curated zone is a later phase, not this one.
- No Connect tie-in — this stands alone, separate from Projects #2 and #3.

## Data flow

1. **EventBridge** fires once an hour (rate expression, `rate(1 hour)`).
2. **Lambda** (`lambda/fetch_feed.py`, Python 3.12, standard library + boto3) fetches the USGS all-day earthquake feed (GeoJSON, no API key) and writes one file per run to S3.
3. **S3 raw zone** stores files partitioned by ingestion date:
   `s3://<bucket>/raw/earthquakes/year=YYYY/month=MM/day=DD/feed-HHMMSS.json`
4. **Glue crawler** runs on the raw prefix, infers the schema, and registers the table in the **Glue Data Catalog**.
5. **Athena** queries the table with plain SQL, e.g. biggest quakes by day, quakes above magnitude 5, counts by region.

## The feed

USGS Earthquake Hazards Program, all-day summary feed. Free, no key, updated every minute. Each file holds every quake in the last 24 hours with time, place, magnitude, depth and coordinates. The pipeline treats the feed as opaque JSON — swapping `FEED_URL` swaps the dataset.

## Gate 0 — the decisive test

Before anything is called done, two things must be true:
1. A scheduled Lambda run lands a partitioned file in S3 (checked by listing the prefix).
2. Athena returns rows from the Glue table (a `SELECT count(*)` plus one real question, e.g. the largest magnitude in the last day).

If either fails, the build stops at the gate — no silent substitution, no "close enough".

## Resources (Terraform, `terraform/main.tf`)

S3 bucket (public access blocked) · IAM role + policy for the Lambda (logs, S3 PutObject on the raw prefix) · Lambda function from the `lambda/` zip · EventBridge hourly rule + target + invoke permission · Glue catalog database + crawler · Athena workgroup. Region: us-east-1.

## Cost

Idle: effectively $0 — S3 storage at this volume is a few cents a month; Lambda, Glue crawler and Athena are all pay-per-use. Exact idle and per-use figures are confirmed with Steven before the apply.

## Implementation plan (later this week)

1. Review this brief and the Terraform plan together; confirm project name, region and costs.
2. `terraform apply` from CloudShell; roll call of live resources by name.
3. Trigger one manual run; verify the file lands partitioned in S3.
4. Run the crawler; verify the table; ask Athena the first question.
5. Record the Gate 0 result here and in the README.
