#!/bin/bash
# Run as root. Execute from filecoin-tools-setup.sh instead of this script directly.
# To execute a full install and test. Recommend run headless via nohup or tmux.

export DATA_SOURCE_ROOT=/tmp/source
export DATA_CAR_ROOT=/tmp/car
export CAR_RETRIEVE_ROOT=/tmp/car-retrieve
export RETRIEVE_ROOT=/tmp/retrieve
export SINGULARITY_CSV_ROOT=/tmp/singularity-csv
TARGET_DEAL_SIZE="2KiB" # devnet. For prod use: "32GiB"

. $(dirname $(realpath $0))"/filecoin-tools-common.sh" # import common functions.
GEN_TEST_DATA_SCRIPT=$(dirname $(realpath $0))"/gen-test-data.sh"
MINER_IMPORT_SCRIPT=$(dirname $(realpath $0))"/miner-import-car.sh"


# Creates test data files with pattern: $DATA_SOURCE_ROOT/$DATASET_NAME/file-$FILE_COUNT
# generates and sets a random DATASET_NAME
# Params: FILE_COUNT, FILE_SIZE
function generate_test_files() {
    FILE_COUNT=${1:-1}
    FILE_SIZE=${2:-1024}
    DIRNAME=${3:-"$DATA_SOURCE_ROOT"}
    export DATASET_NAME=`uuidgen | cut -d'-' -f1`
    DATASET_SOURCE_DIR=$DIRNAME/$DATASET_NAME
    rm -rf $DATASET_SOURCE_DIR && mkdir -p $DATASET_SOURCE_DIR
    PREFIX="file"
    _echo "Generating test files for dataset: $DATASET_NAME, Files: $FILE_COUNT, Size: $FILE_SIZE, output:$DATASET_SOURCE_DIR, prefix: $PREFIX"
    [[ -z "$FILE_COUNT" ]] && { _error "generate_test_files FILE_COUNT is required"; }
    [[ -z "$FILE_SIZE" ]] && { _error "generate_test_files FILE_SIZE bytes is required"; }
    [[ -z "$PREFIX" ]] && { _error "generate_test_files PREFIX is required" ; }
    [[ -z "$DATASET_SOURCE_DIR" ]] && { _error "generate_test_files DATASET_SOURCE_DIR is required" ; }
    mkdir -p "$DATASET_SOURCE_DIR"
    while [[ "$FILE_COUNT" -gt 0 ]]; do
        BLOCK_SIZE=1 # $(( $FILE_SIZE < 1024 ? 1 : 1024 ))
        COUNT_BLOCKS=$(( $FILE_SIZE/$BLOCK_SIZE ))
        CMD="dd if=/dev/urandom of="$DATASET_SOURCE_DIR/$PREFIX-$FILE_COUNT" bs=$BLOCK_SIZE count=$COUNT_BLOCKS iflag=fullblock"
        _echo "executing: $CMD"
        $CMD
        ((FILE_COUNT--))
    done
    _echo "Test files created into $DATASET_SOURCE_DIR"
    echo "export DATASET_NAME=$DATASET_NAME" >> $TEST_CONFIG_FILE
}


