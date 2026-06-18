# wisecapture_backup

Backup infrastructure for Newcombe's WiseCapture photo archive and personal storage.

## Contents

| Directory | What's in it |
|-----------|-------------|
| [`backup/`](backup/) | `wisebackup.sh` — the nightly backup script and its docs |
| [`cdk/`](cdk/) | CDK stack that provisions SNS alerting and CloudWatch alarm on AWS |

## How they fit together

`wisebackup.sh` runs nightly on Newcombe via cron. It mirrors drives locally and syncs to S3, then emits a `WiseBackup/BackupSuccess` CloudWatch metric. The CDK stack (`newcombe-storage-alerts`) provisions a CloudWatch alarm that fires if that metric goes missing for 26 hours, publishing to an SNS topic that emails `caseymwise@gmail.com`.

See [`backup/README.md`](backup/README.md) for script setup and drive inventory.
See [`cdk/README.md`](cdk/README.md) for deploying the AWS infrastructure.
