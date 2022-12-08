#!/bin/bash
# Run as root.
# E.g. via nohup or tmux:
#         ./lotus-init-devnet.sh full_rebuild_test > ./full_rebuild_test.out 2>&1 &
# Build Lotus devnet from source, configure, run devnet
# Based on: 
# https://lotus.filecoin.io/lotus/install/linux/#building-from-source

. "$ROOT_SCRIPT_PATH/lotus/setup-common.sh" # import common functions.

function _prep_test_data() {
    # Generate test data
    _echo "Generating test data..."
    export DATASET_NAME=`uuidgen | cut -d'-' -f1`
    echo "export DATASET_NAME=$DATASET_NAME" >> $TEST_CONFIG_FILE

    rm -rf $CAR_DIR && mkdir -p $CAR_DIR
    rm -rf $DATASET_PATH && mkdir -p $DATASET_PATH
    dd if=/dev/urandom of="$DATASET_PATH/$DATASET_NAME.dat" bs=1024 count=1 iflag=fullblock
    export SINGULARITY_CMD="singularity prep create $DATASET_NAME $DATASET_PATH $CAR_DIR"
    _echo "Preparing data via command: $SINGULARITY_CMD"
    $SINGULARITY_CMD
    _echo "Awaiting prep completion."
    sleep 5
    PREP_STATUS="blank"
    MAX_SLEEP_SECS=10
    while [[ "$PREP_STATUS" != "completed" && $MAX_SLEEP_SECS -ge 0 ]]; do
        MAX_SLEEP_SECS=$(( $MAX_SLEEP_SECS - 1 ))
        if [ $MAX_SLEEP_SECS -eq 0 ]; then _error "Timeout waiting for prep success status."; fi
        sleep 1
        PREP_STATUS=`singularity prep status --json $DATASET_NAME | jq -r '.generationRequests[].status'`
        _echo "PREP_STATUS: $PREP_STATUS"
    done

    export DATA_CID=`singularity prep status --json $DATASET_NAME | jq -r '.generationRequests[].dataCid'`
    export PIECE_CID=`singularity prep status --json $DATASET_NAME | jq -r '.generationRequests[].pieceCid'`
    export CAR_FILE=`ls -tr $CAR_DIR/*.car | tail -1`
}

