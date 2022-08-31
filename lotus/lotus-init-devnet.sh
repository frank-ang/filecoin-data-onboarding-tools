#!/bin/bash
# Run as root.
# Build Lotus devnet from source, configure, run devnet
# Based on: 
# https://lotus.filecoin.io/lotus/install/linux/#building-from-source

set -e
export LOTUS_PATH=$HOME/.lotusDevnetTest/
export LOTUS_MINER_PATH=$HOME/.lotusminerDevnetTest/
export LOTUS_SKIP_GENESIS_CHECK=_yes_
export CGO_CFLAGS_ALLOW="-D__BLST_PORTABLE__"
export CGO_CFLAGS="-D__BLST_PORTABLE__"

LOTUS_SOURCE=$HOME/lotus/
LOTUS_DAEMON_LOG=${LOTUS_SOURCE}lotus-daemon.log
LOTUS_MINER_LOG=${LOTUS_SOURCE}lotus-miner.log

function _echo() {
    echo `date -u +"%Y-%m-%dT%H:%M:%SZ"`"##:$1"
}

function _error() {
    _echo "ERROR: $1"
    exit 1
}

function _waitLotusStartup() {
    echo "## Waiting for lotus startup..."
    lotus wait-api --timeout 60s
    lotus status || _error "timeout waiting for lotus startup."
}

function _killall_daemons() {
    lotus-miner stop || true
    lotus daemon stop || true
    #killall lotus-miner || true
    #killall lotus || true
}


function rebuild() {
    _echo "Rebuilding from source..."
    _killall_daemons

    _echo "## Installing prereqs..."
    apt install mesa-opencl-icd ocl-icd-opencl-dev gcc git bzr jq pkg-config curl clang build-essential hwloc libhwloc-dev wget -y && sudo apt upgrade -y

    _echo "## Installing rust..."
    curl https://sh.rustup.rs -sSf > RUSTUP.sh
    sh RUSTUP.sh -y
    rm RUSTUP.sh

    _echo "## Installing golang..."
    wget -c https://go.dev/dl/go1.18.4.linux-amd64.tar.gz -O - | tar -xz -C /usr/local
    echo "export PATH=$PATH:/usr/local/go/bin" >> ~/.bashrc && source ~/.bashrc

    _echo "## Building lotus..."
    cd $HOME
    rm -rf $HOME/.lotus
    rm -rf $HOME/lotus
    git clone https://github.com/filecoin-project/lotus.git
    cd lotus/
    git checkout releases

    make clean
    time make 2k
    date -u
    _echo "## Installing lotus..."
    make install
    date -u
}


function init_daemons() {
    _echo "Initializing Daemons..."
    _killall_daemons
    rm -rf $LOTUS_PATH
    rm -rf $LOTUS_MINER_PATH
    rm -rf ~/.genesis-sectors
    cd $LOTUS_SOURCE && _echo "Fetching parameters..." #
    time ./lotus fetch-params 2048
    _echo "Pre-seal some sectors for the genesis block..."
    time ./lotus-seed pre-seal --sector-size 2KiB --num-sectors 2
    _echo "Create the genesis block..."
    time ./lotus-seed genesis new localnet.json
    _echo "Create a default address and give it some funds..."
    time ./lotus-seed genesis add-miner localnet.json ~/.genesis-sectors/pre-seal-t01000.json
    _echo "Starting first node..."
    nohup ./lotus daemon --lotus-make-genesis=devgen.car --genesis-template=localnet.json --bootstrap=false >> lotus-daemon.log 2>&1 &
    _echo "Awaiting daemon startup..."
    time _waitLotusStartup
    _echo "Importing the genesis miner key..." 
    ./lotus wallet import --as-default ~/.genesis-sectors/pre-seal-t01000.key
    _echo "Set up the genesis miner. This process can take a few minutes..."
    time ./lotus-miner init --genesis-miner --actor=t01000 --sector-size=2KiB --pre-sealed-sectors=~/.genesis-sectors --pre-sealed-metadata=~/.genesis-sectors/pre-seal-t01000.json --nosync
    _echo "Starting the miner..."
    nohup ./lotus-miner run --nosync >> lotus-miner.log 2>&1 &
}

