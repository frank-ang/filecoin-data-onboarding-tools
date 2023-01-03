#!/bin/bash

. $(dirname $(realpath $0))"/filecoin-tools-common.sh"
BOOST_ENV_FILE=$TEST_CONFIG_FILE  # deprecated, lets use one single config file. Was: $(dirname $(realpath $0))"/boost.env"
BOOST_IMPORT_SCRIPT=$(dirname $(realpath $0))"/boost-import-car.sh"
ulimit -n 1048576
PROJECT_HOME=$HOME
BOOST_PATH=$HOME/.boost

function build_lotus_devnet_for_boost() {
    _echo "Rebuilding lotus devnet for boost..."
    stop_daemons
    rm -rf ~/.lotusmarkets ~/.lotus ~/.lotusminer ~/.genesis_sectors ~/.genesis-sectors
    _echo "Installing prereqs..."
    apt install -y mesa-opencl-icd ocl-icd-opencl-dev gcc git bzr jq pkg-config curl clang build-essential hwloc libhwloc-dev wget && sudo apt upgrade -y
    curl https://sh.rustup.rs -sSf > RUSTUP.sh
    sh RUSTUP.sh -y
    rm RUSTUP.sh
    wget -c https://go.dev/dl/go1.18.4.linux-amd64.tar.gz -O - | tar -xz -C /usr/local
    echo "export PATH=$PATH:/usr/local/go/bin" >> ~/.bashrc && source ~/.bashrc
    _echo "Building lotus..."
    cd $HOME
    rm -rf lotus
    git clone https://github.com/filecoin-project/lotus.git
    cd $PROJECT_HOME/lotus
    git fetch --all
    git checkout tags/v1.18.0 # match the version in Boost's go.mod
    make clean
    make debug
    make install
    sudo install -C ./lotus-seed /usr/local/bin/lotus-seed
    sleep 1
    _echo "Lotus installed complete. Lotus version: "
    lotus --version
}

function clone_boost_repo() {
    rm -rf ~/.lotusmarkets ~/.lotus ~/.lotusminer ~/.genesis_sectors ~/.genesis-sectors
    rm -rf $BOOST_PATH
    cd $PROJECT_HOME
    rm -rf $PROJECT_HOME/boost
    git clone https://github.com/filecoin-project/boost
    cd ./boost
}

function build_boost_devnet() {
    rm -f $BOOST_ENV_FILE
    rm -rf $BOOST_PATH
    cd $PROJECT_HOME/boost/
    make react
    make debug
    sudo make install
    boost --version
}

function start_boost_devnet() {
    # The following command will use the binaries built, and will run lotus, lotus-miner and lotus-seed. 
    # The lotus version must match the version in Boost's go.mod.
    # takes about 10mins, devnet calls lotus fetch-params
    cd $HOME/boost
    nohup ./devnet >> devnet.log 2>&1 &
}

function wait_boost_miner_up() {
    unset MINER_API_INFO
    unset FULLNODE_API_INFO
    lotus-miner wait-api --timeout 1200s
    retry 20 lotus-miner auth api-info --perm=admin
}

function get_miner_auth_tokens() {
    export ENV_MINER_API_INFO=`lotus-miner auth api-info --perm=admin`
    export ENV_FULLNODE_API_INFO=`lotus auth api-info --perm=admin`
    export MINER_API_INFO=`echo $ENV_MINER_API_INFO | awk '{split($0,a,"="); print a[2]}'`
    export FULLNODE_API_INFO=`echo $ENV_FULLNODE_API_INFO | awk '{split($0,a,"="); print a[2]}'`
    echo MINER_API_INFO=$MINER_API_INFO
    echo FULLNODE_API_INFO=$FULLNODE_API_INFO
    echo "export MINER_API_INFO=$MINER_API_INFO" >> $BOOST_ENV_FILE
    echo "export FULLNODE_API_INFO=$FULLNODE_API_INFO" >> $BOOST_ENV_FILE
}

function create_boost_wallets() {
    _echo "creating boost wallets"
    export LOTUS_WALLET=`lotus wallet list | tail +2 | tail -1 | awk '{print $1}'`
    [[ -z "$LOTUS_WALLET" ]] && { _error "lotus wallet not defined"; }
    export COLLAT_WALLET=`lotus wallet new bls`
    export PUBMSG_WALLET=`lotus wallet new bls`
    export CLIENT_WALLET=`lotus wallet new bls`
    echo "export LOTUS_WALLET=$LOTUS_WALLET" >> $BOOST_ENV_FILE
    echo "export COLLAT_WALLET=$COLLAT_WALLET" >> $BOOST_ENV_FILE
    echo "export PUBMSG_WALLET=$PUBMSG_WALLET" >> $BOOST_ENV_FILE
    echo "export CLIENT_WALLET=$CLIENT_WALLET" >> $BOOST_ENV_FILE
}

