#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { NewcombeStorageAlertsStack } from '../lib/newcombe-storage-alerts-stack';

const app = new cdk.App();
new NewcombeStorageAlertsStack(app, 'NewcombeStorageAlertsStack', {
  env: {
    account: '690063008832',
    region: 'us-east-1',
  },
});