function restart_daemons() {
    _echo "restarting daemons..."
    _echo "halting any existing daemons..."
    _killall_daemons
    sleep 2
    start_daemons
    _echo "daemons restarted."
}

function start_daemons() {
    _echo "Starting daemons..."
    cd $LOTUS_SOURCE
    nohup ./lotus daemon >> lotus-daemon.log 2>&1 &
    time _waitLotusStartup
    nohup ./lotus-miner run --nosync >> lotus-miner.log 2>&1 &
    _echo "Daemons started."
}

function setup_wallets() {
    _echo "Setting up wallets..."
    lotus wallet list
    SP_WALLET_ADDRESS=`lotus wallet list | tail -1 | cut -d' ' -f1`
    _echo "SP lotus wallet address: $SP_WALLET_ADDRESS"
    CLIENT_WALLET_ADDRESS=`lotus wallet list | tail -2 | head -1 | cut -d' ' -f1`
    if [[ "$CLIENT_WALLET_ADDRESS" == "Address" ]]; then
        _echo "No client wallet found. Creating new wallet..."
        lotus wallet new
    else
        _echo "Found pre-existing client wallet."
    fi
    CLIENT_WALLET_ADDRESS=`lotus wallet list | tail -2 | head -1 | cut -d' ' -f1`
    _echo "client lotus wallet address: $CLIENT_WALLET_ADDRESS"

    _echo "Sending funds into client lotus wallet..."
    lotus send --from "$SP_WALLET_ADDRESS" "$CLIENT_WALLET_ADDRESS" 1000
    sleep 2
    CLIENT_WALLET_BALANCE=`lotus wallet balance "$CLIENT_WALLET_ADDRESS" | cut -d' ' -f1`
    _echo "client lotus wallet address: $CLIENT_WALLET_ADDRESS, balance: $CLIENT_WALLET_BALANCE"
}

function _prep_test_data() {
    # Generate test data
    _echo "Preparing test data..."
    export DATASET_PATH=/tmp/source
    export CAR_DIR=/tmp/car
    export DATASET_NAME=`uuidgen | cut -d'-' -f1`
    rm -rf $CAR_DIR && mkdir -p $CAR_DIR
    rm -rf $DATASET_PATH && mkdir -p $DATASET_PATH
    dd if=/dev/urandom of="$DATASET_PATH/$DATASET_NAME.dat" bs=1024 count=1 iflag=fullblock

    # Run data prep test
    echo "Running test..."
    export SINGULARITY_CMD="singularity prep create $DATASET_NAME $DATASET_PATH $CAR_DIR"
    echo "executing command: $SINGULARITY_CMD"
    $SINGULARITY_CMD

    # Await prep completion
    echo "awaiting prep status completion."
    sleep 5
    PREP_STATUS="blank"
    MAX_SLEEP_SECS=10
    while [[ "$PREP_STATUS" != "completed" && $MAX_SLEEP_SECS -ge 0 ]]; do
        MAX_SLEEP_SECS=$(( $MAX_SLEEP_SECS - 1 ))
        if [ $MAX_SLEEP_SECS -eq 0 ]; then _error "Timeout waiting for prep success status."; fi
        sleep 1
        PREP_STATUS=`singularity prep status --json $DATASET_NAME | jq -r '.generationRequests[].status'`
        echo "PREP_STATUS: $PREP_STATUS"
    done

    export DATA_CID=`singularity prep status --json $DATASET_NAME | jq -r '.generationRequests[].dataCid'`
    export PIECE_CID=`singularity prep status --json $DATASET_NAME | jq -r '.generationRequests[].pieceCid'`
    export CAR_FILE=`ls -tr $CAR_DIR/*.car | tail -1`

}

