#!/usr/bin/env bash
# End-to-end test: deploys to EC2 and ECS Fargate, checks both answer on 8081,
# then tears everything down. Run from AWS CloudShell or any shell with
# AWS CLI v2 + Docker and IAM user credentials.
set -euo pipefail

export AWS_REGION="${AWS_REGION:-ap-south-1}"
NAME="hello-nginx"
SG_NAME="hello-nginx-ec2-sg"
cd "$(dirname "$0")/.."

wait_for_http() {   # wait_for_http <url> <tries>
  for _ in $(seq 1 "$2"); do
    if curl -fsS --max-time 5 "$1" | grep -q "Hello, World!"; then return 0; fi
    sleep 10
  done
  return 1
}

echo "==> [EC2] Security group: 22 and 8081"
VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
SG_ID=$(aws ec2 describe-security-groups --filters Name=group-name,Values="$SG_NAME" Name=vpc-id,Values="$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text)
if [ "$SG_ID" = "None" ]; then
  SG_ID=$(aws ec2 create-security-group --group-name "$SG_NAME" --description "SSH and app port 8081" \
    --vpc-id "$VPC_ID" --query GroupId --output text)
  MY_IP=$(curl -fsS https://checkip.amazonaws.com)
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 22 --cidr "$MY_IP/32" >/dev/null
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 8081 --cidr 0.0.0.0/0 >/dev/null
fi

echo "==> [EC2] Launching t3.micro (Amazon Linux 2023, 8 GiB gp3) with ec2-setup.sh as user data"
AMI_ID=$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query Parameter.Value --output text)
INSTANCE_ID=$(aws ec2 run-instances --image-id "$AMI_ID" --instance-type t3.micro \
  --security-group-ids "$SG_ID" --user-data file://scripts/ec2-setup.sh \
  --block-device-mappings 'DeviceName=/dev/xvda,Ebs={VolumeSize=8,VolumeType=gp3,DeleteOnTermination=true}' \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME-e2e}]" \
  --query 'Instances[0].InstanceId' --output text)
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
EC2_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
echo "    $INSTANCE_ID at $EC2_IP, waiting for the app..."
if wait_for_http "http://$EC2_IP:8081" 36; then EC2_RESULT="PASS"; else EC2_RESULT="FAIL"; fi
echo "==> [EC2] http://$EC2_IP:8081 -> $EC2_RESULT"

echo "==> [ECS] Deploying with ecs/deploy-ecs.sh"
ECS_OUT=$(./ecs/deploy-ecs.sh | tee /dev/stderr) || true
ECS_URL=$(echo "$ECS_OUT" | grep -o 'http://[0-9.]*:8081' | tail -1)
if [ -n "$ECS_URL" ] && wait_for_http "$ECS_URL" 12; then ECS_RESULT="PASS"; else ECS_RESULT="FAIL"; fi
echo "==> [ECS] $ECS_URL -> $ECS_RESULT"

echo "==> Teardown"
INSTANCE_ID="$INSTANCE_ID" ./scripts/teardown.sh
aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID"
aws ec2 delete-security-group --group-id "$SG_ID"

echo "==> Leftover check (all should be empty)"
echo "Running/stopped instances: $(aws ec2 describe-instances --filters Name=instance-state-name,Values=pending,running,stopping,stopped --query 'Reservations[].Instances[].InstanceId' --output text)"
echo "ECS clusters: $(aws ecs list-clusters --query clusterArns --output text)"
echo "Load balancers: $(aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName' --output text)"
echo "Elastic IPs: $(aws ec2 describe-addresses --query 'Addresses[].PublicIp' --output text)"
echo "Unattached volumes: $(aws ec2 describe-volumes --filters Name=status,Values=available --query 'Volumes[].VolumeId' --output text)"
echo "ECR repos: $(aws ecr describe-repositories --query 'repositories[].repositoryName' --output text)"

echo "RESULT: EC2=$EC2_RESULT ECS=$ECS_RESULT"
[ "$EC2_RESULT" = "PASS" ] && [ "$ECS_RESULT" = "PASS" ]
