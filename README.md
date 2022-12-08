# Filecoin Data Onboarding Tools

Automates provisioning/deprovisioning of a Filecoin cloud appliance. This consists of an Ubuntu instance in`stalled with Lotus,Lotus-miner, Boost, and Singularity.

Currently configures for Devnet.

There is a CloudFormation template that deploys a EC2 Ubuntu instance with the following:
* Installs prereqs.
* Build & installs Lotus, configured for devnet.
* Build & Installs lotus-miner, configured for immediate on-demand sealing.
* Build & Installs Singularity, deploys workaround for devnet block height.
* Excludes Boost since it does not support devnet "cleanly".
* Runs local integration test, as follows:
    * Generate random test data.
    * Prep to CAR file.
    * Send deal to miner.
    * Import CAR into miner (simulating offline data transfer)
    * Await sealing.
    * Retrieval.

Currently supports Amazon Web Services only. Infra-as-code using AWS CloudFormation. The scripts are largely Bash, so should be portable to other cloud and on-premises environments.

## Running

1. Configure

On a workstation terminal (tested on MacOS), in the repo root, create a ```config.mk.gitignore``` file based on the template. Configure to suit your AWS cloud environment.
```
cp config.mk config.mk.gitignore
```

2. Create an appliance on AWS.

```
make create_appliance
```
If prompted to view the CloudFormation JSON, press Q or enter to accept.
The stack creation should complete in under 2 mins. Note the Lotus tools and tests continue in the background. Should take <20 mins in total.

3. Connect to the appliance over SSH.

Connects over SSH.
```
make connect
```

Monitor the tools setup and test log.
```
tail -f /var/log/filecoin-tools-setup.log
```
Once the log indicates test completed, the environment is ready for dev/test.

4. Stop/Start services.

Control lotus, lotus-miner, and singularity daemons.
```
./lotus/filecoin-tools-setup.sh stop_daemons
./lotus/filecoin-tools-setup.sh start_daemons
./lotus/filecoin-tools-setup.sh restart_daemons
```

5. Stop/Start the appliance.

Save on AWS EC2 charges. Please note that AWS will still charge for stopped EBS storage.
```
make stop_appliance
make start_appliance
```

6. Delete the appliance.

Upon conclusion of testing, please export any work and delete the appliance, to save on AW$ charges.
```
make delete_appliance
```

## Miscellaneous

* Full rebuild on the running Linux instance.
```
./lotus/setup-filecoin-tools.sh full_rebuild_test
```