function client_lotus_deal() {

    _prep_test_data
    _echo "CLIENT_WALLET_ADDRESS, DATA_CID, CAR_FILE, DATASET_NAME: $CLIENT_WALLET_ADDRESS, $DATA_CID, $CAR_FILE, $DATASET_NAME"

    if [[ -z "$CLIENT_WALLET_ADDRESS" || -z "$DATA_CID" || -z "$CAR_FILE" || -z "$DATASET_NAME" ]]; then
        _error "CLIENT_WALLET_ADDRESS, DATA_CID, CAR_FILE, DATASET_NAME need to be defined."
    fi

    _echo "CLIENT_WALLET_ADDRESS, DATA_CID, CAR_FILE, DATASET_NAME: $CLIENT_WALLET_ADDRESS, $DATA_CID, $CAR_FILE, $DATASET_NAME"
    
    _echo "Importing CAR into Lotus..."
    lotus client import --car $CAR_FILE
    sleep 2

    export MINERID="t01000"

    QUERY_ASK_CMD="lotus client query-ask $MINERID"
    _echo "Executing: $QUERY_ASK_CMD"
    QUERY_ASK_OUT=$($QUERY_ASK_CMD)
    _echo "ask output: $QUERY_ASK_OUT"

    # E.g. Price per GiB: 0.0000000005 FIL, per epoch (30sec) 
    #      FIL/Epoch for 0.000002 GiB (2KB) : 
    PRICE=0.000000000000001
    DURATION=518400 # 180 days

    _echo "Client Dealing... "
    DEAL_CMD="lotus client deal --from $CLIENT_WALLET_ADDRESS $DATA_CID $MINERID $PRICE $DURATION"
    _echo "Executing: $DEAL_CMD"
    DEAL_ID=`$DEAL_CMD`
    _echo "DEAL_ID: $DEAL_ID"

    sleep 2
    lotus client list-deals --show-failed -v                                                                   
    lotus client get-deal $DEAL_ID
}

function miner_handle_deal() { # TODO TEST

    _echo "Miner handling deal..."
    lotus-miner storage-deals list -v # dealID shows as StorageDealPublish
    _echo "lotus-miner storage-deals pending-publish --publish-now ... "
    lotus-miner storage-deals pending-publish  # dealID should be queued for publish
    lotus-miner storage-deals pending-publish --publish-now

    sleep 5

    lotus-miner sectors list # sector in SubmitPreCommitBatch
    # TODO get sector number, waiting in precommit batch queue
    SECTOR_NUMBER=`lotus-miner sectors batching precommit`
    _echo "SECTOR_NUMBER in precommit batch queue: $SECTOR_NUMBER"
    lotus-miner sectors status $SECTOR_NUMBER | grep 'Status:' | sed 's/Status:[[:space:]]*\(.*\)/\1/g'

    _echo "lotus-miner sectors batching precommit --publish-now..."
    lotus-miner sectors batching precommit --publish-now

    # sector state progresses thru PreCommitBatchWait, WaitSeed, Committing, SubmitCommitAggregate
    sleep 5
    lotus-miner sectors list
    sleep 2
    lotus-miner sectors batching commit # should show sector number.
    sleep 3
    _echo "lotus-miner sectors batching commit --publish-now..."
    lotus-miner sectors batching commit --publish-now
    sleep 3
    lotus-miner sectors list # sector should move thru CommitAggregateWait, PrecommitWait, WaitSeed, CommitWait, Proving, FinalizeSector
    sleep 5

    # successful deal should be in StorageDealActive.  
    lotus-miner storage-deals list -v | grep $DEAL_ID
    lotus-miner storage-deals list --format json | jq '.'
    # Moves into Proving stage, requires WindowPOST.
    lotus client list-deals # still shows StorageDealCheckForAcceptance, Not on-chain.
}


function retrieve() { # TODO TEST
    CID=$1
    if [[ -z "$CID" ]]; then
        _echo "CID undefined." 1>&2
        exit 1
    fi
    # following line throws error: ERR t01000@12D3KooW9sKNwEP2x5rKZojgFstGihzgGxjFNj3ukcWTVHgMh9Sm: exhausted 5 attempts but failed to open stream, err: peer:12D3KooW9sKNwEP2x5rKZojgFstGihzgGxjFNj3ukcWTVHgMh9Sm: resource limit exceeded
    # lotus client find $CID
    lotus client retrieve --provider t01000 $CID `pwd`/retrieved.car.gitignore
    lotus client retrieve --provider t01000 --car `pwd`/$CID retrieved-car.out
}


if [[ -z "$HOME" ]]; then
    echo "HOME undefined." 1>&2
    exit 1
fi

cd $HOME

#_killall_daemons
#rebuild
#init_daemons && sleep 10
#restart_daemons

setup_wallets && sleep 5

client_lotus_deal

#client_lotus_deal && sleep 5
#miner_handle_deal

echo "## Lotus devnet test completed."
