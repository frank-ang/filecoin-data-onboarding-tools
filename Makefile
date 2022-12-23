# AWS resources.
SHELL=/bin/bash
STACK_NAME="filecoin-singularity-appliance-test"
AWS_APPLIANCE_TEMPLATE=aws/filecoin-client-stack.cloudformation.yml
AWS_APPLIANCE_INSTANCE_ID=$(shell aws cloudformation describe-stacks --stack-name ${STACK_NAME} | jq -r '.Stacks[].Outputs[]|select(.OutputKey=="InstanceId").OutputValue')
AWS_APPLIANCE_IP=$(shell aws ec2 describe-instances --instance-id ${AWS_APPLIANCE_INSTANCE_ID} | jq -r '.Reservations[].Instances[].PublicIpAddress')

-include config.mk.gitignore

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
#	scp lotus/filecoin-tools-setup.sh ubuntu@${AWS_APPLIANCE_IP}:/tmp/
#	ssh ubuntu@${AWS_APPLIANCE_IP} "sudo mv -f /tmp/filecoin-tools-setup.sh /root/filecoin-data-onboarding-tools/lotus/"
	scp lotus/filecoin-tools-tests.sh ubuntu@${AWS_APPLIANCE_IP}:/tmp/
	ssh ubuntu@${AWS_APPLIANCE_IP} "sudo mv -f /tmp/filecoin-tools-tests.sh /root/filecoin-data-onboarding-tools/lotus/"
#	scp lotus/miner-import-car.sh ubuntu@${AWS_APPLIANCE_IP}:/tmp/
#	ssh ubuntu@${AWS_APPLIANCE_IP} "sudo mv -f /tmp/miner-import-car.sh /root/filecoin-data-onboarding-tools/lotus/"


connect_boost:
	@echo "Connecting to boost browser UI at: ${AWS_APPLIANCE_IP}:3000"
	open -n -a "Google Chrome" --args '--new-window' "http://${AWS_APPLIANCE_IP}:3000"
# TODO: investigate UX error: Error: Unexpected token '<', "<!doctype "... is not valid JSON
# ssh -L 3000:localhost:3000 ubuntu@${AWS_APPLIANCE_IP}
# ssh ubuntu@${AWS_APPLIANCE_IP} -L 3001:${AWS_APPLIANCE_IP}:3000 -fN

tunnel_to_appliance:
	@echo "Starting local TCP tunnel to: ${AWS_APPLIANCE_IP}"
	ssh -L 8080:127.0.0.1:8080 ubuntu@${AWS_APPLIANCE_IP}
