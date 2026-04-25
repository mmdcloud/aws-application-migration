# GCP → AWS Migration via AWS Application Migration Service (MGN)

## Architecture Overview

```
GCP us-central1-a                          AWS us-east-1
┌─────────────────────┐                   ┌──────────────────────────────────────┐
│  source-instance    │  TCP 1500          │  Staging Area (public subnet)        │
│  (Ubuntu 20.04      │ ─────────────────▶│  Replication Server (t3.small)       │
│   e2-micro, nginx)  │                   │  ↓ (replicated EBS volumes)          │
│                     │                   │                                       │
│  [MGN Agent]        │  TCP 443          │  MGN Service Plane                   │
│                     │ ─────────────────▶│  (mgn.us-east-1.amazonaws.com)       │
└─────────────────────┘                   │                                       │
                                          │  Test / Cutover Launch               │
                                          │  migrated EC2 (t3.micro)             │
                                          │  - nginx running                      │
                                          │  - SSM agent                         │
                                          │  - CloudWatch agent                  │
                                          └──────────────────────────────────────┘
```

## Files

| File | Purpose |
|------|---------|
| `provider.tf` | AWS + GCP provider config |
| `variables.tf` | All configurable inputs |
| `gcp_source.tf` | Existing GCP VM (unchanged) |
| `aws_networking.tf` | Target VPC, subnets, IGW, NAT |
| `aws_iam.tf` | MGN service roles, agent IAM user, Secrets Manager |
| `aws_security_groups.tf` | Replication server SG + migrated instance SG |
| `aws_s3.tf` | MGN staging bucket |
| `aws_mgn.tf` | Replication template, launch template, source server |
| `aws_ec2_launch_template.tf` | EC2 launch template for test/cutover instances |
| `outputs.tf` | Key resource IDs + agent install command |

## Step-by-Step Migration Runbook

### Phase 1 — Terraform Apply

```bash
terraform init
terraform plan -out=mgn.plan
terraform apply mgn.plan
```

### Phase 2 — Install MGN Agent on GCP VM

```bash
# Fetch credentials from Secrets Manager
CREDS=$(aws secretsmanager get-secret-value \
  --secret-id mgn/agent-credentials \
  --region us-east-1 \
  --query SecretString --output text)

ACCESS_KEY=$(echo $CREDS | jq -r .access_key_id)
SECRET_KEY=$(echo $CREDS | jq -r .secret_access_key)

# SSH into the GCP VM
gcloud compute ssh source-instance --zone us-central1-a

# On the GCP VM:
wget -O ./aws-replication-installer-init.py \
  https://aws-application-migration-service-us-east-1.s3.us-east-1.amazonaws.com/latest/linux/aws-replication-installer-init.py

sudo python3 aws-replication-installer-init.py \
  --region us-east-1 \
  --aws-access-key-id $ACCESS_KEY \
  --aws-secret-access-key $SECRET_KEY \
  --no-prompt
```

### Phase 3 — Monitor Replication

```bash
# Check replication status
aws mgn describe-source-servers \
  --filters '{"lifeCycleStates": ["READY_FOR_TEST"]}' \
  --region us-east-1
```

Wait for `dataReplicationState` → `CONTINUOUS` (typically 1–4 hours for initial sync depending on disk size).

### Phase 4 — Test Launch

```bash
# Get source server ID
SOURCE_SERVER_ID=$(aws mgn describe-source-servers \
  --region us-east-1 \
  --query 'items[0].sourceServerID' --output text)

# Launch test instance
aws mgn start-test \
  --source-server-ids $SOURCE_SERVER_ID \
  --region us-east-1
```

Validate:
- nginx responds on port 80
- SSM Session Manager works (no SSH needed)
- Disk layout matches source

Mark test complete:
```bash
aws mgn finish-test \
  --source-server-ids $SOURCE_SERVER_ID \
  --region us-east-1
```

### Phase 5 — Cutover

```bash
# Mark ready for cutover (stops replication server)
aws mgn mark-as-ready-for-cutover \
  --source-server-ids $SOURCE_SERVER_ID \
  --region us-east-1

# Launch cutover instance
aws mgn start-cutover \
  --source-server-ids $SOURCE_SERVER_ID \
  --region us-east-1

# After validation, finalize
aws mgn finalize-cutover \
  --source-server-ids $SOURCE_SERVER_ID \
  --region us-east-1
```

### Phase 6 — Import Source Server into Terraform (optional)

Once the MGN agent registers, import the source server resource:

```bash
SOURCE_SERVER_ID=$(aws mgn describe-source-servers \
  --region us-east-1 \
  --query 'items[0].sourceServerID' --output text)

terraform import aws_mgn_source_server.gcp_vm $SOURCE_SERVER_ID
terraform import aws_mgn_launch_configuration.gcp_vm $SOURCE_SERVER_ID
terraform import aws_mgn_replication_configuration.gcp_vm $SOURCE_SERVER_ID
```

### Phase 7 — Cleanup

```bash
# Disconnect source server from MGN
aws mgn disconnect-from-service \
  --source-server-ids $SOURCE_SERVER_ID \
  --region us-east-1

# Archive source server
aws mgn archive-application \
  --application-id $SOURCE_SERVER_ID \
  --region us-east-1

# Destroy GCP source if migration is complete
terraform destroy -target=module.source_instance
```

## Key Port Requirements

| Direction | Protocol | Port | From → To |
|-----------|----------|------|-----------|
| Outbound (GCP VM) | TCP | 443 | GCP VM → mgn.us-east-1.amazonaws.com |
| Outbound (GCP VM) | TCP | 1500 | GCP VM → Replication Server EIP |
| Inbound (Replication SG) | TCP | 1500 | GCP VM public IP → Replication server |

## Cost Estimate

| Resource | Cost |
|----------|------|
| MGN service | Free |
| Replication server (t3.small) | ~$0.023/hr while replicating |
| Staging EBS (gp3, ~10GB) | ~$0.08/GB/month |
| NAT Gateway | ~$0.045/hr + data |
| S3 staging | Minimal |
| Test/cutover EC2 (t3.micro) | ~$0.0104/hr |