#!/bin/bash
# Launches one EC2 instance from the stock Amazon Linux 2023 AMI, runs measure.sh, downloads the results and terminates it.
#
# Required environment:
#   SUBNET_ID, SECURITY_GROUP_ID (must allow SSH from here), KEY_NAME, KEY_FILE
# Optional:
#   INSTANCE_TYPE (default c6id.32xlarge), REGION (default us-east-2), DURATION seconds (default 300),
#   AMI (default: latest AL2023 from SSM), INSTANCE_PROFILE, OUT (default ./results/<type>-<timestamp>)
set -eu
: "${SUBNET_ID:?}" "${SECURITY_GROUP_ID:?}" "${KEY_NAME:?}" "${KEY_FILE:?}"
TYPE=${INSTANCE_TYPE:-c6id.32xlarge}
REGION=${REGION:-us-east-2}
DURATION=${DURATION:-300}
AMI=${AMI:-$(aws ssm get-parameter --region "$REGION" --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query Parameter.Value --output text)}
OUT=${OUT:-results/$TYPE-$(date -u +%Y%m%dT%H%M%SZ)}
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT"
SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 -i $KEY_FILE"

# The instance terminates itself after 60 minutes in case this script is interrupted
ID=$(aws ec2 run-instances --region "$REGION" --image-id "$AMI" --instance-type "$TYPE" \
  --key-name "$KEY_NAME" --subnet-id "$SUBNET_ID" --security-group-ids "$SECURITY_GROUP_ID" --associate-public-ip-address \
  ${INSTANCE_PROFILE:+--iam-instance-profile Name=$INSTANCE_PROFILE} \
  --instance-initiated-shutdown-behavior terminate --user-data $'#!/bin/bash\nshutdown -h +60' \
  --tag-specifications '[{"ResourceType":"instance","Tags":[{"Key":"Name","Value":"aws-nitro-cpu-steal"}]}]' \
  --query 'Instances[0].InstanceId' --output text)
trap 'aws ec2 terminate-instances --region "$REGION" --instance-ids "$ID" > /dev/null' EXIT
echo "launched $ID ($TYPE, $AMI)"

aws ec2 wait instance-running --region "$REGION" --instance-ids "$ID"
IP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$ID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
for _ in $(seq 60); do $SSH "ec2-user@$IP" true 2> /dev/null && break; sleep 10; done

$SSH "ec2-user@$IP" 'cat > measure.sh && chmod +x measure.sh' < "$HERE/measure.sh"
echo "measuring for $DURATION s"
$SSH "ec2-user@$IP" "sudo ./measure.sh $DURATION && sudo tar czf - out" | tar xzf - -C "$OUT" --strip-components=1
echo "$TYPE $AMI $ID" > "$OUT/instance.txt"

aws ec2 terminate-instances --region "$REGION" --instance-ids "$ID" > /dev/null
trap - EXIT
aws ec2 wait instance-terminated --region "$REGION" --instance-ids "$ID"
echo "terminated $ID; results in $OUT"
python3 "$HERE/analyze.py" "$OUT"
