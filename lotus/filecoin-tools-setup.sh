#!/bin/bash
# Run as root.
# E.g. via nohup or tmux:
#         ./lotus-init-devnet.sh full_rebuild_test > ./full_rebuild_test.out 2>&1 &
# Build Lotus devnet from source, configure, run devnet
# Based on: 
# https://lotus.filecoin.io/lotus/install/linux/#building-from-source

set -e
export LOTUS_PATH=$HOME/.lotus # $HOME/.lotusDevnetTest/
export LOTUS_MINER_PATH=$HOME/.lotusminer # $HOME/.lotusminerDevnetTest/
export LOTUS_SKIP_GENESIS_CHECK=_yes_
export CGO_CFLAGS_ALLOW="-D__BLST_PORTABLE__"
export CGO_CFLAGS="-D__BLST_PORTABLE__"
export BOOST_SOURCE_PATH=$HOME/boost/
export BOOST_PATH=$HOME/.boost
export BOOST_CLIENT_PATH=$HOME/.boost-client
ROOT_SCRIPT_PATH="$HOME/filecoin-data-onboarding-tools"
TEST_CONFIG_FILE="$ROOT_SCRIPT_PATH/lotus/test_config.gitignore"
LOTUS_MINER_CONFIG_FILE="$ROOT_SCRIPT_PATH/lotus/lotusminer-autopublish-config.toml"
LOTUS_SOURCE=$HOME/lotus/
SINGULARITY_OUT_CSV="$ROOT_SCRIPT_PATH/lotus/singularity-out.csv"
export DATASET_PATH=/tmp/source
export CAR_DIR=/tmp/car
export RETRIEVE_CAR_DIR=/tmp/car-retrieve

# set golang envars, because sourcing .bashrc appears not to work in userdata.
export GOPATH=/root/go
export GOBIN=$GOPATH/bin
export GOROOT=/usr/local/go
export PATH=$PATH:$GOPATH/bin:$GOROOT/bin
export NVM_DIR="$HOME/.nvm"
. "$NVM_DIR/nvm.sh"
. "$NVM_DIR/bash_completion"
export MINERID="t01000"

. "$ROOT_SCRIPT_PATH/lotus/filecoin-tools-common.sh" # import common functions.

. "$ROOT_SCRIPT_PATH/lotus/filecoin-tools-tests.sh" # import test functions.

function rebuild() {
    _echo "Rebuilding from source..."
    _killall_daemons

    _echo "## Installing prereqs..."
    apt install -y mesa-opencl-icd ocl-icd-opencl-dev gcc git bzr jq pkg-config curl clang build-essential hwloc libhwloc-dev wget && sudo apt upgrade -y
    curl https://sh.rustup.rs -sSf > RUSTUP.sh
    sh RUSTUP.sh -y
    rm RUSTUP.sh
    wget -c https://go.dev/dl/go1.18.4.linux-amd64.tar.gz -O - | tar -xz -C /usr/local
    echo "export PATH=$PATH:/usr/local/go/bin" >> ~/.bashrc && source ~/.bashrc
    _echo "## Building lotus..."
    cd $HOME
    rm -rf $LOTUS_PATH
    rm -rf $LOTUS_SOURCE
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
    cd $LOTUS_SOURCE && _echo "Fetching parameters..."
    time ./lotus fetch-params 2048
    _echo "Pre-seal some sectors for the genesis block..."
    time ./lotus-seed pre-seal --sector-size 2KiB --num-sectors 2
    _echo "Create the genesis block..."
    time ./lotus-seed genesis new localnet.json
    _echo "Create a default address and give it some funds..."
    time ./lotus-seed genesis add-miner localnet.json ~/.genesis-sectors/pre-seal-t01000.json
    _echo "Starting first node..."
    nohup ./lotus daemon --lotus-make-genesis=devgen.car --genesis-template=localnet.json --bootstrap=false >> /var/log/lotus-daemon.log 2>&1 &
    _echo "Awaiting daemon startup... could take awhile...."
    time _waitLotusStartup "1800s"
    _echo "Importing the genesis miner key..." 
    ./lotus wallet import --as-default ~/.genesis-sectors/pre-seal-t01000.key
    _echo "Set up the genesis miner. This process can take a few minutes..."
    time ./lotus-miner init --genesis-miner --actor=t01000 --sector-size=2KiB --pre-sealed-sectors=~/.genesis-sectors --pre-sealed-metadata=~/.genesis-sectors/pre-seal-t01000.json --nosync
    _echo "Starting the miner..."
    nohup ./lotus-miner run --nosync >> /var/log/lotus-miner.log 2>&1 &
    lotus-miner wait-api --timeout 900s
    _echo "Initializing Daemons completed."
}

