#!/bin/bash

## build, initialize, and run lotus daemon and lotus miner.

set -e

export LOTUS_PATH=$HOME/.lotusDevnetTest/
export LOTUS_MINER_PATH=$HOME/.lotusminerDevnetTest/
export LOTUS_SKIP_GENESIS_CHECK=_yes_
export CGO_CFLAGS_ALLOW="-D__BLST_PORTABLE__"
export CGO_CFLAGS="-D__BLST_PORTABLE__"

LOTUS_MINER_CONFIG_FILE=`pwd`"/lotusminer-autopublish-mac-config.toml"
LOTUS_SOURCE=$HOME/lab/lotus/
LOTUS_DAEMON_LOG=${LOTUS_SOURCE}lotus-daemon.log
LOTUS_MINER_LOG=${LOTUS_SOURCE}lotus-miner.log
export LIBRARY_PATH=/opt/homebrew/lib
export FFI_BUILD_FROM_SOURCE=1
export PATH="$(brew --prefix coreutils)/libexec/gnubin:/usr/local/bin:$PATH"

function _echo() {
    echo `date -u +"%Y-%m-%dT%H:%M:%SZ"`"##:$1"
}

function _error() {
    _echo "ERROR: $1"
    exit 1
}

if [[ -z "$HOME" ]]; then
    _echo "HOME undefined." 1>&2
    exit 1
fi

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

function client_lotus_deal() {
    if [[ -z "$CLIENT_WALLET_ADDRESS" ]]; then
        _echo "CLIENT_WALLET_ADDRESS undefined." 1>&2
        exit 1
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

# No need to push things along manually, by setting auto-publish in config.toml.
function miner_handle_deal_manually_deprecated() {
    # Wait timings are fragile.

    _echo "Miner handling deal..."
    lotus-miner storage-deals list -v # dealID shows as StorageDealPublish
    _echo "lotus-miner storage-deals pending-publish --publish-now ... "
    lotus-miner storage-deals pending-publish  # dealID should be queued for publish
    lotus-miner storage-deals pending-publish --publish-now

    sleep 5

    lotus-miner sectors list # sector in SubmitPreCommitBatch
    # list sectors waiting in precommit batch queue
    lotus-miner sectors batching precommit
    _echo "lotus-miner sectors batching precommit --publish-now..."
    lotus-miner sectors batching precommit --publish-now

    # sector state progresses thru WaitSeed, Committing, SubmitCommitAggregate
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
    lotus client list-deals

}


function retrieve() {
    CID=$1
    if [[ -z "$CID" ]]; then
        _echo "CID undefined." 1>&2
        exit 1
    fi
    lotus client find $CID
    rm -rf `pwd`/retrieved-out.gitignore
    rm -f `pwd`/retrieved-car.gitignore
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


function init_boost() {
    
    #PUBLISH_STORAGE_DEALS_WALLET=`lotus wallet new bls` # t3qjjjzidrcjjkmplkctddkfyopr6skmxoivto2p7xb4sxhhf3glg524cjjjqrhjxl6ja26k27ph3www2yzwfa
    #COLLAT_WALLET=`lotus wallet new bls` # t3ve53qhszjszvvp2cdsbs5pwphpww7rjwnqhusn6zb2to6sy4vqkeadsbtu7kor5gp7voamscjsunaxj73gha
    # Some hardcoding...
    export SP_WALLET_ADDRESS=t3xcz3ni4tvu2yhc4oznumdsyf3vgtgd4iy5y3xjgfft7wkygxkjmihv5lltuwnm2ztgpjqhwqdgwylfvihrkq
    export PUBLISH_STORAGE_DEALS_WALLET=t3qjjjzidrcjjkmplkctddkfyopr6skmxoivto2p7xb4sxhhf3glg524cjjjqrhjxl6ja26k27ph3www2yzwfa
    export COLLAT_WALLET=t3ve53qhszjszvvp2cdsbs5pwphpww7rjwnqhusn6zb2to6sy4vqkeadsbtu7kor5gp7voamscjsunaxj73gha
    
    lotus send --from $SP_WALLET_ADDRESS $PUBLISH_STORAGE_DEALS_WALLET 10
    lotus send --from $SP_WALLET_ADDRESS $COLLAT_WALLET 10
    sleep 60 # takes some time... actor not found, requires chain sync so the new wallet addresses can be found.
    lotus wallet balance $PUBLISH_STORAGE_DEALS_WALLET
    lotus wallet balance $COLLAT_WALLET


    lotus-miner actor control set --really-do-it $PUBLISH_STORAGE_DEALS_WALLET

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

# Execute a function name from CLI parameters
$@

## retrieve $ROOT_CID
# retrieve bafybeicgcmnbeg6ftpmlbkynnvv7pp77ddgq5nglbju7zp26py4di7bmgy
# ROOT_CID=bafybeiheusdoo3wdn3zvpaoprp2tzygydlh2bsvhyisasldre3obfjofii
#retrieve $ROOT_CID
# killall_daemons

#### TODO next idea: Deal using Boost and Singularity.

_echo "Lotus Mac devnet test completed: $0"
