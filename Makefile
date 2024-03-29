# AWS resources.
SHELL=/bin/bash
export AWS_DEFAULT_REGION=ap-southeast-1

STACK_NAME="filecoin-singularity-appliance-test"
AWS_APPLIANCE_TEMPLATE=aws/filecoin-client-stack.cloudformation.yml
AWS_APPLIANCE_INSTANCE_ID=$(shell aws cloudformation describe-stacks --stack-name ${STACK_NAME} --region ${AWS_DEFAULT_REGION} | jq -r '.Stacks[].Outputs[]|select(.OutputKey=="InstanceId").OutputValue')
AWS_APPLIANCE_IP=$(shell aws ec2 describe-instances --instance-id ${AWS_APPLIANCE_INSTANCE_ID} --region ${AWS_DEFAULT_REGION} | jq -r '.Reservations[].Instances[].PublicIpAddress')

-include config.mk.singapore.gitignore

create_appliance:
	@echo "Creating Singularity appliance AWS stack..."
	aws cloudformation validate-template --template-body file://${AWS_APPLIANCE_TEMPLATE}
	time aws cloudformation deploy \
      --stack-name "${STACK_NAME}" \
	  --capabilities CAPABILITY_IAM \
      --template-file ${AWS_APPLIANCE_TEMPLATE}  \
      --parameter-overrides "VPC=${AWS_VPC}" "AZ=${AWS_AZ}" "SubnetId=${AWS_SUBNET}" \
         "KeyPair=${AWS_KEY_PAIR}" "SecurityGroup=${AWS_SECURITY_GROUP}" \
		 "InstanceProfile=${AWS_INSTANCE_PROFILE}" \
      --tags "project=filecoin"
	@echo "Singularity Test EC2 Ubuntu instance IP: "`aws cloudformation describe-stacks --stack-name ${STACK_NAME} | jq '.Stacks[].Outputs[]|select(.OutputKey=="PublicIP").OutputValue' -r`

delete_appliance:
	@echo "Deleting singularity appliance AWS stack..."
	aws cloudformation delete-stack --stack-name ${STACK_NAME}

recreate_appliance: delete_appliance wait_delete_appliance create_appliance
	@echo "Recreated singularity appliance AWS stack..."

stop_appliance:
	aws ec2 stop-instances --instance-ids ${AWS_APPLIANCE_INSTANCE_ID}

start_appliance:
	aws ec2 start-instances --instance-ids ${AWS_APPLIANCE_INSTANCE_ID}

wait_delete_appliance:
	aws cloudformation wait stack-delete-complete --stack-name ${STACK_NAME}

connect_verify:
	ssh ubuntu@${AWS_APPLIANCE_IP} "grep 'EC2 instance inititalization COMPLETE' /var/log/cloud-init-output.log || exit 1" \
	&& ssh ubuntu@${AWS_APPLIANCE_IP} "sudo grep 'PREP_STATUS: completed' /root/filecoin-data-onboarding-tools/singularity-tests.log || exit 1" \
	&& ssh ubuntu@${AWS_APPLIANCE_IP} "sudo grep '## Building lotus' /root/filecoin-data-onboarding-tools/lotus-init-devnet.log || exit 1" \
	&& ssh ubuntu@${AWS_APPLIANCE_IP} "sudo grep '## Lotus setup completed.' /root/filecoin-data-onboarding-tools/lotus-init-devnet.log || exit 1"
	@echo "verification completed."

connect:
	@echo "connecting to: ${AWS_APPLIANCE_IP}"
	ssh ubuntu@${AWS_APPLIANCE_IP}

deploy_script:
	scp lotus/filecoin-tools-setup.sh ubuntu@${AWS_APPLIANCE_IP}:/tmp/
	ssh ubuntu@${AWS_APPLIANCE_IP} "sudo mv -f /tmp/filecoin-tools-setup.sh /root/filecoin-data-onboarding-tools/lotus/"
	scp lotus/filecoin-tools-tests.sh ubuntu@${AWS_APPLIANCE_IP}:/tmp/
	ssh ubuntu@${AWS_APPLIANCE_IP} "sudo mv -f /tmp/filecoin-tools-tests.sh /root/filecoin-data-onboarding-tools/lotus/"
	scp lotus/boost-setup.sh ubuntu@${AWS_APPLIANCE_IP}:/tmp/
	ssh ubuntu@${AWS_APPLIANCE_IP} "sudo mv -f /tmp/boost-setup.sh /root/filecoin-data-onboarding-tools/lotus/"
#	scp lotus/miner-import-car.sh ubuntu@${AWS_APPLIANCE_IP}:/tmp/
#	ssh ubuntu@${AWS_APPLIANCE_IP} "sudo mv -f /tmp/miner-import-car.sh /root/filecoin-data-onboarding-tools/lotus/"
# retrieval scripts.
#	scp lotus/fil-ls ubuntu@${AWS_APPLIANCE_IP}:/tmp/
#	ssh ubuntu@${AWS_APPLIANCE_IP} "sudo mv -f /tmp/fil-ls /root/filecoin-data-onboarding-tools/lotus/"
#	scp lotus/fil-cp ubuntu@${AWS_APPLIANCE_IP}:/tmp/
#	ssh ubuntu@${AWS_APPLIANCE_IP} "sudo mv -f /tmp/fil-cp /root/filecoin-data-onboarding-tools/lotus/"
#	scp lotus/fil-explain ubuntu@${AWS_APPLIANCE_IP}:/tmp/
#	ssh ubuntu@${AWS_APPLIANCE_IP} "sudo mv -f /tmp/fil-explain /root/filecoin-data-onboarding-tools/lotus/"

connect_boost: start_tunnel
	@echo "Connecting to Boost UX: ${AWS_APPLIANCE_IP}:8080"
	@echo starting local MacOS SSH tunnel...
	ssh -L 8080:localhost:8080 ubuntu@${AWS_APPLIANCE_IP} &
	open -n -a "Google Chrome" --args '--new-window' "http://localhost:8080"

start_tunnel:
	@echo "Starting local TCP tunnel to: ${AWS_APPLIANCE_IP}"
	ssh -M -S ~/boost-tunnel-socket.tmp -o "ExitOnForwardFailure yes" -o "StrictHostKeyChecking no" -fN -L 8080:localhost:8080 ubuntu@${AWS_APPLIANCE_IP}

stop_tunnel:
	ssh -S ~/boost-tunnel-socket.tmp ${AWS_APPLIANCE_IP} -O exit
