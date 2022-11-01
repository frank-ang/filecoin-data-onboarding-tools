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
TEST_CONFIG_FILE=`pwd`"/test_config.gitignore"
LOTUS_MINER_CONFIG_FILE=`pwd`"/lotusminer-autopublish-config.toml"
LOTUS_SOURCE=$HOME/lotus/
LOTUS_DAEMON_LOG=${LOTUS_SOURCE}lotus-daemon.log
LOTUS_MINER_LOG=${LOTUS_SOURCE}lotus-miner.log

if [[ -z "$HOME" ]]; then
    echo "HOME undefined." 1>&2
    exit 1
fi
cd $HOME

function _echo() {
    echo `date -u +"%Y-%m-%dT%H:%M:%SZ"`"##:$1"
}

function _error() {
    _echo "ERROR: $1"
    exit 1
}

function _waitLotusStartup() {
    t=${1:-"120s"} # note trailing "s"
    echo "## Waiting for lotus startup, timeout $t..."
    lotus wait-api --timeout $t
    # redundant # lotus status || _error "timeout waiting for lotus startup."
}

function _killall_daemons() {
    lotus-miner stop || true
    lotus daemon stop || true
    stop_singularity || true
}


function rebuild() {
    _echo "Rebuilding from source..."
    _killall_daemons

    _echo "## Installing prereqs..."
    apt install -y mesa-opencl-icd ocl-icd-opencl-dev gcc git bzr jq pkg-config curl clang build-essential hwloc libhwloc-dev wget && sudo apt upgrade -y

    _echo "## Installing rust..."
    curl https://sh.rustup.rs -sSf > RUSTUP.sh
    sh RUSTUP.sh -y
    rm RUSTUP.sh

    _echo "## Installing golang..."
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
}


function deploy_miner_config() {
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
    nohup lotus-miner run --nosync >> /var/log/lotus-miner.log 2>&1 &
    lotus-miner wait-api --timeout 600s
    _echo "Lotus Daemons started."
    start_singularity
}

function start_boost() {
    boostd --vv run
}


function start_singularity() {
    _echo "Starting singularity daemon..."
    nohup singularity daemon 2>&1 >> /var/log/singularity.log &
    sleep 5 && singularity prep list
    _echo "Singularity started."
}

function stop_singularity() {
    pkill -f 'node.*singularity'
}

function docker_boost_setup() {
    _echo "Installing prereqs for Docker."
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
    apt install -y apt-transport-https ca-certificates curl gnupg-agent software-properties-common
    # Ignoring failure: E: The repository 'https://download.docker.com/linux/ubuntu \ Release' does not have a Release file.
    add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu/ $(lsb_release -cs) stable" || true
    apt update
    apt install -y docker-ce docker-ce-cli containerd.io
    which docker
    mkdir -p $HOME/.docker/cli-plugins/
    curl -SL https://github.com/docker/compose/releases/download/v2.3.3/docker-compose-linux-x86_64 -o ~/.docker/cli-plugins/docker-compose
    chmod +x ~/.docker/cli-plugins/docker-compose
    docker compose version
}

function docker_boost_build() {
    _echo "Building docker images. Please be patient...  fresh docker build could exceed 45 mins."
    cd $BOOST_SOURCE_PATH
    export DOCKER_DEFAULT_PLATFORM=linux/amd64 # if building on Mac.
    time make docker/all # Macbook Apple Silicon: 46m / EC2 r2.xlarge: 14m
    _echo "Available images: " && docker images | grep filecoin
}

function docker_boost_run() {
    _echo "Starting boost docker devnet..."
    cd $BOOST_SOURCE_PATH/docker/devnet
    docker compose up -d
}


function docker_trace() {
    cd $BOOST_SOURCE_PATH/docker/devnet
    docker compose logs -f
}