function add_funds_boost_wallets() {
    _echo "adding funds to boost wallets.."
    lotus send --from $LOTUS_WALLET $COLLAT_WALLET 999
    lotus send --from $LOTUS_WALLET $PUBMSG_WALLET 888
    lotus send --from $LOTUS_WALLET $CLIENT_WALLET 777
    sleep 20 # some time for wallet funds to appear on chain.
    retry 10 lotus-miner actor control set --really-do-it $PUBMSG_WALLET
    retry 5 lotus wallet market add --from $LOTUS_WALLET --address $CLIENT_WALLET 666
    retry 5 lotus wallet market add --from $LOTUS_WALLET --address $COLLAT_WALLET 555
    _echo "listing wallets:... "
    lotus wallet list
    _echo "default wallet, before setting control address:"`lotus wallet default` || true
    until lotus-miner actor control set --really-do-it ${PUBMSG_WALLET}; do echo Waiting for storage miner API ready ...; sleep 1; done
    _echo "default wallet, after setting control address:"`lotus wallet default`
    lotus wallet default
}

function init_boost_repo() {
    _echo "Init boost on first run ..."
    boostd -vv init \
    --api-sealer=$MINER_API_INFO \
    --api-sector-index=$MINER_API_INFO \
    --wallet-publish-storage-deals=$PUBMSG_WALLET \
    --wallet-deal-collateral=$COLLAT_WALLET \
    --max-staging-deals-bytes=2000000000
    _echo "Setting port in boost config..."
	sed -i 's|ip4/0.0.0.0/tcp/0|ip4/0.0.0.0/tcp/50000|g' $HOME/.boost/config.toml
}

function setup_maddr() {

    if [ ! -f $BOOST_PATH/.register.boost ]; then
        echo "Temporary starting boost to get maddr..."
        
        boostd -vv run &> $BOOST_PATH/boostd.log &
        BOOST_PID=`echo $!`
        echo Got boost PID = $BOOST_PID

        until cat $BOOST_PATH/boostd.log | grep maddr; do echo "Waiting for boost..."; sleep 1; done
        echo Looks like boost started and initialized...
        
        echo Registering to lotus-miner...
        MADDR=`cat $BOOST_PATH/boostd.log | grep maddr | cut -f3 -d"{" | cut -f1 -d:`
        echo Got maddr=${MADDR}
        
        lotus-miner actor set-peer-id ${MADDR}
        # lotus-miner actor set-addrs /dns/boost/tcp/50000
        lotus-miner actor set-addrs /ip4/127.0.0.1/tcp/50000
        echo Registered

        touch $BOOST_PATH/.register.boost
        echo "Trying to stop boost..."
        kill -15 $BOOST_PID || kill -9 $BOOST_PID
        rm -f $BOOST_PATH/boostd.log
        echo "Boostd is now configured!"
    fi
}

function start_boostd() {
    echo "Starting boost in dev mode..."
    nohup boostd -vv run >> $HOME/boost/boostd.log 2>&1 &
    retry 10 verify_boost_install
}

function fund_wallets() {
    _echo "funding wallets..."
    cd $HOME/boost
    [[ -z "$FULLNODE_API_INFO" ]] && { _error "FULLNODE_API_INFO is required"; }
    export BOOST_INIT_CLIENT_WALLET=`boost wallet default`
    echo "export BOOST_INIT_CLIENT_WALLET=$BOOST_INIT_CLIENT_WALLET" >> $BOOST_ENV_FILE
    echo "export CLIENT_WALLET_ADDRESS=$BOOST_INIT_CLIENT_WALLET" >> $BOOST_ENV_FILE # wallet variable used by Singularity test
    _echo "funding boost client wallet: $BOOST_INIT_CLIENT_WALLET"
    lotus send --from $LOTUS_WALLET $BOOST_INIT_CLIENT_WALLET 21000000 && sleep 30
    retry 60 boostx market-add -y 8088
    sleep 30
    _echo "after funding, lotus wallet list: "
    lotus wallet list
    _echo "after funding, lotus wallet default: "
    lotus wallet default
}

