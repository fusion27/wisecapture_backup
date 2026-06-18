# wisebackup.sh

Nightly backup script for Newcombe (`10.0.0.69`). Runs four jobs every night at midnight via cron.

## What it does

| Job | Source | Destination | Method |
|-----|--------|-------------|--------|
| PersonalMirror | `/media/casey/wcstore2` (spinner 4.5TB) | `/media/casey/Newcombe01` (spinner 4.5TB) | rsync mirror |
| WCPhotoMirror | `/media/casey/WC Storage 1` (IronWolf 8TB) | `/media/casey/WC Storage 2` (IronWolf 8TB) | rsync mirror |
| WCPhotoS3 | `/media/casey/WC Storage 1` | `s3://wisecapture-archive` | aws s3 sync (Glacier Deep Archive) |
| FamilyS3 | `/media/casey/wcstore2/Backup` | `s3://wisefamily-archive` | aws s3 sync (Glacier Deep Archive) |

After all four jobs succeed, it emits a `WiseBackup/BackupSuccess` CloudWatch metric. On Sundays it also sends a weekly SNS check-in email.

Any failure triggers an SNS alert via the `newcombe-storage-alerts` topic (see `../cdk/`).

## Drive inventory

| Mount | UUID | Type | Role |
|-------|------|------|------|
| `/media/casey/wcstore2` | `f923f153-e624-487a-9f54-baec24cec4ab` | Spinner 4.5TB | Personal archive source |
| `/media/casey/Newcombe01` | `21f4e317-6f64-4bb8-85fc-c37573280654` | Spinner 4.5TB | Personal archive mirror |
| `/media/casey/WC Storage 1` | `5c719d20-7fd5-4e30-a20a-479b698109e8` | IronWolf 8TB | WiseCapture primary |
| `/media/casey/WC Storage 2` | `9da343f0-3965-49eb-b8a4-8ae166a004bd` | IronWolf 8TB | WiseCapture mirror |

Both IronWolf drives require a `.mirror_sentinel` file at their root — the script verifies this as a safety guard before running any rsync or S3 sync.

## Prerequisites

- All four drives mounted at the paths above (see `/etc/fstab` on Newcombe for UUID-based entries)
- AWS credentials configured on Newcombe with permission to publish to SNS and put CloudWatch metrics (the `newcombe` IAM user — `AmazonS3FullAccess` + `BackupPolicy` inline)
- `rsync`, `aws` CLI, `findmnt` available on PATH

## Installation

```bash
# Copy to Newcombe
scp backup/wisebackup.sh casey@newcombe:/home/casey/wisebackup.sh
chmod +x /home/casey/wisebackup.sh

# Enable nightly cron (run on Newcombe)
crontab -e
# Add: 0 0 * * * /usr/bin/env bash /home/casey/wisebackup.sh >>/home/casey/wisebackup.cron.log 2>&1
```

## Logs

| File | Contents |
|------|----------|
| `/home/casey/automater.log` | Per-job completion lines (timestamps, file/byte counts) |
| `/home/casey/wisebackup.cron.log` | Full stdout+stderr from cron (rsync output, aws errors, etc.) |
| `~/.local/share/wisebackup/*.last_run` | Per-job epoch timestamps for S3 change estimation |

## AWS resources

| Resource | Value |
|----------|-------|
| SNS Topic | `arn:aws:sns:us-east-1:690063008832:newcombe-storage-alerts` |
| S3 buckets | `wisecapture-archive`, `wisefamily-archive` |
| CloudWatch namespace | `WiseBackup` |
| CW Alarm | `newcombe-wisebackup-missing` (fires if no BackupSuccess in 26h) |

The CDK stack that provisions the SNS topic and CloudWatch alarm lives in `../cdk/`.

## End-to-end test

```bash
bash -x /home/casey/wisebackup.sh 2>&1 | tee /home/casey/wisebackup-test-$(date +%Y%m%d).log
```