function docker_stop() {
    _echo "Stopping devnet..."
    cd $BOOST_SOURCE_PATH/docker/devnet
    docker compose down --rmi local
    rm -rf ./data
    rm -rf /var/tmp/filecoin-proof-parameters
    # docker system prune
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

    _prep_test_data  # Setup DATA_CID, CAR_FILE, DATASET_NAME
    if [[ -z "$CLIENT_WALLET_ADDRESS" || -z "$DATA_CID" || -z "$CAR_FILE" || -z "$DATASET_NAME" ]]; then
        _error "CLIENT_WALLET_ADDRESS, DATA_CID, CAR_FILE, DATASET_NAME need to be defined."
    fi
    _echo "📦📦📦 Making Deals..."
    _echo "CLIENT_WALLET_ADDRESS, DATA_CID, CAR_FILE, DATASET_NAME: $CLIENT_WALLET_ADDRESS, $DATA_CID, $CAR_FILE, $DATASET_NAME"
    _echo "Importing CAR into Lotus..."
    lotus client import --car $CAR_FILE
    sleep 2

    export MINERID="t01000"

    QUERY_ASK_CMD="lotus client query-ask $MINERID"
    _echo "Executing: $QUERY_ASK_CMD"
    QUERY_ASK_OUT=$($QUERY_ASK_CMD)
    _echo "query-ask response: $QUERY_ASK_OUT"

    # E.g. Price per GiB: 0.0000000005 FIL, per epoch (30sec) 
    #      FIL/Epoch for 0.000002 GiB (2KB) : 
    PRICE=0.000000000000001
    DURATION=518400 # 180 days

    DEAL_CMD="lotus client deal --from $CLIENT_WALLET_ADDRESS $DATA_CID $MINERID $PRICE $DURATION"
    _echo "Client Dealing... executing: $DEAL_CMD"
    DEAL_ID=`$DEAL_CMD`
    _echo "DEAL_ID: $DEAL_ID"
    sleep 2
    lotus client list-deals --show-failed -v                                                                   
    lotus client get-deal $DEAL_ID
}

function retrieve() { # TODO TEST
    CID=$1
    if [[ -z "$CID" ]]; then
        _echo "CID undefined." 1>&2
        exit 1
    fi
    # following line throws error: ERR t01000@12D3KooW9sKNwEP2x5rKZojgFstGihzgGxjFNj3ukcWTVHgMh9Sm: exhausted 5 attempts but failed to open stream, err: peer:12D3KooW9sKNwEP2x5rKZojgFstGihzgGxjFNj3ukcWTVHgMh9Sm: resource limit exceeded
    # lotus client find $CID
    rm -rf `pwd`/retrieved-out.gitignore || true
    rm -f `pwd`/retrieved-car.gitignore || true
    lotus client retrieve --provider t01000 $CID `pwd`/retrieved.car.gitignore
    lotus client retrieve --provider t01000 --car `pwd`/$CID retrieved-car.out
}

function retrieve_wait() {
    CID=$1
    RETRY_COUNT=20
    until retrieve $CID; do
        RETRY_COUNT=$((RETRY_COUNT-1))
        if [[ "$RETRY_COUNT" < 1 ]]; then _error "Exhausted retries"; fi
        _echo "RETRY_COUNT: $RETRY_COUNT"
        sleep 10
    done
}

function full_rebuild_test() {
    rebuild
    init_daemons && sleep 10

    _killall_daemons && sleep 2
    deploy_miner_config
    restart_daemons && sleep 2

    setup_wallets && sleep 5
    client_lotus_deal && sleep 5   # Legacy deals.

    # Wait 24hrs for deal to seal and appear onchain.
    _echo "📦 sleeping 24hrs..." && sleep $(( 60*60*24 ))

    _echo "📦 retrieving CID: $DATA_CID" && retrieve_wait "$DATA_CID"

    # Note: Skip Boost. Problems with Boost on mac/linux/docker.
    # build_boost
    # config_boost
}

