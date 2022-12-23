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

function test_singularity_prep_multi_car() {
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
    MAX_SLEEP_SECS=120
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

function test_singularity_prep() {
    _echo "Testing singularity prep..."
    DATASET_SOURCE_DIR=$DATA_SOURCE_ROOT/$DATASET_NAME
    DATASET_CAR_ROOT=$DATA_CAR_ROOT/$DATASET_NAME
    rm -rf $DATASET_CAR_ROOT && mkdir -p $DATASET_CAR_ROOT
    SINGULARITY_CMD="singularity prep create --deal-size $TARGET_DEAL_SIZE $DATASET_NAME $DATASET_SOURCE_DIR $DATASET_CAR_ROOT"
    _echo "Preparing test data via command: $SINGULARITY_CMD"
    $SINGULARITY_CMD
    _echo "Awaiting prep completion..." && sleep 5
    PREP_STATUS="blank"
    MAX_SLEEP_SECS=120
    while [[ "$PREP_STATUS" != "completed" && $MAX_SLEEP_SECS -ge 0 ]]; do
        MAX_SLEEP_SECS=$(( $MAX_SLEEP_SECS - 1 ))
        if [ $MAX_SLEEP_SECS -eq 0 ]; then _error "Timeout waiting for prep completion."; fi
        sleep 1
        PREP_STATUS_LIST=`singularity prep status --json $DATASET_NAME | jq -r '.generationRequests[].status'`
        for p in $PREP_STATUS; do if [[ "$p" != "completed" ]]; then echo "Prep status: $p"; break; fi; done
        PREP_STATUS="completed"
    done
    # CAR_COUNT=`ls $DATASET_CAR_ROOT/*car | wc -l` # at this point, CAR has not yet appeared in this path.
    export DATASET_ID=`singularity prep status --json $DATASET_NAME | jq -r '.id'`
    echo "export DATASET_ID=$DATASET_ID" >> $TEST_CONFIG_FILE
    export DATA_CID=`singularity prep status --json $DATASET_NAME | jq -r '.generationRequests[].dataCid' | tail -1` # TODO handle multi-value
    echo "export DATA_CID=$DATA_CID" >> $TEST_CONFIG_FILE
    export PIECE_CID=`singularity prep status --json $DATASET_NAME | jq -r '.generationRequests[].pieceCid' | tail -1` # TODO handle multi-value
    echo "export PIECE_CID=$PIECE_CID" >> $TEST_CONFIG_FILE
    export CAR_FILE=`ls -tr $DATASET_CAR_ROOT/*.car | tail -1` # TODO handle multi-val
    echo "export CAR_FILE=$CAR_FILE" >> $TEST_CONFIG_FILE
}


function test_singularity_repl_multi_car() {
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
    REPL_CMD="singularity repl start --start-delay $START_DELAY_DAYS --duration $DURATION_DAYS --max-deals 10 --verified false --price $PRICE --output-csv $CSV_DIR $DATASET_NAME $MINERID $CLIENT_WALLET_ADDRESS"
    _echo "Executing replication command: $REPL_CMD"
    $REPL_CMD
    sleep 1
    export REPL_ID=$(singularity repl list | grep $DATASET_ID | sed -n -r 's/^│[[:space:]]+[0-9]+[[:space:]]+│[[:space:]]*'\''([^'\'']*).*/\1/p')
    _echo "Singularity replication ID: $REPL_ID , for dataset ID: $DATASET_ID"
    REPL_STATUS_JSON=$(singularity repl status -v $REPL_ID)
    echo "export REPL_ID=$REPL_ID" >> $TEST_CONFIG_FILE
    _echo "REPL_STATUS_JSON: $REPL_STATUS_JSON"
    #export DEAL_CID=$(echo $REPL_STATUS_JSON | jq -r '.deals[].dealCid') # multi-value
    #echo "export DEAL_CID=$DEAL_CID" >> $TEST_CONFIG_FILE
    #export DATA_CID=$(echo $REPL_STATUS_JSON | jq -r '.deals[].dataCid') # multi-value
    #echo "export DATA_CID=$DATA_CID" >> $TEST_CONFIG_FILE
    #_echo "REPL_ID=$REPL_ID ; DEAL_CID=$DEAL_CID ; DATA_CID=$DATA_CID"
    #export PIECE_CID=$(echo $REPL_STATUS_JSON | jq -r '.deals[].pieceCid')
    # TODO: handle the case where 1 replication has many deals.
    #echo "export PIECE_CID=$PIECE_CID" >> $TEST_CONFIG_FILE
}

function test_singularity_repl() {
    _echo "Testing singularity replicate..."
    LOTUS_CLIENT_IMPORT_CAR_CMD="lotus client import --car $CAR_FILE"
    _echo "Executing command: $LOTUS_CLIENT_IMPORT_CAR_CMD"
    $LOTUS_CLIENT_IMPORT_CAR_CMD
    unset FULLNODE_API_INFO
    CURRENT_EPOCH=$(lotus status | sed -n 's/^Sync Epoch: \([0-9]\+\)[^0-9]*.*/\1/p')
    START_DELAY_DAYS=$(( $CURRENT_EPOCH / 2880 + 1 )) # 1 day floor.
    _echo "CURRENT_EPOCH: $CURRENT_EPOCH , START_DELAY_DAYS: $START_DELAY_DAYS"
    DURATION_DAYS=180
    PRICE="953"
    REPL_CMD="singularity repl start --start-delay $START_DELAY_DAYS --duration $DURATION_DAYS --max-deals 10 --verified false --price $PRICE --output-csv $SINGULARITY_CSV_ROOT/$DATASET_NAME $DATASET_NAME $MINERID $CLIENT_WALLET_ADDRESS"
    _echo "Executing replication command: $REPL_CMD" 
    $REPL_CMD
    sleep 1
    export REPL_ID=$(singularity repl list | grep $DATASET_ID | sed -n -r 's/^│[[:space:]]+[0-9]+[[:space:]]+│[[:space:]]*'\''([^'\'']*).*/\1/p')
    _echo "looking up singularity replication ID: $REPL_ID , for dataset ID: $DATASET_ID"
    REPL_STATUS_JSON=$(singularity repl status -v $REPL_ID)
    export DEAL_CID=$(echo $REPL_STATUS_JSON | jq -r '.deals[].dealCid')
    export DATA_CID=$(echo $REPL_STATUS_JSON | jq -r '.deals[].dataCid')
    export PIECE_CID=$(echo $REPL_STATUS_JSON | jq -r '.deals[].pieceCid')
    echo "export REPL_ID=$REPL_ID" >> $TEST_CONFIG_FILE
    # TODO: handle the case where 1 replication has many deals?
    echo "export DEAL_CID=$DEAL_CID" >> $TEST_CONFIG_FILE
    echo "export DATA_CID=$DATA_CID" >> $TEST_CONFIG_FILE
    echo "export PIECE_CID=$PIECE_CID" >> $TEST_CONFIG_FILE
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
    MAX_POLL_SECS=600
    SLEEP_INTERVAL=10
    _echo "Waiting for sealing of deal $DEAL_CID"
    while [[ "$DEAL_STATUS" != "StorageDealActive" && $MAX_POLL_RETRY -ge 0 ]]; do
        MAX_POLL_SECS=$(( $MAX_POLL_SECS - $SLEEP_INTERVAL ))
        if [ $MAX_POLL_SECS -eq 0 ]; then _error "Timeout exceeded $MAX_POLL_SECS seconds waiting for prep deal status to go StorageDealActive."; fi
        DEAL_STATUS=$( lotus-miner storage-deals list -v | grep $DEAL_CID | tr -s ' ' | cut -d ' ' -f7 )
        _echo "deal:$DEAL_CID , status:$DEAL_STATUS"
        if [ "$DEAL_STATUS" == "StorageDealActive" ]; then break; fi
        sleep $SLEEP_INTERVAL
    done
}


function wait_miner_receive_all_deals() {
    _echo "waiting for miner to receive all deals."
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
        if [ $MAX_POLL_SECS -eq 0 ]; then _error "Timeout exceeded $MAX_POLL_SECS seconds waiting for miner to receive deal: $DEAL_CID."; fi
        DEAL_STATUS=$( lotus-miner storage-deals list -v | grep $DEAL_CID | tr -s ' ' | cut -d ' ' -f7 )
        _echo "Deal:$DEAL_CID , status:$DEAL_STATUS"
        if [[ "$DEAL_STATUS" == "StorageDealWaitingForData" || "$DEAL_STATUS" == "StorageDealActive" ]]; then break; fi
        sleep $SLEEP_INTERVAL
    done
}

function wait_singularity_manifest() {
    echo "waiting for manifest csv file at: $SINGULARITY_CSV_ROOT/$DATASET_NAME"
    MAX_POLL_SECS=600
    CUR_SECS=0
    SLEEP_INTERVAL=10
    while [[ $CUR_SECS -le $MAX_POLL_SECS ]]; do
        if ls $SINGULARITY_CSV_ROOT/$DATASET_NAME/*.csv; then break; fi
        sleep $SLEEP_INTERVAL
        CUR_SECS=$((CUR_SECS+SLEEP_INTERVAL))
    done
}


function test_miner_import_multi_car() {
    . $TEST_CONFIG_FILE
    CSV_PATH=$(realpath $SINGULARITY_CSV_ROOT/$DATASET_NAME/*.csv | head -1 ) # TODO handle >1 csv files?
    CMD="./miner-import-car.sh $CSV_PATH /tmp/car/$DATASET_NAME"
    _echo "[importing]: $CMD" 
    $CMD
    _echo "CAR files imported into miner."
}

function test_miner_import_car() {
    . $TEST_CONFIG_FILE
    export DATA_CAR_ROOT=/tmp/car/$DATASET_NAME
    export CAR_FILE=`ls -tr $DATA_CAR_ROOT/*.car | tail -1` # TODO only handles 1 file.
    IMPORT_CMD="lotus-miner storage-deals import-data $DEAL_CID $CAR_FILE"
    _echo "Importing car file into miner...executing: $IMPORT_CMD"
    $IMPORT_CMD
    _echo "CAR file imported. Awaiting miner sealing..."
    DEAL_STATUS="blank"
    MAX_POLL_SECS=600
    SLEEP_INTERVAL=10
    _echo "Waiting for deal status to go StorageDealActive..."
    while [[ "$DEAL_STATUS" != "StorageDealActive" && $MAX_POLL_RETRY -ge 0 ]]; do
        MAX_POLL_SECS=$(( $MAX_POLL_SECS - $SLEEP_INTERVAL ))
        if [ $MAX_POLL_SECS -eq 0 ]; then _error "Timeout exceeded $MAX_POLL_SECS seconds waiting for prep deal status to go StorageDealActive."; fi
        sleep $SLEEP_INTERVAL
        DEAL_STATUS=$( lotus-miner storage-deals list -v | grep $DEAL_CID | tr -s ' ' | cut -d ' ' -f7 )
        _echo "DEAL_STATUS: $DEAL_STATUS"
    done

    #LOTUS_GET_DEAL_CMD="lotus client get-deal $DEAL_CID | "
    #_echo "Querying lotus client deal status. Executing: $LOTUS_GET_DEAL_CMD"
    #$LOTUS_GET_DEAL_CMD # shows "OnChain", and "Log": "deal activated",

    #SINGULARITY_DEAL_STATUS_MD="singularity repl status -v $REPL_ID"
    SINGULARITY_DEAL_STATUS_MD="singularity repl status -v $REPL_ID | jq  '.deals[] | ._id,.state,.errorMessage'"
    _echo "Querying singularity client deal status. Executing: $SINGULARITY_DEAL_STATUS_MD"
    $SINGULARITY_DEAL_STATUS_MD # somehow state remains in proposed... whats the refresh frequency of singularity ? retry later?
}

function test_lotus_retrieve() {
    . $TEST_CONFIG_FILE
    _echo "testing lotus retrieve for DATASET_NAME: $DATASET_NAME"
    RETRIEVE_CAR_FILE="$CAR_RETRIEVE_ROOT/$DATASET_NAME/retrieved.car"
    rm -rf "$CAR_RETRIEVE_ROOT/$DATASET_NAME"
    mkdir -p "$CAR_RETRIEVE_ROOT/$DATASET_NAME"
    lotus_retrieve $DATA_CID $RETRIEVE_CAR_FILE
    SOURCE_CAR_FILE="$DATA_CAR_ROOT/$PIECE_CID.car"
    DIFF_CMD="diff $RETRIEVE_CAR_FILE $SOURCE_CAR_FILE"
    _echo "comparing retrieved against original: $DIFF_CMD"
    $DIFF_CMD || _error "retrieved file differs from original"
}

function lotus_retrieve() {
    DATA_CID=$1
    RETRIEVE_CAR_FILE=$2
    LOTUS_RETRIEVE_CMD="lotus client retrieve --car --provider $MINERID $DATA_CID $RETRIEVE_CAR_FILE"
    _echo "executing command: $LOTUS_RETRIEVE_CMD"
    $LOTUS_RETRIEVE_CMD
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
    _echo "INDEX_ROOT_CID=$INDEX_ROOT_IPFS"
    echo "export INDEX_ROOT_CID=$INDEX_ROOT_IPFS" >> $TEST_CONFIG_FILE
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
    FILENAME="file-1" # Hardcoded
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

function test_singularity_retrieve_standalone() {
    . $TEST_CONFIG_FILE
    test_singularity_retrieve
}

function _exec() {
    CMD=$@
    _echo "executing: $CMD"
    $CMD
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
    generate_test_files "10" "1" # "5" "512" failed? # generate_test_files "1" "1024"
    test_singularity_prep_multi_car
    test_singularity_repl_multi_car
    wait_singularity_manifest
    wait_miner_receive_all_deals
    test_miner_import_multi_car
    sleep 1
    test_lotus_retrieve # car file retrieval
    setup_singularity_index
    test_singularity_retrieve
    _echo "test_singularity completed."
}


# nohup ./filecoin-tools-setup.sh mytest >> mytest.log.0 2>&1 &
function mytest() {
    . $TEST_CONFIG_FILE
    generate_test_files 3 1024
    # generate_test_files 10 1024 # FAILED. data doesn't fit in a sector, 2125 Bytes
    # generate_test_files 10 1 # small 
    test_singularity_prep_multi_car
    test_singularity_repl_multi_car
    _echo "sleeping a bit for miner to receive deals..." && sleep 31
    wait_singularity_manifest
    wait_miner_receive_all_deals
    _echo "sleeping before importing cars..." && sleep 10 # TODO what is the wait condition?
    test_miner_import_multi_car
    wait_seal_all_deals
    sleep 1
    setup_singularity_index
    test_singularity_retrieve
}
