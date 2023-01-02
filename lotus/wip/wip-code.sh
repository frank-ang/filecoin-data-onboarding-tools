# Holding area for boost scripts that may be useful later.
# currently does not work.

# --- start parking lot - problems getting boost devnet to work ---

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
    # Browser Access: http://localhost:8080 , via SSH tunnel: ssh -L 8080:localhost:8080 user@remote-host
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

function start_boost() {
    boostd --vv run
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

function do_docker() {
    rebuild
    build_boost
    docker_boost_setup
    docker_boost_build
    docker_boost_run
}
# --- end boost parking lot ---

# --- start lotus client deal parking lot ---

function _prep_test_data_lotus_deprecated() {
    _echo "_prep_test_data ..."
    rm -rf $DATA_SOURCE_ROOT && mkdir -p $DATA_SOURCE_ROOT
    rm -rf $DATA_CAR_ROOT && mkdir -p $DATA_CAR_ROOT
    generate_test_files "1" "1024" "$DATA_SOURCE_ROOT"
    SINGULARITY_CMD="singularity prep create $DATASET_NAME $DATA_SOURCE_ROOT $DATA_CAR_ROOT"
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
    export CAR_FILE=`ls -tr $DATA_CAR_ROOT/*.car | tail -1`
}

function client_lotus_deal() {

    _prep_test_data_lotus_deprecated  # Setup DATA_CID, CAR_FILE, DATASET_NAME
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

# --- end lotus client deal parking lot ---


# ----- DEPRECATED stuff here ------


function test_miner_import_car_deprecated() {
    . $TEST_CONFIG_FILE
    export DATA_CAR_ROOT=/tmp/car/$DATASET_NAME
    export CAR_FILE=`ls -tr $DATA_CAR_ROOT/*.car | tail -1` # only handles 1 file.
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
    lotus_retrieve_car $DATA_CID $RETRIEVE_CAR_FILE
    SOURCE_CAR_FILE="$DATA_CAR_ROOT/$PIECE_CID.car"
    DIFF_CMD="diff $RETRIEVE_CAR_FILE $SOURCE_CAR_FILE"
    _echo "comparing retrieved against original: $DIFF_CMD"
    $DIFF_CMD || _error "retrieved file differs from original"
}

function lotus_retrieve_car() {
    DATA_CID=$1
    RETRIEVE_CAR_FILE=$2
    LOTUS_RETRIEVE_CMD="lotus client retrieve --car --provider $MINERID $DATA_CID $RETRIEVE_CAR_FILE"
    _echo "executing command: $LOTUS_RETRIEVE_CMD"
    $LOTUS_RETRIEVE_CMD
}

function cur_block_height() {
    echo "FULLNODE_API_INFO: $FULLNODE_API_INFO"
    # lotus cli uses a pre-generated API token locally at ~/.lotus/token
    lotus auth create-token --perm read # write sign admin
    lotus auth create-token --perm write
    lotus auth create-token --perm sign
    lotus auth create-token --perm admin
    lotus auth create-token
}