function build_boost() {
    _echo "📦 building boost... 📦 "
    cd $HOME
    rm -rf boost || true
    git clone https://github.com/filecoin-project/boost
    cd boost
    git pull
    make clean
    # make build # mainnet
    make debug # devnet
    sudo make install
}

function config_boost() {
    _echo "📦 Configuring boost... 📦"

    mv -f $BOOST_PATH $BOOST_PATH.bak || true

    if grep "PUBLISH_STORAGE_DEALS_WALLET" "$TEST_CONFIG_FILE"; then
        _echo "reusing PUBLISH_STORAGE_DEALS_WALLET from $TEST_CONFIG_FILE"
        . "$TEST_CONFIG_FILE"
    else
        PUBLISH_STORAGE_DEALS_WALLET=`lotus wallet new bls`
        COLLAT_WALLET=`lotus wallet new bls`
        _echo "PUBLISH_STORAGE_DEALS_WALLET: $PUBLISH_STORAGE_DEALS_WALLET"
        _echo "COLLAT_WALLET: $COLLAT_WALLET"
        echo "export PUBLISH_STORAGE_DEALS_WALLET=$PUBLISH_STORAGE_DEALS_WALLET" >> $TEST_CONFIG_FILE
        echo "export COLLAT_WALLET=$COLLAT_WALLET" >> $TEST_CONFIG_FILE
        lotus send --from $SP_WALLET_ADDRESS $PUBLISH_STORAGE_DEALS_WALLET 10
        lotus send --from $SP_WALLET_ADDRESS $COLLAT_WALLET 10
        sleep 15 # takes some time... actor not found, requires chain sync so the new wallet addresses can be found.
        _echo "PUBLISH_STORAGE_DEALS_WALLET balance: "`lotus wallet balance $PUBLISH_STORAGE_DEALS_WALLET`
        _echo "COLLAT_WALLET balance: "`lotus wallet balance $COLLAT_WALLET`
    fi

    _echo "Setting the publish storage deals wallet as a control wallet..."
    OLD_CONTROL_ADDRESS=`lotus-miner actor control list  --verbose | awk '{print $3}' | grep -v key | tr -s '\n'  ' '`
    lotus-miner actor control set --really-do-it $PUBLISH_STORAGE_DEALS_WALLET $OLD_CONTROL_ADDRESS

    export $(lotus auth api-info --perm=admin) #FULLNODE_API_INFO
    export $(lotus-miner auth api-info --perm=admin) #MINER_API_INFO
    export APISEALER=`lotus-miner auth api-info --perm=admin` 
    export APISECTORINDEX=`lotus-miner auth api-info --perm=admin` 
    ulimit -n 1048576

    _echo "shutting down lotus-miner..."
    lotus-miner stop || true
    sleep 5

    _echo "Backup the lotus-miner repository..."
    cp -rf "$LOTUS_MINER_PATH" "${LOTUS_MINER_PATH%/}.bak"
    # Backup the lotus-miner datastore (in case you decide to roll back from Boost to Lotus) with: lotus-shed market export-datastore --repo <repo> --backup-dir <backup-dir>

    # migrate lotus-markets
    export $(lotus auth api-info --perm=admin) # FULLNODE_API_INFO
    _echo "Migrating monolithic lotus-miner to boost"
    MIGRATE_CMD="boostd --vv migrate-monolith \
       --import-miner-repo="$LOTUS_MINER_PATH" \
       --api-sealer=$APISEALER \
       --api-sector-index=$APISECTORINDEX \
       --wallet-publish-storage-deals=$PUBLISH_STORAGE_DEALS_WALLET \
       --wallet-deal-collateral=$COLLAT_WALLET \
       --max-staging-deals-bytes=50000000000" # Maybe add --nosync flag??
    _echo "Executing: $MIGRATE_CMD"
    # Keeps looping "Checking full node sync status", until manual interrupt Ctrl-C SIGINT to continue. 
    timeout -s SIGINT 10 $MIGRATE_CMD 

    _echo "Updating lotus-miner config to disable markets"
    cp "$LOTUS_MINER_PATH""config.toml" "$LOTUS_MINER_PATH""config.toml.backup"
    sed -i 's/^[ ]*#[ ]*EnableMarkets = .*/EnableMarkets = false/' "$LOTUS_MINER_PATH""config.toml"

    _echo "Starting lotus-miner..."
    nohup lotus-miner run --nosync >> /var/log/lotus-miner.log 2>&1 &
    lotus-miner wait-api --timeout 300s

    _echo "Starting boost..."
    # Observation: 1st time running this manually, instantiates new boost node, 
    nohup boostd --vv run --nosync >> /var/log/boostd.log 2>&1 &
}