function test_boost_deal() {
    _echo "testing boost deal..."
    cd $HOME/boost
    [[ -z "$FULLNODE_API_INFO" ]] && { _error "FULLNODE_API_INFO is required"; }
    SOURCE_PATH=$HOME/lotus/README.md
    CAR_PATH=/var/www/html/my-data.car # nginx path, hardcoded.
    PAYLOAD_CID=$(boostx generate-car $SOURCE_PATH $CAR_PATH | sed -nr 's/^Payload CID:[[:space:]]+([[:alnum:]]+)$/\1/p')
    if [ ${#PAYLOAD_CID} -lt 62 ]; then _error "Invalid Payload CID:$PAYLOAD_CID , length: ${#PAYLOAD_CID}"; fi
    CAR_HTTP_URL="http://localhost/my-data.car"
    COMMP_CID=`boostx commp $CAR_PATH 2> /dev/null | grep CID | cut -d: -f2 | xargs`
    PIECE_SIZE=`boostx commp $CAR_PATH 2> /dev/null | grep Piece | cut -d: -f2 | xargs`
    CAR_SIZE=`boostx commp $CAR_PATH 2> /dev/null | grep Car | cut -d: -f2 | xargs`
    STORAGE_PRICE=20000000000 # hardcoded, TODO set miner ask and calculate this dynamically?
    [[ -z "$COMMP_CID" ]] && { _error "COMMP_CID is required"; }
    [[ -z "$CAR_SIZE" ]] && { _error "FULLNODE_API_INFO is required"; }

    BOOST_DEAL_CMD="boost -vv deal --verified=false --provider=$MINERID \
        --http-url=$CAR_HTTP_URL --commp=$COMMP_CID --car-size=$CAR_SIZE \
        --piece-size=$PIECE_SIZE --payload-cid=$PAYLOAD_CID --storage-price $STORAGE_PRICE"
    _echo "Executing boost deal: $BOOST_DEAL_CMD"
    $BOOST_DEAL_CMD
    sleep 30
    _echo "publishing deal now..."
    curl -X POST -H "Content-Type: application/json" -d '{"query":"mutation { dealPublishNow }"}' http://localhost:8080/graphql/query | jq
    # Deal goes from AwaitPublishConfirmation -> WaitDeals, and stops there.
    # at this point, deals are stuck in Status "Sealer: WaitDeals",
    # Solutions:
    # Option 1: hot-edit config.toml before miner starts,
    #    devnet.go already edited the config. Can try a parallel sed replace, but may cause race condition?
    # Option 2: "manually use CLI to babysit the deal forward"
    #    lotus-miner sectors seal [command options] <sectorNum>
    # lets try option 2 manually first. Use the default devnet miner settings.
    # ...
    _echo "waiting for miner sector state to enter WaitDeals" && sleep 30
    babysit_deal_sealing
}

function babysit_deal_sealing() {
    # push the sector thru sealing.
    _echo "pushing the deal through. current sectors list:" && lotus-miner sectors list
    NUM_REGEX='^[0-9]+$'
    TIMEOUT=120
    SLEEP_INTERVAL_SECS=5
    until [[ "$SECTOR_ID" =~ $NUM_REGEX ]] || [ "$TIMEOUT" -le 0 ]; do
        SECTOR_ID=$(lotus-miner sectors list | grep WaitDeals | tail -1 | awk '{print $1}' )
        _echo "SECTOR_ID: $SECTOR_ID , TIMEOUT: $TIMEOUT"
        TIMEOUT=$(( TIMEOUT - $SLEEP_INTERVAL_SECS))
        [ "$TIMEOUT" -le 0 ] && _error "Timed out waiting for a sector with state: WaitDeals"
        sleep $SLEEP_INTERVAL_SECS
    done
    _echo "Sector ID in WaitDeals state: $SECTOR_ID"
    [[ -z "$SECTOR_ID" ]] && { _error "SECTOR_ID is required"; }
    lotus-miner sectors seal $SECTOR_ID # sector in state "WaitDeals", lets force it to seal.
    watch_sector_sealing $SECTOR_ID
}

function watch_sector_sealing() {
    SECTOR_ID="$1"
    [[ -z "$SECTOR_ID" ]] && { _error "SECTOR_ID is required"; }
    _echo "watching sealing for sector: $SECTOR_ID"
    STATUS=""
    TIMEOUT=600
    SLEEP_INTERVAL_SECS=5
    until [[ "$STATUS" == "Proving" ]] || [ "$TIMEOUT" -lt 0 ]; do 
        STATUS=$( lotus-miner sectors status "$SECTOR_ID" | grep Status | awk '{print $2}' )
        _echo "Sector:$SECTOR_ID status:$STATUS"
        TIMEOUT=$(( TIMEOUT - $SLEEP_INTERVAL_SECS))
        [ "$TIMEOUT" -lt 0 ] && _error "Timed out waiting for sector:$SECTOR_ID to go Proving state"
        sleep $SLEEP_INTERVAL_SECS
    done
    lotus-miner sectors list
    # Sector status moves thru Packing, PreCommit2, PrecommitWait, WaitSeed, Committing, Proving, FinalizeSector
}

function lotus_client_retrieve_car() {
    DATA_CID=$1
    RETRIEVE_CAR_FILE=$2
    [ -z "$DATA_CID" ] || [ -z "$RETRIEVE_CAR_FILE" ] || [ -z "$MINERID" ] && { echo "DATA_CID, RETRIEVE_CAR_FILE, MINERID required during retrieve"; }
    LOTUS_RETRIEVE_CMD="lotus client retrieve --car --provider $MINERID $DATA_CID $RETRIEVE_CAR_FILE"
    _echo "executing command: $LOTUS_RETRIEVE_CMD"
    $LOTUS_RETRIEVE_CMD
}

function test_lotus_client_retrieve() { # lotus retrieve may not use Singularity CSV. Lookup the car some other way? Or skip this test?
    MANIFEST_CSV_FILENAME=$(realpath $SINGULARITY_CSV_ROOT/$DATASET_NAME/*.csv | head -1 ) # TODO handle >1 csv files?
    RETRIEVE_CAR_PATH="$RETRIEVE_ROOT/$DATASET_NAME"
    [[ -z "$MANIFEST_CSV_FILENAME" ]] && { echo "MANIFEST_CSV_FILENAME is required"; exit 1; }
    [[ -z "$RETRIEVE_CAR_PATH" ]] && { echo "RETRIEVE_CAR_PATH is required"; exit 1; }
    {
        read
        while IFS=, read -r miner_id deal_cid filename data_cid piece_cid start_epoch full_url
        do 
            CMD="lotus_client_retrieve_car $deal_cid $RETRIEVE_ROOT/$DATASET_NAME/$filename"
            _echo "retrieving car, executing: $CMD"
            $CMD
        done
    } < $MANIFEST_CSV_FILENAME
}


function test_boost_import() {
    _echo "importing data into boost..."
    . $TEST_CONFIG_FILE
    CSV_PATH=$(realpath $SINGULARITY_CSV_ROOT/$DATASET_NAME/*.csv | head -1 ) # TODO handle >1 csv files?
    # boostd import-data [command options] <proposal CID> <file> or <deal UUID> <file>
    CMD="$BOOST_IMPORT_SCRIPT $CSV_PATH /tmp/car/$DATASET_NAME"
    _echo "[importing]: $CMD" 
    $CMD
    _echo "CAR files imported into boost."
}

function publish_boost_deals() {
    sleep 10
    _echo "publishing boost deals..."
    curl -X POST -H "Content-Type: application/json" -d '{"query":"mutation { dealPublishNow }"}' http://localhost:8080/graphql/query | jq
    sleep 30 # pause again ....
    # deal should now be at WaitDeals/
}

function test_singularity_boost() {
    _echo "test_singularity for boost starting..."
    . $TEST_CONFIG_FILE
    reset_test_data
    generate_test_files "1" "1024"
    test_singularity_prep
    test_singularity_repl
    wait_singularity_manifest
    sleep 30 # wait_miner_receive_all_deals # TODO poll boost. 
    test_boost_import # deal goes into state: Ready to Publish. 
    publish_boost_deals
    babysit_deal_sealing
    sleep 1
    setup_singularity_index
    retry 5 test_singularity_retrieve
    _echo "test_singularity completed."
}

function build_configure_boost_devnet() { # runtime duration: 5m1s
    clone_boost_repo
    build_boost_devnet
    start_boost_devnet
    wait_boost_miner_up
    get_miner_auth_tokens
    create_boost_wallets
    add_funds_boost_wallets
    init_boost_repo
    setup_maddr
    start_boostd
    retry 40 verify_boost_install
}

function verify_boost_install() {
    curl -s -X POST -H "Content-Type: application/json" -d '{"query":"query {epoch { Epoch }}"}' http://localhost:8080/graphql/query
    echo
    curl http://localhost:8080 | grep "Boost"
}

function setup_boost_devnet() {
    build_lotus_devnet_for_boost
    build_configure_boost_devnet
    boost init # client
    fund_wallets
    start_singularity
    sleep 10
    # try if re-introducing plain boost deal will somehow avoid miner sealing failure: WARN	sectors	pipeline/fsm.go:792	sector 1 got error event sealing.SectorCommitFailed: proof validation failed, sector not found in sector set after cron
    test_boost_deal # runtime duration approx: 8m39s (2022-12-30)
    #test_lotus_client_retrieve # broken, besides, lotus tests are too low-level.

    test_singularity_boost
}
