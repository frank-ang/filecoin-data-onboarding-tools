#!/bin/bash

. $(dirname $(realpath $0))"/filecoin-tools-common.sh"
BOOST_ENV_FILE=$(dirname $(realpath $0))"/boost.env"
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
    # now deal stuck in Status	"Sealer: WaitDeals",
    # TODO
    # Option 1: autopublish config.toml for miner,
    #    but devnet.go will edit the config.toml changes... parallel sed replace may cause race condition?
    # Option 2: "manually use CLI to babysit the deal forward"
    #    lotus-miner sectors seal [command options] <sectorNum>
    # lets try option 2 manually first. Use the default devnet miner settings.
    # ...
    babysit_deal_sealing
}

function babysit_deal_sealing() {
    # push the sector thru sealing.
    lotus-miner sectors list
    SECTOR_ID="INVALID"
    NUM_REGEX='^[0-9]+$'
    TIMEOUT=60
    SLEEP_INTERVAL_SECS=5
    if ! [[ "$SECTOR_ID" =~ $NUM_REGEX ]] && [ "$TIMEOUT" -ge 0 ]; then
        SECTOR_ID=$(lotus-miner sectors list | grep WaitDeals | tail -1 | awk '{print $1}' )
        _echo "SECTOR_ID: $SECTOR_ID , TIMEOUT: $TIMEOUT"
        TIMEOUT=$(( TIMEOUT - $SLEEP_INTERVAL_SECS))
        [ "$TIMEOUT" -lt 0 ] && _error "Timed out waiting for a sector with state: WaitDeals"
        sleep $SLEEP_INTERVAL_SECS
    fi
    _echo "Sector ID in WaitDeals state: $SECTOR_ID"

    # sector stuck in "WaitDeals", lets force it to seal:
    [[ -z "$SECTOR_ID" ]] && { _error "SECTOR_ID is required"; }
    lotus-miner sectors seal $SECTOR_ID
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
    # Sector status should move to PrecommitWait -> WaitSeed, CommitWait, Proving -> FinalizeSector
}

function test_boost_retrieval() {
    _echo "TODO test_boost_retrieval..."
}

######## main sequence #######

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
    test_boost_deal # runtime duration approx: 8m39s (2022-12-30)
    # TODO verify deal
}
