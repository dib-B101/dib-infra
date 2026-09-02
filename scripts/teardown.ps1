# teardown.ps1 — ★ 철거는 반드시 이 스크립트로 (Ingress 먼저, Terraform은 그다음)
# 이유: ALB는 K8s 컨트롤러가 만들어서 Terraform 장부에 없음.
#       순서를 어기면 ALB가 VPC를 물고 있어 destroy 실패 + 잔해 과금.
$ErrorActionPreference = "Continue"
Set-Location $PSScriptRoot\..

# 1. K8s가 만든 AWS 리소스(ALB)부터 삭제 유발
kubectl delete ingress --all --ignore-not-found
kubectl delete -f infra\k8s\ --ignore-not-found
Write-Host "ALB 삭제 대기 90초..."
Start-Sleep -Seconds 90

# 2. Terraform 스택 삭제 (~15분)
Set-Location infra\ephemeral
terraform destroy -auto-approve

# 3. 삭제 검증 — 전부 [] 또는 빈 값이어야 함
Set-Location ..\..
Write-Host "`n===== 삭제 검증 =====" -ForegroundColor Yellow
aws eks list-clusters --region ap-northeast-2 --query "clusters"
aws rds describe-db-instances --query "DBInstances[].DBInstanceIdentifier"
aws elasticache describe-replication-groups --query "ReplicationGroups[].ReplicationGroupId"
aws elbv2 describe-load-balancers --query "LoadBalancers[].LoadBalancerName"
aws ec2 describe-nat-gateways --filter Name=state,Values=available --query "NatGateways[].NatGatewayId"
aws ec2 describe-instances --filters Name=instance-state-name,Values=running --query "Reservations[].Instances[].InstanceId"
aws ec2 describe-volumes --filters Name=status,Values=available --query "Volumes[].VolumeId"
aws ec2 describe-addresses --query "Addresses[].PublicIp"
Write-Host "전부 비어 있으면 과금 요소 0. ECR/S3(상시 스택)만 남은 게 정상" -ForegroundColor Green
