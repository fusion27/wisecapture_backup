# newcombe-storage-alerts

CDK stack (TypeScript) that provisions AWS alerting infrastructure for Newcombe's nightly backup script (`wisebackup.sh`).

## What this deploys

| Resource | Name / Value |
|----------|-------------|
| SNS Topic | `newcombe-storage-alerts` |
| Email subscription | `caseymwise@gmail.com` |
| IAM User | `newcombe-wisebackup` |
| IAM Policy | `sns:Publish` on topic; `cloudwatch:PutMetricData` |
| IAM Access Key | Output via stack outputs (configure on Newcombe post-deploy) |
| CloudWatch Alarm | `newcombe-wisebackup-missing` — fires if no `WiseBackup/BackupSuccess` metric in 26 hours |

## Prerequisites

- AWS CLI configured with credentials that have CDK deploy permissions (use Tacoma — Newcombe's `newcombe` IAM user lacks these)
- Node.js / npm installed
- CDK bootstrapped in `690063008832/us-east-1` (run bootstrap step below if not already done)

## Deploy

```bash
npm install
npx node_modules/.bin/cdk bootstrap aws://690063008832/us-east-1   # skip if already done
npx node_modules/.bin/cdk deploy
```

## After deploy

1. Note the `AccessKeyId` and `SecretAccessKey` values from the stack outputs — **do not commit them**
2. On Newcombe, configure the backup profile:
   ```bash
   aws configure --profile wisebackup
   ```
3. Confirm the SNS subscription email sent to `caseymwise@gmail.com`
4. Re-enable cron on Newcombe (`crontab -e` → `0 0 * * * /home/casey/wisebackup.sh`)
5. Run an end-to-end test:
   ```bash
   bash -x /home/casey/wisebackup.sh 2>&1 | tee /home/casey/wisebackup-test-$(date +%Y%m%d).log
   ```

## Alarm logic

The CloudWatch alarm uses 26 consecutive 1-hour evaluation periods with `treatMissingData: BREACHING`. All 26 periods must be missing or zero before the alarm fires, which means a once-daily backup at midnight keeps the alarm green for the full 26-hour window. If the backup stops running entirely, the alarm triggers and publishes to the SNS topic, which delivers an email.

## Context

`wisebackup.sh` runs nightly on Newcombe (Beelink SER5 Pro, `10.0.0.69`) and mirrors the WiseCapture photo archive across two Seagate IronWolf 8TB drives and S3. The SNS topic ARN is hardcoded in the script:

```
arn:aws:sns:us-east-1:690063008832:newcombe-storage-alerts
```

The script's `_sns_alert()` helper uses `|| true` so it fails silently until this stack is deployed and the `wisebackup` AWS profile is configured on Newcombe.
