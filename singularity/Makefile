# AWS resources.
SHELL=/bin/bash
AWS_APPLIANCE_TEMPLATE=singularity-cloudformation.yml
AWS_APPLIANCE_IP=`aws cloudformation describe-stacks --stack-name filecoin-singularity-appliance-test | jq '.Stacks[].Outputs[]|select(.OutputKey=="PublicIP").OutputValue' -r`


-include config.mk.gitignore

create_appliance:
	@echo "Creating Singularity appliance AWS stack..."
	aws cloudformation validate-template --template-body file://${AWS_APPLIANCE_TEMPLATE}
	time aws cloudformation deploy \
      --stack-name "filecoin-singularity-appliance-test" \
	  --capabilities CAPABILITY_IAM \
      --template-file ${AWS_APPLIANCE_TEMPLATE}  \
      --parameter-overrides "VPC=${AWS_VPC}" "AZ=${AWS_AZ}" "SubnetId=${AWS_SUBNET}" \
         "KeyPair=${AWS_KEY_PAIR}" "SecurityGroup=${AWS_SECURITY_GROUP}" \
		 "InstanceProfile=${AWS_INSTANCE_PROFILE}" \
      --tags "project=filecoin"
	@echo "Singularity Test EC2 Ubuntu instance IP: "`aws cloudformation describe-stacks --stack-name filecoin-singularity-appliance-test | jq '.Stacks[].Outputs[]|select(.OutputKey=="PublicIP").OutputValue' -r`

delete_appliance:
	@echo "Deleting singularity appliance AWS stack..."
	aws cloudformation delete-stack --stack-name filecoin-singularity-appliance-test

recreate_appliance: delete_appliance wait_delete_appliance create_appliance
	@echo "Recreated singularity appliance AWS stack..."

wait_delete_appliance:
	aws cloudformation wait stack-delete-complete --stack-name filecoin-singularity-appliance-test

verify_appliance:
	ssh ubuntu@${AWS_APPLIANCE_IP} "grep 'EC2 instance inititalization COMPLETE' /var/log/cloud-init-output.log || exit 1"
	ssh ubuntu@${AWS_APPLIANCE_IP} "cat /var/log/cloud-init-output.log"
