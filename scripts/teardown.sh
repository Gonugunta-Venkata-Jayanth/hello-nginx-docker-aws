#!/usr/bin/env bash
# Removes everything the ECS deploy created so nothing keeps billing.
# EC2: stop or terminate the instance from the console (or pass INSTANCE_ID).
set -uo pipefail

REGION="${AWS_REGION:-ap-south-1}"
CLUSTER="hello-nginx-cluster"
SERVICE="hello-nginx-service"

echo "==> Scaling the ECS service to 0 and deleting it"
aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" --desired-count 0 --region "$REGION" >/dev/null
aws ecs delete-service --cluster "$CLUSTER" --service "$SERVICE" --force --region "$REGION" >/dev/null
aws ecs wait services-inactive --cluster "$CLUSTER" --services "$SERVICE" --region "$REGION"
aws ecs delete-cluster --cluster "$CLUSTER" --region "$REGION" >/dev/null

echo "==> Deleting the ECR repository, log group and security group"
aws ecr delete-repository --repository-name hello-nginx --force --region "$REGION" >/dev/null
aws logs delete-log-group --log-group-name /ecs/hello-nginx --region "$REGION"
SG_ID=$(aws ec2 describe-security-groups --filters Name=group-name,Values=hello-nginx-ecs-sg \
  --query 'SecurityGroups[0].GroupId' --output text --region "$REGION")
[ "$SG_ID" != "None" ] && aws ec2 delete-security-group --group-id "$SG_ID" --region "$REGION"

if [ -n "${INSTANCE_ID:-}" ]; then
  echo "==> Terminating EC2 instance $INSTANCE_ID (its root volume is deleted with it)"
  aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION" >/dev/null
fi
echo "==> Teardown complete"