function test_singularity_prep() {
    _echo "Testing singularity prep for multiple car..."
    DATASET_SOURCE_DIR=$DATA_SOURCE_ROOT/$DATASET_NAME
    DATASET_CAR_ROOT=$DATA_CAR_ROOT/$DATASET_NAME
    rm -rf $DATASET_CAR_ROOT && mkdir -p $DATASET_CAR_ROOT
    MAX_RATIO="0.80"
    SINGULARITY_CMD="singularity prep create --deal-size $TARGET_DEAL_SIZE --max-ratio $MAX_RATIO $DATASET_NAME $DATASET_SOURCE_DIR $DATASET_CAR_ROOT"
    _echo "Preparing test data via command: $SINGULARITY_CMD"
    $SINGULARITY_CMD
    _echo "Awaiting prep completion." && sleep 2
    PREP_STATUS="blank"
    MAX_SLEEP_SECS=240
    while [[ "$PREP_STATUS" != "completed" && $MAX_SLEEP_SECS -ge 0 ]]; do
        MAX_SLEEP_SECS=$(( $MAX_SLEEP_SECS - 1 ))
        if [ $MAX_SLEEP_SECS -eq 0 ]; then _error "Timeout waiting for prep completion."; fi
        sleep 1
        PREP_STATUS_LIST=`singularity prep status --json $DATASET_NAME | jq -r '.generationRequests[].status'`
        for p in $PREP_STATUS; do if [[ "$p" != "completed" ]]; then echo "Prep status: $p"; break; fi; done
        PREP_STATUS="completed"
    done
    # TODO following variables to fix and handle multi-val.
    sleep 1
    CAR_COUNT=`ls $DATASET_CAR_ROOT/*car | wc -l`
    ls $DATASET_CAR_ROOT/*car
    _echo "CAR_COUNT: $CAR_COUNT"
    export DATASET_ID=`singularity prep status --json $DATASET_NAME | jq -r '.id'`
    echo "export DATASET_ID=$DATASET_ID" >> $TEST_CONFIG_FILE
    export DATA_CID=`singularity prep status --json $DATASET_NAME | jq -r '.generationRequests[].dataCid' | tail -1` # TODO handle multi-value
    echo "export DATA_CID=$DATA_CID" >> $TEST_CONFIG_FILE
    export PIECE_CID=`singularity prep status --json $DATASET_NAME | jq -r '.generationRequests[].pieceCid' | tail -1` # TODO handle multi-value
    echo "export PIECE_CID=$PIECE_CID" >> $TEST_CONFIG_FILE
    export CAR_FILE=`ls -tr $DATASET_CAR_ROOT/*.car | tail -1` # TODO handle multi-val
    echo "export CAR_FILE=$CAR_FILE" >> $TEST_CONFIG_FILE
}


function test_singularity_repl() {
    _echo "Testing singularity replicate with multi car..."
    DATASET_CAR_ROOT=$DATA_CAR_ROOT/$DATASET_NAME
    _echo "## importing car files into lotus from directory: $DATASET_CAR_ROOT"
    ls $DATASET_CAR_ROOT
    for CAR_FILE in $( ls $DATASET_CAR_ROOT/*.car ); do
        echo "CAR_FILE: $CAR_FILE"
        LOTUS_CLIENT_IMPORT_CAR_CMD="lotus client import --car $CAR_FILE"
        _echo "Executing command: $LOTUS_CLIENT_IMPORT_CAR_CMD"
        $LOTUS_CLIENT_IMPORT_CAR_CMD
    done
    unset FULLNODE_API_INFO
    CURRENT_EPOCH=$(lotus status | sed -n 's/^Sync Epoch: \([0-9]\+\)[^0-9]*.*/\1/p')
    START_DELAY_DAYS=$(( $CURRENT_EPOCH / 2880 + 1 )) # 1 day floor.
    _echo "CURRENT_EPOCH: $CURRENT_EPOCH , START_DELAY_DAYS: $START_DELAY_DAYS"
    DURATION_DAYS=180
    PRICE="953" # TODO hardcoded magic number
    CSV_DIR="$SINGULARITY_CSV_ROOT/$DATASET_NAME"
    REPL_CMD_IMMEDIATE_DEPRECATED="singularity repl start --start-delay $START_DELAY_DAYS --duration $DURATION_DAYS \
        --max-deals 10 --verified false --price $PRICE --output-csv $CSV_DIR $DATASET_NAME $MINERID $CLIENT_WALLET_ADDRESS"
    # i.e. send max-deals each cron period, max total cron-max-deals, with cron-max-pending-deals total pending.
    set -x
    singularity repl start --max-deals 2 --cron-schedule '*/2 * * * *' --cron-max-deals 200 --cron-max-pending-deals 2 \
                        --start-delay $START_DELAY_DAYS --duration $DURATION_DAYS --verified false --price $PRICE \
                        --output-csv $CSV_DIR $DATASET_NAME $MINERID $CLIENT_WALLET_ADDRESS  # TODO set CLIENT_WALLET_ADDRESS for boost.
    set +x
    sleep 1
    export REPL_ID=$(singularity repl list | grep $DATASET_ID | sed -n -r 's/^│[[:space:]]+[0-9]+[[:space:]]+│[[:space:]]*'\''([^'\'']*).*/\1/p')
    _echo "Singularity replication ID: $REPL_ID , for dataset ID: $DATASET_ID"
    REPL_STATUS_JSON=$(singularity repl status -v $REPL_ID)
    echo "export REPL_ID=$REPL_ID" >> $TEST_CONFIG_FILE
    _echo "replication status: $REPL_STATUS_JSON"
}


function wait_singularity_manifest() {
    echo "waiting for manifest csv file at: $SINGULARITY_CSV_ROOT/$DATASET_NAME"
    MAX_POLL_SECS=1200
    CUR_SECS=0
    SLEEP_INTERVAL=20
    while [[ $CUR_SECS -le $MAX_POLL_SECS ]]; do
        if ls $SINGULARITY_CSV_ROOT/$DATASET_NAME/*.csv; then break; fi
        sleep $SLEEP_INTERVAL
        CUR_SECS=$((CUR_SECS+SLEEP_INTERVAL))
    done
    if [[ $CUR_SECS -ge $MAX_POLL_SECS ]]; then
        _error "timeout while waiting for Singularity CSV manifest."
    fi
    _echo "found singularity manifest file: "`ls $SINGULARITY_CSV_ROOT/$DATASET_NAME/*.csv`
}


function wait_miner_receive_all_deals() {
    _echo "Waiting for miner to receive all deals. please be patient."
    MANIFEST_CSV_FILENAME=$(ls $SINGULARITY_CSV_ROOT/$DATASET_NAME/*.csv | tail -1 )
    {
        read
        while IFS=, read -r miner_id deal_cid filename data_cid piece_cid start_epoch full_url
        do
            wait_miner_receive_deal $deal_cid
        done
    } < $MANIFEST_CSV_FILENAME
    _echo "all deals received."
}

function wait_miner_receive_deal() {
    DEAL_CID=$1
    [[ -z "$DEAL_CID" ]] && { echo "DEAL_CID is required"; exit 1; }
    DEAL_STATUS="invalid"
    MAX_POLL_SECS=600
    SLEEP_INTERVAL=10
    _echo "Waiting for miner to receive deal: $DEAL_CID"
    while [[ "$DEAL_STATUS" != "StorageDealWaitingForData" && $MAX_POLL_RETRY -ge 0 ]]; do
        MAX_POLL_SECS=$(( $MAX_POLL_SECS - $SLEEP_INTERVAL ))
        if [ $MAX_POLL_SECS -eq 0 ]; then _error "Timeout exceeded waiting for miner to receive deal: $DEAL_CID."; fi
        DEAL_STATUS=$( lotus-miner storage-deals list -v | grep $DEAL_CID | tr -s ' ' | cut -d ' ' -f7 )
        _echo "Deal:$DEAL_CID , status:$DEAL_STATUS"
        if [[ "$DEAL_STATUS" == "StorageDealWaitingForData" || "$DEAL_STATUS" == "StorageDealActive" ]]; then break; fi
        sleep $SLEEP_INTERVAL
    done
}


function test_miner_import() {
    . $TEST_CONFIG_FILE
    CSV_PATH=$(realpath $SINGULARITY_CSV_ROOT/$DATASET_NAME/*.csv | head -1 ) # TODO handle >1 csv files?
    CMD="$MINER_IMPORT_SCRIPT $CSV_PATH /tmp/car/$DATASET_NAME"
    _echo "[importing]: $CMD" 
    $CMD
    _echo "CAR files imported into miner."
}


function wait_seal_all_deals() {
    _echo "waiting for deals to seal on miner."
    _echo "to watch sealing live, you can run in another console: lotus-miner storage-deals list --watch"
    MANIFEST_CSV_FILENAME=$(ls $SINGULARITY_CSV_ROOT/$DATASET_NAME/*.csv | tail -1 )
    {
        read
        while IFS=, read -r miner_id deal_cid filename data_cid piece_cid start_epoch full_url
        do
            wait_seal_deal $deal_cid
        done
    } < $MANIFEST_CSV_FILENAME
    _echo "all deals sealed."
}

function wait_seal_deal() {
    DEAL_CID=$1
    [[ -z "$DEAL_CID" ]] && { echo "DEAL_CID is required"; exit 1; }
    DEAL_STATUS="invalid"
    MAX_POLL_SECS=1200
    SLEEP_INTERVAL=20
    _echo "Waiting for sealing of deal: $DEAL_CID"
    while [[ "$DEAL_STATUS" != "StorageDealActive" && $MAX_POLL_RETRY -ge 0 ]]; do
        MAX_POLL_SECS=$(( $MAX_POLL_SECS - $SLEEP_INTERVAL ))
        if [ $MAX_POLL_SECS -eq 0 ]; then _error "Timeout exceeded $MAX_POLL_SECS seconds waiting for prep deal status to go StorageDealActive."; fi
        DEAL_STATUS=$( lotus-miner storage-deals list -v | grep $DEAL_CID | tr -s ' ' | cut -d ' ' -f7 )
        _echo "deal:$DEAL_CID , status:$DEAL_STATUS"
        if [ "$DEAL_STATUS" == "StorageDealActive" ]; then _echo "Sealed deal: $DEAL_CID" && break; fi
        sleep $SLEEP_INTERVAL
    done
}


function setup_singularity_index() {
    INDEX_MAX_LINKS=1000
    INDEX_MAX_NODES=100
    INDEX_CREATE_CMD="singularity index create --max-links $INDEX_MAX_LINKS --max-nodes $INDEX_MAX_NODES $DATASET_NAME"
    _echo "Setting up Singularity index. Executing: $INDEX_CREATE_CMD"
    INDEX_CREATE_CMD_OUT=$($INDEX_CREATE_CMD)
    _echo "Index create output: $INDEX_CREATE_CMD_OUT"
    #export DNSLINK_TXT_RECORD=$(echo $INDEX_CREATE_CMD_OUT | sed -n -r 's/^.+("dnslink=.*$)/\1/p' | tr -d '"')
    #echo "DNSLink TXT record to be updated into DNS: $DNSLINK_TXT_RECORD"
    export INDEX_ROOT_IPFS=$(echo $INDEX_CREATE_CMD_OUT | sed -n -r 's/^.+"dnslink=(.*$)/\1/p' | tr -d '"')
    _echo "INDEX_ROOT_IPFS=$INDEX_ROOT_IPFS"
    echo "export INDEX_ROOT_IPFS=$INDEX_ROOT_IPFS" >> $TEST_CONFIG_FILE
}

function update_dns_txt_record_route53() {
    # Turns out we can simply use the IPFS INDEX CID as root, instead of messing with DNSLINK or EC2 instance IAM permissions.
    DNSLINK_TXT_RECORD="dnslink=$INDEX_ROOT_IPFS"
    RRSET_JSON_FILE_TEMPLATE="$ROOT_SCRIPT_PATH/aws/dnslink_txt_record.template.json"
    RRSET_JSON_FILE="$ROOT_SCRIPT_PATH/aws/dnslink_txt_record.json.gitignore"
    DOMAIN_NAME="frankang.com." # TODO Set this in a config file.
    TXT_RECORD_NAME="_dnslink.$DOMAIN_NAME"
    HOSTED_ZONE_ID=`aws route53 list-hosted-zones | jq -r ".HostedZones[] | select(.Name==\"$DOMAIN_NAME\") | .Id"`
    _echo "domain name: $DOMAIN_NAME , hosted zone id: $HOSTED_ZONE_ID"
    DNSLINK_TXT_RECORD_OLD=$(aws route53 list-resource-record-sets --hosted-zone-id $HOSTED_ZONE_ID | jq -r ".ResourceRecordSets[] | select(.Name == \"$TXT_RECORD_NAME\") | .ResourceRecords[].Value")
    _echo "Current DNSLink TXT record: $DNSLINK_TXT_RECORD_OLD"
    _echo "Setting route53 update file with new DNSLINK TXT record: $DNSLINK_TXT_RECORD"
    cp -f $RRSET_JSON_FILE_TEMPLATE $RRSET_JSON_FILE
    sed -i -e "s/DOMAIN_NAME_REPLACE_ME/$TXT_RECORD_NAME/g" $RRSET_JSON_FILE
    sed -i -e "s|DNSLINK_TXT_RECORD_REPLACE_ME|$DNSLINK_TXT_RECORD|g" $RRSET_JSON_FILE
    ROUTE53_UPDATE_CMD="aws route53 change-resource-record-sets --hosted-zone-id $HOSTED_ZONE_ID --change-batch file://$RRSET_JSON_FILE"
    cat $RRSET_JSON_FILE
    _echo "Upserting DNSLink record on Route53, command: $ROUTE53_UPDATE_CMD" 
    $ROUTE53_UPDATE_CMD
    QUERY_DNS_TXT_RECORD_CMD="dig +short TXT $TXT_RECORD_NAME"
    _echo "DNS should update after TTL expiry. You can verify with command: $QUERY_DNS_TXT_RECORD_CMD"
}


function test_singularity_retrieve() {
    #update_dns_txt_record_route53
    FILENAME="file-1" # Hardcoded for test
    RETRIEVE_FILE_PATH=$RETRIEVE_ROOT/$DATASET_NAME
    rm -rf $RETRIEVE_ROOT/$DATASET_NAME && mkdir -p $RETRIEVE_ROOT/$DATASET_NAME
    _exec "singularity-retrieve ls -v singularity:/$INDEX_ROOT_IPFS/"
    _exec "singularity-retrieve ls -v singularity:/$INDEX_ROOT_IPFS/$FILENAME"
    _exec "singularity-retrieve cp -p $MINERID singularity:/$INDEX_ROOT_IPFS/$FILENAME $RETRIEVE_FILE_PATH/"
    DIFF_CMD="diff $RETRIEVE_FILE_PATH/$FILENAME $DATA_SOURCE_ROOT/$DATASET_NAME/$FILENAME"
    _echo "Comparing retrieved against original. Command: $DIFF_CMD"
    $DIFF_CMD || _error "retrieved file differs from original"
    _echo "test_singularity_retrieve successful"
}

function retrieve_wait() {
    CID=$1
    RETRY_COUNT=60
    until retrieve $CID; do
        RETRY_COUNT=$((RETRY_COUNT-1))
        if [[ "$RETRY_COUNT" < 1 ]]; then _error "Exhausted retries"; fi
        _echo "RETRY_COUNT: $RETRY_COUNT"
        sleep 60
    done
}

function retrieve() {
    CID=$1
    if [[ -z "$CID" ]]; then
        _echo "CID undefined." 1>&2
        exit 1
    fi
    _echo "Retrieving CID: $CID"
    rm -rf `pwd`/retrieved-out.gitignore || true
    lotus client retrieve --provider t01000 $CID `pwd`/retrieved.car.gitignore
}


function reset_test_data() {
    rm -rf $DATA_SOURCE_ROOT/*
    rm -rf $DATA_CAR_ROOT/*
    rm -rf $CAR_RETRIEVE_ROOT/*
}

function dump_deal_info() {
    singularity repl list
    singularity repl status -v $REPL_ID
    lotus client list-deals --show-failed -v
    lotus-miner storage-deals list -v
    lotus-miner sectors list
}


function test_singularity() {
    _echo "test_singularity starting..."
    . $TEST_CONFIG_FILE
    reset_test_data
    generate_test_files "10" "1024" # "10" "1" ok # "5" "512" failed? # generate_test_files "1" "1024"
    test_singularity_prep
    test_singularity_repl
    wait_singularity_manifest
    wait_miner_receive_all_deals
    test_miner_import
    wait_seal_all_deals
    sleep 1
    setup_singularity_index
    retry 5 test_singularity_retrieve
    _echo "test_singularity completed."
}


function exercise_singularity_api_wip() {
    . $TEST_CONFIG_FILE
    set -x
    curl http://localhost:7001/preparations | jq
    curl http://localhost:7004/replications | jq
    curl http://localhost:7004/replications | jq '.[] | select(.id == "'$REPL_ID'")'
    #  jq -r ".ResourceRecordSets[] | select(.Name == \"$TXT_RECORD_NAME\") | .ResourceRecords[].Value")
    curl http://localhost:7004/replication/:$REPL_ID | jq '.'

    set +x
}