function client_lotus_deal() {

    _prep_test_data  # Setup DATA_CID, CAR_FILE, DATASET_NAME
    if [[ -z "$CLIENT_WALLET_ADDRESS" || -z "$DATA_CID" || -z "$CAR_FILE" || -z "$DATASET_NAME" ]]; then
        _error "CLIENT_WALLET_ADDRESS, DATA_CID, CAR_FILE, DATASET_NAME need to be defined."
    fi
    _echo "📦📦📦 Making Deals..."
    _echo "CLIENT_WALLET_ADDRESS, DATA_CID, CAR_FILE, DATASET_NAME: $CLIENT_WALLET_ADDRESS, $DATA_CID, $CAR_FILE, $DATASET_NAME"
    _echo "Importing CAR into Lotus..."
    lotus client import --car $CAR_FILE
    sleep 2

    QUERY_ASK_CMD="lotus client query-ask $MINERID"
    _echo "Executing: $QUERY_ASK_CMD"
    QUERY_ASK_OUT=$($QUERY_ASK_CMD)
    _echo "query-ask response: $QUERY_ASK_OUT"

    # E.g. Price per GiB per 30sec epoch: 0.0000000005 FIL
    PRICE=0.000000000000001
    CURRENT_EPOCH=$(lotus status | sed -n 's/^Sync Epoch: \([0-9]\+\)[^0-9]*.*/\1/p')
    SEALING_DELAY_EPOCHS=$(( 60 * 2 )) # seconds
    START_EPOCH=$(( $CURRENT_EPOCH + $SEALING_DELAY_EPOCHS ))
    DURATION_EPOCHS=$(( 180 * 2880 )) # 180 days
    _echo "CURRENT_EPOCH:$CURRENT_EPOCH; START_EPOCH (ignored TODO):$START_EPOCH; SEALING_DELAY_EPOCHS:$SEALING_DELAY_EPOCHS; DURATION_EPOCHS:$DURATION_EPOCHS"
    # TODO: tune miner config.
    #  StorageDealError when using switch: --start-epoch $START_EPOCH , possibly caused by autosealing miner config.
    DEAL_CMD="lotus client deal --from $CLIENT_WALLET_ADDRESS $DATA_CID $MINERID $PRICE $DURATION_EPOCHS"
    _echo "Client Dealing... executing: $DEAL_CMD"
    DEAL_ID=`$DEAL_CMD`
    _echo "DEAL_ID: $DEAL_ID"
    sleep 2
    lotus client list-deals --show-failed -v                                                                   
    lotus client get-deal $DEAL_ID
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

function singularity_test() { # deprecated??
    _echo "singularity_test starting..."
    . $TEST_CONFIG_FILE # set wallet addresses env variables.
    singularity prep list --json | jq -r '.[].name'
    _echo "DATASET_NAME: $DATASET_NAME"
    # or, alternately # export DATASET_NAME=`singularity prep list --json | jq -r '.[].name' | grep -v test | head -1`
    
    singularity prep status --json $DATASET_NAME
    # Wait for prep generation status to complete.
    # TODO: singularity prep generation-status ?
    singularity prep list --json | jq -r '.[] | select(.name==env.DATASET_NAME) | [ .id, .name ]'
    singularity prep list --json | jq -r '.[] | select(.name==env.DATASET_NAME) | ( .id, .name, .scanningStatus, .generationTotal, .generationCompleted )'

    _echo "Make deals to storage providers..."
    CURRENT_EPOCH=$(lotus status | sed -n 's/^Sync Epoch: \([0-9]\+\)[^0-9]*.*/\1/p')
    START_DELAY_DAYS="0.041" # ~ <60 mins.
    DURATION_DAYS=180
    echo "CURRENT_EPOCH: $CURRENT_EPOCH , START_DELAY_DAYS: $START_DELAY_DAYS , DURATION_DAYS: $DURATION_DAYS"

    # Usage: singularity replication start [options] <datasetid> <storage-providers> <client> [# of replica]
    PRICE="953" #"0.0000000005"
    # TODO troubleshoot online deals first, 
    # REPL_CMD="singularity repl start --start-delay $START_DELAY_DAYS --duration $DURATION_DAYS --max-deals 10 --verified false --price $PRICE --output-csv $SINGULARITY_OUT_CSV $DATASET_NAME $MINERID $CLIENT_WALLET_ADDRESS"
    ## troubleshooting. remove --start-delay
    REPL_CMD="singularity repl start --duration $DURATION_DAYS --max-deals 10 --verified false --price $PRICE --output-csv $SINGULARITY_OUT_CSV $DATASET_NAME $MINERID $CLIENT_WALLET_ADDRESS"
    _echo "Executing replication command: $REPL_CMD"
    $REPL_CMD

    _echo "sleeping a bit..." && sleep 30
    _echo "listing singularity replications..."
    singularity repl list
    # singularity repl status -v REPLACE_WITH_REPL_ID

    lotus-miner storage-deals list -v
    lotus-miner sectors list
    _echo "singularity_test completed."
}

function test_singularity() {
    _echo "test_singularity starting..."
    . $TEST_CONFIG_FILE
    generate_test_data
    test_singularity_prep
    test_singularity_repl
    _echo "test_singularity verify deals..."
    sleep 10
    singularity repl list
    # Singularity bug. Does not support devnet block height. (workaround in DealReplicationWorker.ts)
    # error during repl status # deal rejected: invalid deal end epoch 3882897: cannot be more than 1555200 past current epoch 1007
    # singularity repl status -v 63771015987d840fafb37afa # TODO hardcoded REPLACE_WITH_REPL_ID
    lotus client list-deals --show-failed -v  
    lotus-miner storage-deals list -v
    lotus-miner sectors list
    _echo "sleeping, for miner to receive deal..." && sleep 60
    test_miner_import_car
    _echo "sleeping, although miner has sealed the deal..." && sleep 1
    test_lotus_retrieve
    _echo "test_singularity completed."
}

function generate_test_data() {
    _echo "Generating test data for dataset: $DATASET_NAME"
    export DATASET_NAME=`uuidgen | cut -d'-' -f1`
    export DATASET_SOURCE_DIR=/tmp/source/$DATASET_NAME
    rm -rf $DATASET_SOURCE_DIR && mkdir -p $DATASET_SOURCE_DIR
    DATA_FILE="$DATASET_SOURCE_DIR/$DATASET_NAME.dat"
    dd if=/dev/urandom of="$DATA_FILE" bs=1024 count=1 iflag=fullblock
    echo "export DATASET_NAME=$DATASET_NAME" >> $TEST_CONFIG_FILE
}

function test_singularity_prep() {
    _echo "Testing singularity prep..."
    export CAR_DIR=/tmp/car/$DATASET_NAME
    DATASET_SOURCE_DIR=/tmp/source/$DATASET_NAME
    rm -rf $CAR_DIR && mkdir -p $CAR_DIR
    SINGULARITY_CMD="singularity prep create $DATASET_NAME $DATASET_SOURCE_DIR $CAR_DIR"
    _echo "Preparing test data via command: $SINGULARITY_CMD"
    $SINGULARITY_CMD
    _echo "Awaiting prep completion."
    PREP_STATUS="blank"
    MAX_SLEEP_SECS=10
    while [[ "$PREP_STATUS" != "completed" && $MAX_SLEEP_SECS -ge 0 ]]; do
        MAX_SLEEP_SECS=$(( $MAX_SLEEP_SECS - 1 ))
        if [ $MAX_SLEEP_SECS -eq 0 ]; then _error "Timeout waiting for prep completion."; fi
        sleep 1
        PREP_STATUS=`singularity prep status --json $DATASET_NAME | jq -r '.generationRequests[].status'`
    done
    export DATA_CID=`singularity prep status --json $DATASET_NAME | jq -r '.generationRequests[].dataCid'`
    echo "export DATA_CID=$DATA_CID" >> $TEST_CONFIG_FILE
    export PIECE_CID=`singularity prep status --json $DATASET_NAME | jq -r '.generationRequests[].pieceCid'`
    echo "export PIECE_CID=$PIECE_CID" >> $TEST_CONFIG_FILE
    export CAR_FILE=`ls -tr $CAR_DIR/*.car | tail -1`
    echo "export CAR_FILE=$CAR_FILE" >> $TEST_CONFIG_FILE
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
    REPL_CMD="singularity repl start --start-delay $START_DELAY_DAYS --duration $DURATION_DAYS --max-deals 10 --verified false --price $PRICE --output-csv $SINGULARITY_OUT_CSV $DATASET_NAME $MINERID $CLIENT_WALLET_ADDRESS"
    _echo "Executing replication command: $REPL_CMD" 
    $REPL_CMD
    sleep 1
    export REPL_ID=$(singularity repl list | sed -n -r 's/^│[[:space:]]+[0-9]+[[:space:]]+│[[:space:]]*'\''([^'\'']*).*/\1/p' | tail -1)
     _echo "looking up Singularity replication ID: $REPL_ID"
    REPL_STATUS_JSON=$(singularity repl status -v $REPL_ID)
    export DEAL_CID=$(echo $REPL_STATUS_JSON | jq -r '.deals[].dealCid')
    export DATA_CID=$(echo $REPL_STATUS_JSON | jq -r '.deals[].dataCid') # already set by prep stage
    export PIECE_CID=$(echo $REPL_STATUS_JSON | jq -r '.deals[].pieceCid')
    echo "export REPL_ID=$REPL_ID" >> $TEST_CONFIG_FILE
    echo "export DEAL_CID=$DEAL_CID" >> $TEST_CONFIG_FILE
    echo "export DATA_CID=$DATA_CID" >> $TEST_CONFIG_FILE
    echo "export PIECE_CID=$PIECE_CID" >> $TEST_CONFIG_FILE
}

function test_miner_import_car() {
    . $TEST_CONFIG_FILE
    export CAR_DIR=/tmp/car/$DATASET_NAME
    export CAR_FILE=`ls -tr $CAR_DIR/*.car | tail -1`
    IMPORT_CMD="lotus-miner storage-deals import-data $DEAL_CID $CAR_FILE"
    _echo "Importing car file into miner...executing: $IMPORT_CMD"
    $IMPORT_CMD
    _echo "CAR file imported. Awaiting miner sealing..."
    DEAL_STATUS="blank"
    MAX_POLL_SECS=600
    SLEEP_INTERVAL=10
    _echo "Polling $MAX_POLL_SECS seconds, for deal status to go StorageDealActive..."
    while [[ "$DEAL_STATUS" != "StorageDealActive" && $MAX_POLL_RETRY -ge 0 ]]; do
        MAX_POLL_SECS=$(( $MAX_POLL_SECS - $SLEEP_INTERVAL ))
        if [ $MAX_POLL_SECS -eq 0 ]; then _error "Timeout exceeded $MAX_POLL_SECS seconds waiting for prep deal status to go StorageDealActive."; fi
        sleep $SLEEP_INTERVAL
        DEAL_STATUS=$( lotus-miner storage-deals list -v | grep $DEAL_CID | tr -s ' ' | cut -d ' ' -f7 )
        _echo "DEAL_STATUS: $DEAL_STATUS"
    done

    LOTUS_GET_DEAL_CMD="lotus client get-deal $DEAL_CID | "
    _echo "Querying lotus client deal status. Executing: $LOTUS_GET_DEAL_CMD"
    $LOTUS_GET_DEAL_CMD # shows "OnChain", and "Log": "deal activated",

    SINGULARITY_DEAL_STATUS_MD="singularity repl status -v $REPL_ID"
    _echo "Querying singularity client deal status. Executing: $SINGULARITY_DEAL_STATUS_MD"
    $SINGULARITY_DEAL_STATUS_MD # somehow state remains in proposed... whats the refresh frequency of singularity ? retry later?
}

function test_miner_auto_import_script() {
    MARKETS_API_INFO="SETME"
    MINER_API_INFO="SETME"
    # Which utility to use?: singularity-import
    AUTO_IMPORT_SCRIPT="$HOME/singularity/scripts/auto-import.sh"
    # Example: ./auto-import.sh <car_dir_path> <verified_client_address>
    # auto-import.sh requires variables to be set.
    # Tested this is working: lotus-miner storage-deals import-data <proposal CID> <file>
    _echo "importing storage deals..."
    $AUTO_IMPORT_SCRIPT $CAR_DIR $CLIENT_WALLET_ADDRESS
}

function test_lotus_retrieve() {
    . $TEST_CONFIG_FILE
    _echo "testing lotus retrieve for DATASET_NAME: $DATASET_NAME"
    RETRIEVE_CAR_FILE="$RETRIEVE_CAR_DIR/$DATASET_NAME/retrieved.car"
    rm -rf "$RETRIEVE_CAR_DIR/$DATASET_NAME"
    mkdir -p "$RETRIEVE_CAR_DIR/$DATASET_NAME"
    lotus_retrieve $DATA_CID $RETRIEVE_CAR_FILE
    SOURCE_CAR_FILE="$CAR_DIR/$PIECE_CID.car"
    DIFF_CMD="diff $RETRIEVE_CAR_FILE $SOURCE_CAR_FILE"
    _echo "comparing retrieved against original: $DIFF_CMD" || _error "retrieved file differs from original"
    $DIFF_CMD
}

function lotus_retrieve() {
    DATA_CID=$1
    RETRIEVE_CAR_FILE=$2
    LOTUS_RETRIEVE_CMD="lotus client retrieve --car --provider $MINERID $DATA_CID $RETRIEVE_CAR_FILE"
    _echo "executing command: $LOTUS_RETRIEVE_CMD"
    $LOTUS_RETRIEVE_CMD
}

function setup_singularity_index() {
    echo noop
}

function test_singularity_retrieve() {
    echo noop
}
