# Filecoin Data Onboarding Tools

Automates provisioning/deprovisioning of a Filecoin cloud appliance. This consists of an Ubuntu instance in`stalled with Lotus,Lotus-miner, Boost, and Singularity.

Currently configures for Devnet.

There is a CloudFormation template that deploys an Ubuntu instance running the following script in the background:
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

Rapidly spin up the stack on an Ubuntu AWS EC2 instance, CloudFormation template provided. Setup scripts are portable to similar Ubuntu environments.

## Prerequisites:

Local Workstation (tested on MacOS) with bash, make, jq, etc.
Ubuntu Linux instance (tested on AWS EC2 r5.2xlarge)


## Running

1. Configure

On a workstation terminal (tested on MacOS), in the repo root, create a ```config.mk.gitignore``` file based on the template [config.mk](config.mk). Configure to your AWS environment.

2. Create an appliance on AWS.

```bash
make create_appliance
```
If prompted to view the CloudFormation JSON, press Q or enter to accept.
The stack creation should complete in around 2 mins. S
The instance bootstrapping and test scripts run in the background. Filecoin client tools go through build/install/config/startup/tests as a background process, taking <20 mins?? (TODO update).

3. Connect to the appliance over SSH.

Connect over SSH. You need to first configure ```AWS_KEY_PAIR``` in ```config.mk.gitignore``` to the Ubuntu EC2 instance keypair for certificate login.
```bash
make connect
```
commands on the Ubuntu instance are run as root.
```bash
sudo su
```

Monitor the tools setup and test log.
```bash
tail -f /var/log/filecoin-tools-setup.log
```
Once the log indicates test completed, the environment is ready for dev/test.

4. Stop/Start services.

Control lotus, lotus-miner, and singularity daemons.
```bash
./lotus/filecoin-tools-setup.sh stop_daemons
./lotus/filecoin-tools-setup.sh start_daemons
./lotus/filecoin-tools-setup.sh restart_daemons
```

5. Stop/Start the appliance.

Save on AWS EC2 charges. Please note that AWS will still charge for stopped EBS storage.
```bash
make stop_appliance
make start_appliance
```

6. Delete the appliance.

Upon conclusion of testing, please export any work and delete the appliance, to save on AW$ charges.
```bash
make delete_appliance
```

### Legacy markets test.

Full rebuild and legacy markets test.
```bash
cd $HOME/filecoin-data-onboarding-tools/lotus
nohup ./filecoin-tools-setup.sh full_build_test_legacy >> /var/log/filecoin-tools-setup.log 2>&1 &
```

Re-run tests only.
```bash
cd $HOME/filecoin-data-onboarding-tools/lotus
nohup ./filecoin-tools-setup.sh test_singularity >> test_singularity.log 2>&1 &

```

### Boost markets test.

Full rebuild and boost markets test.
```bash
cd ./lotus
nohup ./filecoin-tools-setup.sh run >> /var/log/filecoin-tools-setup.log 2>&1 &
```

For MacOS, to connect to remote Boost UX, open your local workstation shell terminal, and:
```
make connect_boost
```
This starts an SSH tunnel in the background, and opens Chrome to the URL (http://localhost:8080)[http://localhost:8080]. The Boost admin page should load.

For other platforms:
```
make start_tunnel
# access http://localhost:8080 , when completed, 
make stop_tunnel
```