function deploy_miner_config() {
    _echo "Deploying miner config..."
    cp -f $LOTUS_MINER_PATH/config.toml $LOTUS_MINER_PATH/config.toml.bak
    cp -f $LOTUS_MINER_CONFIG_FILE $LOTUS_MINER_PATH/config.toml
}

function restart_daemons() {
    _echo "restarting daemons..."
    _echo "halting any existing daemons..."
    _killall_daemons
    sleep 10
    start_daemons
    sleep 10
    _echo "daemons restarted."
}

function start_daemons() {
    _echo "Starting lotus daemons..."
    cd $LOTUS_SOURCE
    nohup lotus daemon >> /var/log/lotus-daemon.log 2>&1 &
    time _waitLotusStartup
    _echo "Lotus node started."
    nohup lotus-miner run --nosync >> /var/log/lotus-miner.log 2>&1 &
    lotus-miner wait-api --timeout 600s
    _echo "Lotus miner started."
    start_ipfs || true
    start_singularity
}

function _waitLotusStartup() {
    t=${1:-"120s"} # note trailing "s"
    _echo "## Waiting for lotus startup, timeout $t..."
    lotus wait-api --timeout $t
}

function _killall_daemons() {
    _echo "Killing all daemons..."
    lotus-miner stop || true
    lotus daemon stop || true
    stop_singularity || true
    stop_ipfs || true
}

function start_singularity() {
    _echo "Starting singularity daemon..."
    nohup singularity daemon >> /var/log/singularity.log 2>&1 &
    _echo "Awaiting singularity start..."
    timeout 1m bash -c 'until singularity prep list; do sleep 10; done'
    timeout 30s bash -c 'until singularity repl list; do sleep 10; done'
    _echo "Singularity started."
}

function stop_singularity() {
    _echo "stopping singularity..."
    pkill -f 'node.*singularity' || true
    pkill -f '.*mongod-x64-ubuntu' || true
    sleep 1
}

function setup_ipfs() {
    _echo "setting up IPFS..."
    wget https://dist.ipfs.tech/kubo/v0.17.0/kubo_v0.17.0_linux-amd64.tar.gz
    tar -xvzf kubo_v0.17.0_linux-amd64.tar.gz
    cd kubo
    bash install.sh
    ipfs --version
    ipfs init --profile server
    ipfs config --json Swarm.ResourceMgr.Limits.System.FD: 8192
}

function start_ipfs() {
    _echo "starting IPFS..."
    nohup ipfs daemon >> /var/log/ipfs.log 2>&1 &
    _echo "IPFS started."
}

function stop_ipfs() {
    _echo "stopping IPFS..."
    ipfs shutdown
    _echo "IPFS stopped."
}

# Setup SP_WALLET_ADDRESS, CLIENT_WALLET_ADDRESS
function setup_wallets() {
    _echo "Setting up wallets..."
    lotus wallet list
    SP_WALLET_ADDRESS=`lotus wallet list | grep "^.*X" | grep -oE "^\w*\b"` # default wallet
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
    rm $TEST_CONFIG_FILE || true
    echo "export SP_WALLET_ADDRESS=$SP_WALLET_ADDRESS" >> $TEST_CONFIG_FILE
    echo "export CLIENT_WALLET_ADDRESS=$CLIENT_WALLET_ADDRESS" >> $TEST_CONFIG_FILE

    _echo "Sending funds into client lotus wallet..."
    lotus send --from "$SP_WALLET_ADDRESS" "$CLIENT_WALLET_ADDRESS" 10000000
    sleep 2
    CLIENT_WALLET_BALANCE=`lotus wallet balance "$CLIENT_WALLET_ADDRESS" | cut -d' ' -f1`
    _echo "client lotus wallet address: $CLIENT_WALLET_ADDRESS, balance: $CLIENT_WALLET_BALANCE"
}

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

