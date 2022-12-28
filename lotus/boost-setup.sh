#!/bin/bash

. $(dirname $(realpath $0))"/filecoin-tools-common.sh" # import common functions.
BOOST_ENV_FILE=$(dirname $(realpath $0))"/boost.env"

function clone_boost_repo() {
    cd $HOME
    # rm -rf ~/.lotusmarkets ~/.lotus ~/.lotusminer ~/.genesis_sectors # no need, assume lotus & lotus miner are built prior to boost.
    rm -rf ~/.boost
    rm -rf ./boost
    git clone https://github.com/filecoin-project/boost
    cd ./boost
}

function build_lotus_devnet() {
    # cd $HOME
    # rm -rf lotus
    # git clone https://github.com/filecoin-project/lotus.git
    cd $HOME/lotus
    git fetch --all
    git checkout tags/v1.18.0 # match the version in Boost's go.mod
    make clean
    make debug
    _echo "Installing lotus..."
    make install
    install -C ./lotus-seed /usr/local/bin/lotus-seed
    _echo "Lotus installed complete. Lotus version: "`lotus --version`
}

function build_boost_devnet() {
    # export LIBRARY_PATH=/opt/homebrew/lib # mac only?
    # export PATH="$(brew --prefix coreutils)/libexec/gnubin:/usr/local/bin:$PATH" # mac only?
    cd $HOME/boost
    make debug
    make install
}

function start_boost_devnet() {
    # The following command will use the binaries built, and will run lotus, lotus-miner and lotus-seed. 
    # The lotus version must match the version in Boost's go.mod.
    # takes about 10mins when devnet calls lotus fetch-params
    rm -rf ~/.lotusmarkets && rm -rf ~/.lotus && rm -rf ~/.lotusminer && rm -rf ~/.genesis_sectors
    rm -rf ~/.boost
    rm -f $BOOST_ENV_FILE
    cd $HOME/boost
    unset MINER_API_INFO
    unset FULLNODE_API_INFO
    nohup ./devnet >> devnet.log 2>&1 &
}

function wait_boost_miner_up() {
    unset MINER_API_INFO
    unset FULLNODE_API_INFO
    # TODO retry until success.
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
    export DEFAULT_WALLET=`lotus wallet list | tail -1 | awk '{print $1}'`
    export COLLAT_WALLET=`lotus wallet new bls`
    export PUBMSG_WALLET=`lotus wallet new bls`
    export CLIENT_WALLET=`lotus wallet new bls` 
    echo "export DEFAULT_WALLET=$DEFAULT_WALLET" >> $BOOST_ENV_FILE
    echo "export COLLAT_WALLET=$COLLAT_WALLET" >> $BOOST_ENV_FILE
    echo "export PUBMSG_WALLET=$PUBMSG_WALLET" >> $BOOST_ENV_FILE
    echo "export CLIENT_WALLET=$CLIENT_WALLET" >> $BOOST_ENV_FILE
}

function add_funds_boost_wallets() {
    lotus send --from $DEFAULT_WALLET $COLLAT_WALLET 10
    lotus send --from $DEFAULT_WALLET $PUBMSG_WALLET 10
    lotus send --from $DEFAULT_WALLET $CLIENT_WALLET 10
    sleep 10
    lotus wallet list
    lotus-miner actor control set --really-do-it $PUBMSG_WALLET
    lotus wallet market add --from $DEFAULT_WALLET --address $CLIENT_WALLET 5
    lotus wallet market add --address $COLLAT_WALLET 5
}

function init_boost_repo() {
    boostd -vv init \
    --api-sealer=$MINER_API_INFO \
    --api-sector-index=$MINER_API_INFO \
    --wallet-publish-storage-deals=$PUBMSG_WALLET \
    --wallet-deal-collateral=$COLLAT_WALLET \
    --max-staging-deals-bytes=2000000000
}

function setup_web_ui() {
    cd $HOME/boost
    make react
# EDIT
#[Libp2p]
#  ListenAddresses = ["/ip4/0.0.0.0/tcp/50000", "/ip6/::/tcp/0"]
}

function setup_boost_devnet() {
    build_lotus_devnet
    clone_boost_repo
    build_boost_devnet
    start_boost_devnet
    # wait for startup.
    wait_boost_miner_up
    get_miner_auth_tokens
    create_boost_wallets
    add_funds_boost_wallets
    init_boost_repo
    setup_web_ui
}