function setup_boost_ui() {
    _echo "📦 Setting up Boost UI 📦"
    cd $BOOST_SOURCE_PATH/react
    npm install --legacy-peer-deps
    npm run build
    npm install -g serve
    nohup serve -s build >> /var/log/boost-ui.log 2>&1 &
    # Browser Access: http://localhost:8080 , via SSH tunnel ssh -L 8080:localhost:8080 myserver
    # API Access: requires BOOST_API_INFO environment variable
    # Demonstration of API Access
    sleep 2
    export $(boostd auth api-info -perm admin)
    curl -s -X POST -H "Content-Type: application/json" -d '{"query":"query {epoch { Epoch }}"}' http://localhost:8080/graphql/query 
}

function setup_boost_client() {
    _echo "📦 Setting up Boost Client 📦"
    rm -rf $BOOST_CLIENT_PATH.bak && mv -f $BOOST_CLIENT_PATH $BOOST_CLIENT_PATH.bak || true
    export $(lotus auth api-info --perm=admin) # FULLNODE_API_INFO
    boost -vv init
    sleep 15
    fund_boost_client_wallet
}

function fund_boost_client_wallet() {
    export $(lotus auth api-info --perm=admin) # FULLNODE_API_INFO
    _echo "Funding Boost Client wallet..."
    SP_WALLET_ADDRESS=`lotus wallet list | grep "^.*X" | grep -oE "^\w*\b"` # default wallet
    export BOOST_CLIENT_WALLET=`boost wallet list | grep -o 'f3.[^\S]*' | tr -d '\n'`
    _echo "SP_WALLET_ADDRESS: $SP_WALLET_ADDRESS"
    _echo "BOOST_CLIENT_WALLET: $BOOST_CLIENT_WALLET" # TODO its a mainnet f3, not a t3 address.
    _echo "Adding funds to BOOST_CLIENT_WALLET: $BOOST_CLIENT_WALLET from SP_WALLET_ADDRESS: $SP_WALLET_ADDRESS"
    lotus send --from "$SP_WALLET_ADDRESS" "$BOOST_CLIENT_WALLET" 10
    _echo "Adding funds to market actor..."
    boostx market-add 1
}

function boost_devnet() {
    echo "setting up boost_devnet..."
    rm -rf ~/.lotusmarkets ~/.lotus ~/.lotusminer ~/.genesis_sectors
    rm -rf ~/.boost
    rm -rf $LOTUS_PATH $LOTUS_MINER_PATH $BOOST_PATH $BOOST_CLIENT_PATH
    cd $LOTUS_SOURCE
    git checkout releases
    make debug
    sudo make install
    install -C ./lotus-seed /usr/local/bin/lotus-seed
    # TODO WIP
    _error "TODO incomplete"
}

function wait_complete_TODO() {
    cd $BOOST_SOURCE_PATH/docker/devnet
    docker compose exec boost /bin/bash
}

function do_docker() {
    rebuild
    build_boost
    docker_boost_setup
    docker_boost_build
    docker_boost_run
}

function run() {
    full_rebuild_test
}

# Execute function from parameters
$@

_echo "Lotus Linux devnet test completed: $0"