function install_singularity() {
    rm -rf $HOME/singularity
    rm -rf $HOME/.singularity
    _echo "## cloning singularity repo..."
    cd $HOME
    git clone https://github.com/tech-greedy/singularity.git
    _echo "## deploying hacky patch to DealReplicationWorker.ts for devnet blockheight."
    cp -f filecoin-data-onboarding-tools/singularity/DealReplicationWorker.ts singularity/src/replication/DealReplicationWorker.ts
    _echo "## building singularity..."
    cd singularity
    npm ci
    npm run build
    npm link
    npx singularity -h
    _echo "Installing go-generate-car dependency..."
    cd $HOME
    rm -rf go-generate-car
    git clone https://github.com/tech-greedy/go-generate-car.git
    cd go-generate-car
    make
    mv -f ./generate-car /root/singularity/node_modules/.bin
}

function init_singularity() {
    stop_singularity
    sleep 2
    rm -rf $HOME/.singularity

    echo "Initializing Singularity..."
    singularity init
    ls $HOME/.singularity
    echo "Setting up config for deal prep only."
    cp $HOME/.singularity/default.toml $HOME/.singularity/default.toml.orig
    cp $HOME/filecoin-data-onboarding-tools/singularity/my-singularity-config.toml $HOME/.singularity/default.toml
    echo "Starting singularity daemon..."
    nohup singularity daemon 2>&1 >> /var/log/singularity.log &
    echo "Started singularity daemon."

    # Wait for singularity daemon startup.
    sleep 10 && singularity prep list

    # Generate test data
    echo "Preparing test data..."
    OUT_DIR=/tmp/car
    DATASET_NAME="verify-test"
    rm -rf $DATASET_PATH && mkdir -p $DATASET_PATH
    rm -rf $OUT_DIR && mkdir -p $OUT_DIR
    cp -r /root/singularity $DATASET_PATH

    # Run data prep test
    _echo "Running singularity install verification test..."
    export SINGULARITY_CMD="singularity prep create $DATASET_NAME $DATASET_PATH $OUT_DIR"
    _echo "executing command: $SINGULARITY_CMD"
    $SINGULARITY_CMD

    # Await prep completion
    _echo "awaiting prep status completion."
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

    # Verify test result
    export EXPECTED_CAR_COUNT=1
    _echo "Verifying test output..."
    _echo "listing of $OUT_DIR: "`ls -lh $OUT_DIR`
    _echo "size of $OUT_DIR: "`du -sh $OUT_DIR`
    export ACTUAL_CAR_COUNT=`find $OUT_DIR -type f | wc -l`
    _echo "count of regular files in $OUT_DIR: $ACTUAL_CAR_COUNT"
    if [ $ACTUAL_CAR_COUNT -ne $EXPECTED_CAR_COUNT ]; then _error "unexpected count of files: $ACTUAL_CAR_COUNT -ne $EXPECTED_CAR_COUNT"; fi
    _echo "Singularity test completed."
}

function full_rebuild_test() {
    install_singularity
    init_singularity

    setup_ipfs
    start_ipfs
    rebuild
    init_daemons && sleep 10

    _killall_daemons && sleep 2
    deploy_miner_config
    restart_daemons && sleep 2

    setup_wallets && sleep 5

    _echo "lotus-miner storage-deals and sectors..."
    lotus-miner storage-deals list -v
    lotus-miner sectors list

    client_lotus_deal && sleep 5   # Legacy deals.

    _echo "lotus-miner storage-deals and sectors..."
    lotus-miner storage-deals list -v
    lotus-miner sectors list

    # Wait some time for deal to seal and appear onchain.
    SEAL_SLEEP_SECS=$(( 60*2 )) # 2 mins
    _echo "📦 sleeping $SEAL_SLEEP_SECS secs for sealing..." && sleep $SEAL_SLEEP_SECS

    _echo "lotus-miner storage-deals and sectors..."
    lotus-miner storage-deals list -v
    lotus-miner sectors list

    _echo "📦 retrieving CID: $DATA_CID" && retrieve_wait "$DATA_CID"
    # compare source file with retrieved file.
    _echo "comparing source file with retrieved file."
    diff -r /tmp/source `pwd`/retrieved.car.gitignore && _echo "comparison succeeded."

    # singularity_test
    test_singularity
}

# Entry point.
function run() {
    full_rebuild_test
}

# Execute function from parameters
$@
_echo "Lotus Linux devnet test completed: $0"
