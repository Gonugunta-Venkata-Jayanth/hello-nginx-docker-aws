#!/usr/bin/env bash
# Prepares a fresh Amazon Linux 2023 EC2 instance and runs the app on port 8081.
# Use it as EC2 "User data" at launch, or run it after SSH-ing in:
#   curl -fsSL https://raw.githubusercontent.com/Gonugunta-Venkata-Jayanth/hello-nginx-docker-aws/main/scripts/ec2-setup.sh | sudo bash
set -euo pipefail

REPO_URL="https://github.com/Gonugunta-Venkata-Jayanth/hello-nginx-docker-aws.git"
APP_DIR="/opt/hello-nginx-docker-aws"
IMAGE="hello-nginx:latest"
CONTAINER="hello-nginx"
PORT=8081

echo "==> Installing Docker and Git"
dnf install -y docker git

echo "==> Starting Docker and enabling it on boot"
systemctl enable --now docker
usermod -aG docker ec2-user   # lets ec2-user run docker without sudo (after re-login)

echo "==> Verifying Docker"
docker run --rm hello-world

echo "==> Fetching the app"
rm -rf "$APP_DIR"
git clone --depth 1 "$REPO_URL" "$APP_DIR"

echo "==> Building and running the container"
docker build -t "$IMAGE" "$APP_DIR"
docker rm -f "$CONTAINER" 2>/dev/null || true
docker run -d --name "$CONTAINER" --restart unless-stopped -p "$PORT:$PORT" "$IMAGE"

echo "==> Checking the app locally"
sleep 2
curl -fsS "http://localhost:$PORT/health"

PUBLIC_IP=$(curl -fsS -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60" \
  | xargs -I{} curl -fsS -H "X-aws-ec2-metadata-token: {}" http://169.254.169.254/latest/meta-data/public-ipv4 || echo "<public-ip>")
echo "==> Done. Open http://$PUBLIC_IP:$PORT"
