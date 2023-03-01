# Filecoin Storage Gateway

## User Journey.

* Spin-up Storage Gateway instance. Build, Install, init stack.

* Connect to instance, view admin landing page. View link to make a Datacap application.

* Configure Client Wallet (Datacap or FIL). Import default wallet. Export default wallet.

* Prepare DataSet.
    * Add DataSet
    * Start DataSet prep.
    * View/pause/resume/retry prep job
    * Host DataSet (CAR files).
    * Remove DataSet.

* Replicate DataSet.
    * Configure Replication
        * Select number of replicas.
        * Select SP for each replica (drop-down list?)
        * Configure replication schedule. 
          (user will need guidance, depends on bandwidth, SP sealing rate, to determine flow control)
        * Verified deals or FIL-price.
    * Start Replication
    * Pause/Restart Replication 
    * View Replication status

* Create Index

* Retrieve data
    * fil-ls: Directory listing at dataset path
    * fil-cp: Copy dataset file to local.

* Shutdown/Startup Storage Gateway VM.

* Delete Storage Gateway VM.

* Restore Storage Gateway VM from backup (MVP: cloud image snapshot)
    * restore ipfs index
    * restore singularity db
    * restore config files.

## Benefits.

* Automates the provisioning of a client tools stack in the cloud.  (MVP: provision to AWS)
* Technically enables data owner self-service onboarding.

## Architectural Decisions.

* User is responsible for datacap application, or wallet FIL funding, and import.
* Online deals, hosting for data transfer.
* Single-tenanted.
* Question: how to handle maintenance and upgrades?

## Deliverables.

* AWS CloudFormation template and scripts.
* (stretch) Terraform template?
* UX

## Future Enhancements.

* LRU local near-cache.
* ISV hardware NAS appliance.
* ISV-funded preloaded FIL wallets for deals?

## Project Asks.

* Grant funding.
