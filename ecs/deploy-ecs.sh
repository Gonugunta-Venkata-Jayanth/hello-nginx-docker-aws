#!/usr/bin/env bash
# Deploys the same image to ECS Fargate: pushes to ECR, registers the task
# definition, and runs one task with a public IP in the default VPC.
# Needs: AWS CLI v2, Docker, and credentials for an IAM user (not root).
set -euo pipefail

REGION="${AWS_REGION:-ap-south-1}"
NAME="hello-nginx"
CLUSTER="hello-nginx-cluster"
SERVICE="hello-nginx-service"
SG_NAME="hello-nginx-ecs-sg"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGISTRY="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"
cd "$(dirname "$0")/.."

echo "==> ECR repository and image"
aws ecr describe-repositories --repository-names "$NAME" --region "$REGION" >/dev/null 2>&1 \
  || aws ecr create-repository --repository-name "$NAME" --region "$REGION" >/dev/null
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"
docker build --platform linux/amd64 -t "$REGISTRY/$NAME:latest" .
docker push "$REGISTRY/$NAME:latest"

echo "==> ECS service-linked role (new accounts don't have it until ECS is first used)"
aws iam get-role --role-name AWSServiceRoleForECS >/dev/null 2>&1 \
  || aws iam create-service-linked-role --aws-service-name ecs.amazonaws.com >/dev/null

echo "==> Task execution role (lets ECS pull from ECR and write logs)"
if ! aws iam get-role --role-name ecsTaskExecutionRole >/dev/null 2>&1; then
  aws iam create-role --role-name ecsTaskExecutionRole --assume-role-policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  aws iam attach-role-policy --role-name ecsTaskExecutionRole \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
  sleep 10   # IAM changes take a few seconds to propagate
fi

echo "==> Log group"
aws logs create-log-group --log-group-name "/ecs/$NAME" --region "$REGION" 2>/dev/null || true
aws logs put-retention-policy --log-group-name "/ecs/$NAME" --retention-in-days 1 --region "$REGION"

echo "==> Task definition"
sed -e "s/ACCOUNT_ID/$ACCOUNT_ID/g" -e "s/REGION/$REGION/g" ecs/task-definition.json > /tmp/taskdef.json
aws ecs register-task-definition --cli-input-json file:///tmp/taskdef.json --region "$REGION" >/dev/null

echo "==> Network: default VPC, public subnets, security group open on 8081"
VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text --region "$REGION")
SUBNETS=$(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC_ID" Name=default-for-az,Values=true \
  --query 'Subnets[].SubnetId' --output text --region "$REGION" | tr '\t' ',')
SG_ID=$(aws ec2 describe-security-groups --filters Name=group-name,Values="$SG_NAME" Name=vpc-id,Values="$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text --region "$REGION")
if [ "$SG_ID" = "None" ]; then
  SG_ID=$(aws ec2 create-security-group --group-name "$SG_NAME" --description "Allow HTTP on 8081 to ECS task" \
    --vpc-id "$VPC_ID" --query GroupId --output text --region "$REGION")
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 8081 --cidr 0.0.0.0/0 --region "$REGION" >/dev/null
fi

echo "==> Cluster and service"
aws ecs create-cluster --cluster-name "$CLUSTER" --region "$REGION" >/dev/null
if aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --region "$REGION" \
     --query 'services[?status==`ACTIVE`]' --output text | grep -q .; then
  aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" --task-definition "$NAME" \
    --desired-count 1 --force-new-deployment --region "$REGION" >/dev/null
else
  aws ecs create-service --cluster "$CLUSTER" --service-name "$SERVICE" --task-definition "$NAME" \
    --desired-count 1 --launch-type FARGATE --region "$REGION" \
    --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SG_ID],assignPublicIp=ENABLED}" >/dev/null
fi

echo "==> Waiting for the service to become stable"
aws ecs wait services-stable --cluster "$CLUSTER" --services "$SERVICE" --region "$REGION"
TASK_ARN=$(aws ecs list-tasks --cluster "$CLUSTER" --service-name "$SERVICE" --query 'taskArns[0]' --output text --region "$REGION")
ENI_ID=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK_ARN" --region "$REGION" \
  --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value" --output text)
PUBLIC_IP=$(aws ec2 describe-network-interfaces --network-interface-ids "$ENI_ID" --region "$REGION" \
  --query 'NetworkInterfaces[0].Association.PublicIp' --output text)
echo "==> Running on ECS: http://$PUBLIC_IP:8081"
