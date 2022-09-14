#!/bin/bash

## build, initialize, and run lotus daemon and lotus miner.

set -e
# $HOME/.lotusDevnetTest/
# $HOME/.lotusminerDevnetTest/
export LOTUS_PATH=$HOME/.lotus/
export LOTUS_MINER_PATH=$HOME/.lotusminer/
export LOTUS_SKIP_GENESIS_CHECK=_yes_
export CGO_CFLAGS_ALLOW="-D__BLST_PORTABLE__"
export CGO_CFLAGS="-D__BLST_PORTABLE__"
export BOOST_SOURCE_PATH=$HOME/lab/boost/
export BOOST_PATH=$HOME/.boost
export BOOST_CLIENT_PATH=$HOME/.boost-client
TEST_CONFIG_FILE=`pwd`"/test_config.gitignore"
LOTUS_MINER_CONFIG_FILE=`pwd`"/lotusminer-autopublish-config.toml"
LOTUS_SOURCE=$HOME/lab/lotus/
LOTUS_DAEMON_LOG=${LOTUS_SOURCE}lotus-daemon.log
LOTUS_MINER_LOG=${LOTUS_SOURCE}lotus-miner.log
export LIBRARY_PATH=/opt/homebrew/lib
export FFI_BUILD_FROM_SOURCE=1
export PATH="$(brew --prefix coreutils)/libexec/gnubin:/usr/local/bin:$PATH"

if [[ -z "$HOME" ]]; then
    _echo "HOME undefined." 1>&2
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
    echo "## Waiting for lotus startup..."
    lotus wait-api --timeout 60s
    lotus status || _error "timeout waiting for lotus startup."
}

function killall_daemons() {
    lotus-miner stop || true
    lotus daemon stop || true
}

function rebuild() {
    _echo "📦Rebuilding from source...📦"
    killall_daemons
    cd $HOME/lab/
    rm -rf $LOTUS_SOURCE
    git clone https://github.com/filecoin-project/lotus.git
    cd lotus/
    git checkout releases
    make clean
    time make 2k
    date -u
    _echo "Installing... user input prompt..."
    sudo make install # Prompts for user interactive input.
    date -u
}

