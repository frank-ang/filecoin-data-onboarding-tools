#!/bin/bash

. $(dirname $(realpath $0))"/filecoin-tools-common.sh" # import common functions.
BOOST_ENV_FILE=$(dirname $(realpath $0))"/boost.env"
ulimit -n 1048576
PROJECT_HOME=$HOME
BOOST_PATH=$HOME/.boost

function build_lotus_devnet() {
    stop_daemons
    _echo "Rebuilding from source..."
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
    _echo "Lotus installed complete. Lotus version: "`lotus --version`
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
    # export LIBRARY_PATH=/opt/homebrew/lib # mac only?
    # export PATH="$(brew --prefix coreutils)/libexec/gnubin:/usr/local/bin:$PATH" # mac only?
    cd $PROJECT_HOME/boost
    make debug
    sudo make install
}

function start_boost_devnet() {
    # The following command will use the binaries built, and will run lotus, lotus-miner and lotus-seed. 
    # The lotus version must match the version in Boost's go.mod.
    # takes about 10mins when devnet calls lotus fetch-params
    rm -f $BOOST_ENV_FILE
    cd $HOME/boost
    nohup ./devnet >> devnet.log 2>&1 &
}

function wait_boost_miner_up() {
    unset MINER_API_INFO
    unset FULLNODE_API_INFO
    lotus-miner wait-api --timeout 1200s
    # retry 20 lotus-miner auth api-info --perm=admin
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
    sleep 20 # some time for wallet funds to appear on chain.
    retry 10 lotus-miner actor control set --really-do-it $PUBMSG_WALLET
    retry 5 lotus wallet market add --from $DEFAULT_WALLET --address $CLIENT_WALLET 5
    retry 5 lotus wallet market add --address $COLLAT_WALLET 5
    lotus wallet list
    until lotus-miner actor control set --really-do-it ${PUBMSG_WALLET}; do echo Waiting for storage miner API ready ...; sleep 1; done
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
    #[Libp2p]
    #  ListenAddresses = ["/ip4/0.0.0.0/tcp/50000", "/ip6/::/tcp/0"]
}

function setup_web_ui() {
    cd $HOME/boost
    # make react # TODO curl returns 404 not found
    npm install --legacy-peer-deps
    npm run build
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
        echo Try to stop boost...
        kill -15 $BOOST_PID || kill -9 $BOOST_PID
        rm -f $BOOST_PATH/boostd.log
        echo Super. DONE! Boostd is now configured and will be started soon
    fi
}

function start_boostd() {
    echo Starting boost in dev mode...
    # exec boostd -vv run
    nohup boostd -vv run >> $HOME/boost/boostd.log 2>&1 &
}

function do_boost_client() {
    cd $HOME/boost
    [[ -z "$FULLNODE_API_INFO" ]] && { _error "FULLNODE_API_INFO is required"; }
    boost -vv init
    export BOOST_INIT_CLIENT_WALLET=`boost wallet default`
    _echo "boost client wallet: $BOOST_INIT_CLIENT_WALLET"
    echo "export BOOST_INIT_CLIENT_WALLET=$BOOST_INIT_CLIENT_WALLET" >> $BOOST_ENV_FILE
    _echo "funding client wallet: $BOOST_INIT_CLIENT_WALLET"
    #lotus send --from $DEFAULT_WALLET $BOOST_INIT_CLIENT_WALLET 100 && sleep 30
    boostx market-add 11
    sleep 30
    boostx generate-car ./README.md ./my-data.car
}


function rebuild_boost_devnet() {
    set -x
    clone_boost_repo
    build_boost_devnet
    start_boost_devnet
    wait_boost_miner_up
    get_miner_auth_tokens
    create_boost_wallets
    add_funds_boost_wallets
    init_boost_repo
    setup_web_ui # TODO 404
    setup_maddr
    start_boostd
    set +x
    retry 20 verify_boost_install
}

function verify_boost_install() {
    curl -s -X POST -H "Content-Type: application/json" -d '{"query":"query {epoch { Epoch }}"}' http://localhost:8080/graphql/query
    curl http://localhost:8080 # 404 page not found?
    # Tunnel: ssh -L 8080:localhost:8080 ubuntu@myserver
    # open web ui localhost:8080
    # Problem with boost UI: 404 not found
}

function setup_boost_devnet() {
    build_lotus_devnet # comment out to skip rebuild lotus
    rebuild_boost_devnet
    verify_boost_install
}