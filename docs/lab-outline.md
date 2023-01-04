# Class Name: Technical Introduction to Data Archival on Filecoin.

* Class concept: introductory technical familiarization lab for evaluators from data clients. Walkthru to prepare data, make deals to a local devnet 2k sectors miner, and retrieval.
* Target attendees: Evaluators, data owners, data preparers, that have PiB-scale archival requirements.
* Prereqs: 
    * Practical skill in Linux CLI, Bash, SSH. 
    * Attendee desktop pre-installed with SSH client (e.g. OpenSSH Client on Windows 10). 
    * Access to an AWS account: 
        * PL/FF-provisioned dev desktop environment, password provisioned? 
        * OR, BYOD with pre-installed AWS CLI,
    * Basic understanding of Filecoin.
* Delivery format: Online classroom, 2 hours.

* Lab Environment: AWS (during MVP), 
    * either attendee bring-your-own-cloud or 
    * AWS CloudFormation click-thru provisioning.
    * Option of PL/FF provisioned hosted classroom AWS accounts. 
        * Questions: Who owns PL/FF AWS master account? how to request for a child account? budget?
    * Not Docker containers. Interactive lab. Reduces lab dependency on docker, fewer moving parts.

* Notes:
    * Should set attendee expectation that the classroom local devnet miners will have very limited sealing rate. <1MB sealed per lab. 2x.large EC2 instance sizes?
    * Attendees using self-provisioned environments should be reminded to stop/delete after the class to save costs.
    * Devnet FIL deals, not datacap.
    * Have sufficient Instructor + Lab assistants ratio to attendee count.

# Attendee experience.

* Pre-class: install prereqs.
* Start Lab.
* Provision environment on AWS. (or provided by PL.)
    * PL-pre-provisioned, gain access via emailed IP address & password: 5m
    * or self-provisioned environment : 30m
* SSH to Ubuntu environment: 5-15m
* Start daemons using helper script. :10m
* View test data. 
* Run ```singularity prepare``` test data into CARs. :10m
* View CAR files.
* Run ```singularity replicate``` :10m
    * Online deals or miner import deals.
    * Legacy lotus (MVP)
* Await deal sealing ```lotus-miner storage-deals list --watch"  :20m
    * Classroom presentation section, Q&A, break, while waiting.
* Setup Singularity index. :10m
* Retrieval using ```fil-ls``` ```fil-cp``` command aliases. :10m
* Feeback form: 2m

Estimated time: 2hr

# Presentation material:

* Review of Filecoin :15m
* Positioning of onboarding paths: Singularity PiB scale, Estuary, Web3.storage, Chainsafe. :10m
* Overview of data onboarding process :20m
* Overview of lab :10m
* Overview of retrieval, position singularity indexing and retrieval:10m

Estimated time: 1hr

# Benefits:

* Demystify the large data onboarding and retrieval process. 
* Repeatable class that SPs and onboarders can replicate for their clients.
* Tailored for Archival use-cases.
* Lab environment can be re-purposed for actual POC use.

# Risks:

* Set clear expectation about slow sealing rate of small devnet miner.
* CLI experience.