function init_daemons() {
    _echo "📦Initializing Daemons...📦"
    killall_daemons
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

function deploy_miner_config() {
    cp -f $LOTUS_MINER_PATH/config.toml $LOTUS_MINER_PATH/config.toml.bak
    cp -f $LOTUS_MINER_CONFIG_FILE $LOTUS_MINER_PATH/config.toml
}

function restart_daemons() {
    _echo "restarting daemons..."
    _echo "halting any existing daemons..."
    killall_daemons
    sleep 2
    start_daemons
    _echo "daemons restarted."
}

function start_daemons() {
    _echo "📦Starting daemons...📦"
    cd $LOTUS_SOURCE
    nohup ./lotus daemon >> lotus-daemon.log 2>&1 &
    time _waitLotusStartup
    nohup ./lotus-miner run --nosync >> lotus-miner.log 2>&1 &
    _echo "Daemons started."
}

function tail_logs() {
    _echo "Tailing logs..."
    osascript -e 'tell app "Terminal"' -e 'do script "tail -f '${LOTUS_DAEMON_LOG}'"' -e 'end tell'
    osascript -e 'tell app "Terminal"' -e 'do script "tail -f '${LOTUS_MINER_LOG}'"' -e 'end tell'

}

function setup_wallets() {
    _echo "📦Setting up wallets..📦."
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

function client_lotus_deal() {
    if [[ -z "$CLIENT_WALLET_ADDRESS" ]]; then
        _error "CLIENT_WALLET_ADDRESS undefined."
    fi
    
    # Package a CAR file
    _echo "📦Packaging CAR file...📦"
    CAR_FILE=testdata.gitignore/car/testdata.car
    rm -rf testdata.gitignore
    mkdir -p testdata.gitignore/00 testdata.gitignore/car
    dd if=/dev/urandom of="testdata.gitignore/00/data00" bs=1024 count=1 iflag=fullblock
    IPFS_CAR_OUT=`ipfs-car --pack testdata.gitignore/00 --output $CAR_FILE`
    export ROOT_CID=`echo $IPFS_CAR_OUT | sed -rEn 's/^root CID: ([[:alnum:]]*).*$/\1/p'`
    _echo "ROOT_CID: $ROOT_CID"

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
    DEAL_CMD="lotus client deal --from $CLIENT_WALLET_ADDRESS $ROOT_CID $MINERID $PRICE $DURATION"
    _echo "Executing: $DEAL_CMD"
    export DEAL_ID=`$DEAL_CMD`
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
    lotus client find $CID
    rm -rf `pwd`/retrieved-out.gitignore || true
    rm -f `pwd`/retrieved-car.gitignore || true
    lotus client retrieve --provider t01000 $CID `pwd`/retrieved-out.gitignore
    # lotus client retrieve --provider t01000 --car $CID `pwd`/retrieved-car.gitignore
}

function retrieve_wait() {
    CID=$1
    RETRY_COUNT=20
    until retrieve $CID; do
        RETRY_COUNT=$((RETRY_COUNT-1))
        if [[ "$RETRY_COUNT" < 1 ]]; then _error "Exhausted retrie retries"; fi
        _echo "RETRY_COUNT: $RETRY_COUNT"
        sleep 10
    done
}

function build_boost() {
    _echo "📦 building boost... 📦 "
    #cd $BOOST_SOURCE_PATH/..
    #rm -rf $BOOST_SOURCE_PATH
    # git clone https://github.com/filecoin-project/boost
    cd $BOOST_SOURCE_PATH
    git pull
    make clean
    make build
    sudo make install
}

function config_boost() {
    _echo "📦 Configuring boost... 📦"

    mv -f $BOOST_PATH $BOOST_PATH.bak || true
    mv -f $BOOST_CLIENT_PATH $BOOST_CLIENT_PATH.bak || true

    setup_wallets
    if grep "PUBLISH_STORAGE_DEALS_WALLET" "$TEST_CONFIG_FILE"; then
        . "$TEST_CONFIG_FILE"
    else
        PUBLISH_STORAGE_DEALS_WALLET=`lotus wallet new bls`
        COLLAT_WALLET=`lotus wallet new bls`
        _echo "PUBLISH_STORAGE_DEALS_WALLET: $PUBLISH_STORAGE_DEALS_WALLET"
        _echo "COLLAT_WALLET: $COLLAT_WALLET"
        echo "export PUBLISH_STORAGE_DEALS_WALLET=$PUBLISH_STORAGE_DEALS_WALLET" >> $TEST_CONFIG_FILE
        echo "export COLLAT_WALLET: $COLLAT_WALLET" >> $TEST_CONFIG_FILE
        lotus send --from $SP_WALLET_ADDRESS $PUBLISH_STORAGE_DEALS_WALLET 10
        lotus send --from $SP_WALLET_ADDRESS $COLLAT_WALLET 10
        sleep 15 # takes some time... actor not found, requires chain sync so the new wallet addresses can be found.
        _echo "PUBLISH_STORAGE_DEALS_WALLET balance: "`lotus wallet balance $PUBLISH_STORAGE_DEALS_WALLET`
        _echo "COLLAT_WALLET balance: "`lotus wallet balance $COLLAT_WALLET`
    fi

    echo "migrating monolithic lotus-miner to boost"
    # Set the publish storage deals wallet as a control wallet.
    export OLD_CONTROL_ADDRESS=`lotus-miner actor control list  --verbose | awk '{print $3}' | grep -v key | tr -s '\n'  ' '`
    lotus-miner actor control set --really-do-it $PUBLISH_STORAGE_DEALS_WALLET $OLD_CONTROL_ADDRESS

    export $(lotus auth api-info --perm=admin) #FULLNODE_API_INFO
    export $(lotus-miner auth api-info --perm=admin) #MINER_API_INFO
    export APISEALER=`lotus-miner auth api-info --perm=admin` 
    export APISECTORINDEX=`lotus-miner auth api-info --perm=admin` 
    ulimit -n 1048576

    _echo "shutting down lotus-miner..."
    lotus-miner stop || true
    sleep 3

    _echo "Backup the lotus-miner repository..."
    cp -rf "$LOTUS_MINER_PATH" "${LOTUS_MINER_PATH%/}.bak"
    # Backup the lotus-miner datastore (in case you decide to roll back from Boost to Lotus) with: lotus-shed market export-datastore --repo <repo> --backup-dir <backup-dir>

    # migrate lotus-markets
    boostd --vv migrate-monolith \
       --import-miner-repo="$LOTUS_MINER_PATH" \
       --api-sealer=$APISEALER \
       --api-sector-index=$APISECTORINDEX \
       --wallet-publish-storage-deals=$PUBLISH_STORAGE_DEALS_WALLET \
       --wallet-deal-collateral=$COLLAT_WALLET \
       --max-staging-deals-bytes=50000000000

    # Update the lotus-miner config
    _echo "Updating lotus-miner config to disable markets"
    cp "$LOTUS_MINER_PATH""config.toml" "$LOTUS_MINER_PATH""config.toml.backup"
    sed -i '' 's/^[ ]*#EnableMarkets = true/EnableMarkets = false/' "$LOTUS_MINER_PATH""config.toml"

    # Restart lotus-miner
    nohup lotus-miner run --nosync >> lotus-miner.log 2>&1 &
    sleep 2

    _echo "Starting boost..."
    boostd --vv run
}

function run_boost() {
    killall_daemons && sleep 2
    restart_daemons && sleep 3
    boostd --vv run
}

function full_rebuild_test() {
    rebuild
    init_daemons && sleep 10

    killall_daemons && sleep 2
    deploy_miner_config
    restart_daemons
    tail_logs && sleep 10

    setup_wallets && sleep 5
    client_lotus_deal
    client_lotus_deal && sleep 5
}

# Devnet README. https://github.com/filecoin-project/boost/blob/3976945354856f34ac7004dabfb353b579254ab4/README.md#running-boost-for-development
function build_start_devnet() {
    _echo "building boost devnet"
    rm -rf ~/.lotusmarkets ~/.lotus ~/.lotusminer ~/.genesis_sectors
    rm -rf ~/.boost
    rm -rf $LOTUS_PATH $LOTUS_MINER_PATH $BOOST_PATH $BOOST_CLIENT_PATH
    cd $LOTUS_SOURCE
    git checkout releases
    _echo "Making lotus debug..."
    make debug
    _echo "installing lotus..."
    sudo make install
    _echo "installing lotus-seed..."
    sudo install -C ./lotus-seed /usr/local/bin/lotus-seed

    cd $BOOST_SOURCE_PATH
    make debug
    sudo make install

    _echo "starting boost devnet..."
    ./devnet >> ./devnet.log &
    sleep 10
    post_install_devnet
}

function restart_devnet() {
    
    # The devnet isn't designed to be restartable. 
    # After it has been successfully run once, you'll have to clear out the previous data before re-running ./devnet:
    unset MINER_API_INFO
    unset FULLNODE_API_INFO
    #export ENV_MINER_API_INFO=`lotus-miner auth api-info --perm=admin`
    #export ENV_FULLNODE_API_INFO=`lotus auth api-info --perm=admin`

    #export MINER_API_INFO=`echo $ENV_MINER_API_INFO | awk '{split($0,a,"="); print a[2]}'`
    #export FULLNODE_API_INFO=`echo $ENV_FULLNODE_API_INFO | awk '{split($0,a,"="); print a[2]}'`

    #_echo "MINER_API_INFO=$MINER_API_INFO"
    #_echo "FULLNODE_API_INFO=$FULLNODE_API_INFO"

    killall_daemons
    rm -rf ~/.lotusmarkets && rm -rf ~/.lotus && rm -rf ~/.lotusminer && rm -rf ~/.genesis_sectors
    rm -rf $LOTUS_PATH $LOTUS_MINER_PATH $BOOST_PATH $BOOST_CLIENT_PATH

    _echo "Starting boost devnet..."
    cd $BOOST_SOURCE_PATH
    ./devnet >> ./devnet.log &
    echo "Waiting for devnet startup..."
    lotus wait-api --timeout 60s
    lotus status || _error "timeout waiting for lotus startup."
    lotus-miner wait-api --timeout 300s
    lotus-miner auth api-info --perm=admin
    echo "Devnet started-up..."
}


function post_install_devnet() {
    _echo "post-install devnet..."
    unset MINER_API_INFO
    unset FULLNODE_API_INFO
    export ENV_MINER_API_INFO=`lotus-miner auth api-info --perm=admin`
    export ENV_FULLNODE_API_INFO=`lotus auth api-info --perm=admin`
    export MINER_API_INFO=`echo $ENV_MINER_API_INFO | awk '{split($0,a,"="); print a[2]}'`
    export FULLNODE_API_INFO=`echo $ENV_FULLNODE_API_INFO | awk '{split($0,a,"="); print a[2]}'`
    echo MINER_API_INFO=$MINER_API_INFO
    echo FULLNODE_API_INFO=$FULLNODE_API_INFO

    export DEFAULT_WALLET=`lotus wallet list | tail -1 | awk '{print $1}'`
    export COLLAT_WALLET=`lotus wallet new bls`
    export PUBMSG_WALLET=`lotus wallet new bls`
    export CLIENT_WALLET=`lotus wallet new bls`

    echo DEFAULT_WALLET=$DEFAULT_WALLET
    echo COLLAT_WALLET=$COLLAT_WALLET
    echo PUBMSG_WALLET=$PUBMSG_WALLET
    echo CLIENT_WALLET=$CLIENT_WALLET

    lotus wallet list
    _echo "setting: lotus-miner actor control set"
    lotus-miner actor control set --really-do-it $PUBMSG_WALLET

    _echo "Sending funds..."

    lotus send --from $DEFAULT_WALLET $COLLAT_WALLET 10
    lotus send --from $DEFAULT_WALLET $PUBMSG_WALLET 10
    lotus send --from $DEFAULT_WALLET $CLIENT_WALLET 10

    _echo "setting wallets market..."
    lotus wallet market add --from $DEFAULT_WALLET --address $CLIENT_WALLET 5
    lotus wallet market add --address $COLLAT_WALLET 5

    _echo "Initializing up Boost..."
    boostd -vv init \
    --api-sealer=$MINER_API_INFO \
    --api-sector-index=$MINER_API_INFO \
    --wallet-publish-storage-deals=$PUBMSG_WALLET \
    --wallet-deal-collateral=$COLLAT_WALLET \
    --max-staging-deals-bytes=2000000000

    lotus wallet list
    
    make react


    _echo "done with post_install_devnet."

    _echo "building UI.."
    make react
    _echo "setting actor control set..."
    lotus-miner actor control set --really-do-it $PUBMSG_WALLET

    # NOTE mac has additional empty param.
    sed -i '' 's/^[ ]*#EnableMarkets = true/EnableMarkets = false/' "$LOTUS_MINER_PATH""config.toml"
    sed -i '' 's|^[ ]*#ListenAddresses *= \[.*|ListenAddress = \["/ip4/0.0.0.0/tcp/50000", "/ip6/::/tcp/0"\]|' "$LOTUS_MINER_PATH""config.toml"

}




# Execute a function name from CLI parameters
$@

## retrieve $ROOT_CID
# retrieve bafybeicgcmnbeg6ftpmlbkynnvv7pp77ddgq5nglbju7zp26py4di7bmgy
# ROOT_CID=bafybeiheusdoo3wdn3zvpaoprp2tzygydlh2bsvhyisasldre3obfjofii
#retrieve $ROOT_CID

# BOOST SETUP
# killall_daemons
# build_boost
# restart_daemons
# config_boost

#### TODO next idea: Deal using Boost and Singularity.

_echo "Lotus Mac devnet test completed: $0"
