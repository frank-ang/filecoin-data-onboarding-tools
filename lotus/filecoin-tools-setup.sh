#!/bin/bash
# Main install/configure script.
# Also, use this script to invoke test functions.
# Run as root.
# E.g. via nohup or tmux:
#         ./filecoin-tools-setup.sh full_rebuild_test >> ./full_rebuild_test.out 2>&1 &
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

# set golang env vars, because sourcing .bashrc appears not to work in userdata.
export GOPATH=/root/go
export GOBIN=$GOPATH/bin
export GOROOT=/usr/local/go
export PATH=$PATH:$GOPATH/bin:$GOROOT/bin

# set NVM env vars for Singularity
export NVM_DIR="$HOME/.nvm"
. "$NVM_DIR/nvm.sh"
. "$NVM_DIR/bash_completion"
export MINERID="t01000"

. $(dirname $(realpath $0))"/filecoin-tools-common.sh" # import common functions.
. $(dirname $(realpath $0))"/filecoin-tools-tests.sh" # import test functions.

function build_lotus() {
    _echo "Rebuilding from source..."
    stop_daemons

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
    _echo "## Installing lotus..."
    make install
    _echo "## Lotus installed complete. Lotus version: "`lotus --version`
}

function init_daemons() {
    _echo "Initializing lotus daemons..."
    stop_daemons
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
    _echo "Initializing lotus daemons completed."
}

function deploy_miner_config() {
    _echo "Deploying miner config..."
    cp -f $LOTUS_MINER_PATH/config.toml $LOTUS_MINER_PATH/config.toml.bak
    cp -f $LOTUS_MINER_CONFIG_FILE $LOTUS_MINER_PATH/config.toml
}

function restart_daemons() {
    _echo "restarting daemons..."
    _echo "halting any existing daemons..."
    stop_daemons
    sleep 10
    start_daemons
    sleep 10
    _echo "daemons restarted."
}

function start_daemons() {
    start_ipfs
    _echo "Starting lotus node..."
    cd $LOTUS_SOURCE
    nohup lotus daemon >> /var/log/lotus-daemon.log 2>&1 &
    _waitLotusStartup
    _echo "lotus node started. starting lotus miner..."
    sleep 5
    nohup lotus-miner run --nosync >> /var/log/lotus-miner.log 2>&1 &
    lotus-miner wait-api --timeout 600s
    _echo "lotus miner started."
    start_singularity
}

function _waitLotusStartup() {
    t=${1:-"120s"} # note trailing "s"
    _echo "## Waiting for lotus startup, timeout $t..."
    lotus wait-api --timeout $t
}

function stop_daemons() {
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
    sleep 12
    timeout 1m bash -c 'until singularity prep list; do sleep 5; done'
    timeout 30s bash -c 'until singularity repl list; do sleep 5; done'
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
    rm -rf $HOME/.ipfs
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

# Sets SP_WALLET_ADDRESS, CLIENT_WALLET_ADDRESS
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

function install_singularity() {
    rm -rf $HOME/singularity
    rm -rf $HOME/.singularity
    _echo "cloning singularity repo..."
    cd $HOME
    git clone https://github.com/tech-greedy/singularity.git
    _echo "deploying hacky patch to DealReplicationWorker.ts for devnet blockheight."
    cp -f filecoin-data-onboarding-tools/singularity/DealReplicationWorker.ts singularity/src/replication/DealReplicationWorker.ts
    _echo "building singularity..."
    cd singularity
    npm ci
    npm run build
    npm link
    npx singularity -V
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
    _echo "Initializing Singularity..."
    singularity init
    ls $HOME/.singularity
    cp $HOME/.singularity/default.toml $HOME/.singularity/default.toml.orig
    cp $HOME/filecoin-data-onboarding-tools/singularity/my-singularity-config.toml $HOME/.singularity/default.toml
}

function build {
    setup_ipfs
    start_ipfs

    install_singularity
    init_singularity
    start_singularity

    build_lotus
    init_daemons && sleep 10

    stop_daemons && sleep 2
    deploy_miner_config
    restart_daemons && sleep 2

    setup_wallets && sleep 5
}

function full_rebuild_test() {
    build
    test_singularity
}

function run() {
    full_build_test
}

# Execute function from parameters
# cd $HOME
$@
