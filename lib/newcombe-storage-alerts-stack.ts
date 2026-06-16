import * as cdk from 'aws-cdk-lib';
import * as sns from 'aws-cdk-lib/aws-sns';
import * as subscriptions from 'aws-cdk-lib/aws-sns-subscriptions';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as cloudwatch from 'aws-cdk-lib/aws-cloudwatch';
import * as cloudwatch_actions from 'aws-cdk-lib/aws-cloudwatch-actions';
import * as constructs from 'constructs';

export class NewcombeStorageAlertsStack extends cdk.Stack {
  constructor(scope: constructs.Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    const topic = new sns.Topic(this, 'AlertsTopic', {
      topicName: 'newcombe-storage-alerts',
      displayName: 'Newcombe Storage Alerts',
    });

    topic.addSubscription(new subscriptions.EmailSubscription('caseymwise@gmail.com'));

    const backupUser = new iam.User(this, 'BackupUser', {
      userName: 'newcombe-wisebackup',
    });

    backupUser.addToPolicy(new iam.PolicyStatement({
      actions: ['sns:Publish'],
      resources: [topic.topicArn],
    }));

    // cloudwatch:PutMetricData does not support resource-level permissions
    backupUser.addToPolicy(new iam.PolicyStatement({
      actions: ['cloudwatch:PutMetricData'],
      resources: ['*'],
    }));

    const accessKey = new iam.CfnAccessKey(this, 'BackupUserAccessKey', {
      userName: backupUser.userName,
    });

    // Alarm: BREACHING if no WiseBackup/BackupSuccess metric published in any of the last
    // 26 consecutive 1-hour periods (i.e., nothing in ~26 hours).
    const backupSuccessMetric = new cloudwatch.Metric({
      namespace: 'WiseBackup',
      metricName: 'BackupSuccess',
      statistic: 'Sum',
      period: cdk.Duration.hours(1),
    });

    const missedBackupAlarm = new cloudwatch.Alarm(this, 'MissedBackupAlarm', {
      alarmName: 'newcombe-wisebackup-missing',
      alarmDescription: 'No WiseBackup/BackupSuccess metric published in the last 26 hours',
      metric: backupSuccessMetric,
      evaluationPeriods: 26,
      datapointsToAlarm: 26,
      threshold: 1,
      comparisonOperator: cloudwatch.ComparisonOperator.LESS_THAN_THRESHOLD,
      treatMissingData: cloudwatch.TreatMissingData.BREACHING,
    });

    missedBackupAlarm.addAlarmAction(new cloudwatch_actions.SnsAction(topic));

    new cdk.CfnOutput(this, 'TopicArn', {
      description: 'SNS Topic ARN',
      value: topic.topicArn,
    });

    new cdk.CfnOutput(this, 'AccessKeyId', {
      description: 'newcombe-wisebackup IAM access key ID',
      value: accessKey.ref,
    });

    new cdk.CfnOutput(this, 'SecretAccessKey', {
      description: 'newcombe-wisebackup IAM secret access key — configure on Newcombe, do not commit',
      value: accessKey.attrSecretAccessKey,
    });
  }
}
