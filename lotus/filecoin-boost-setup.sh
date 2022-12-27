#!/bin/bash

. $(dirname $(realpath $0))"/filecoin-tools-common.sh" # import common functions.


function clone_boost_repo() {
    cd $HOME
    # rm -rf ~/.lotusmarkets ~/.lotus ~/.lotusminer ~/.genesis_sectors # no need, assume lotus & lotus miner are built prior to boost.
    rm -rf ~/.boost
    rm -rf ./boost
    git clone https://github.com/filecoin-project/boost
    cd ./boost
}

function build_boost() {
    # export LIBRARY_PATH=/opt/homebrew/lib # mac only?
    # export PATH="$(brew --prefix coreutils)/libexec/gnubin:/usr/local/bin:$PATH" # mac only?
    cd $HOME/boost
    make debug
    make install
}

function start_boost_devnet() {
    # The following command will use the binaries that you built and installed above, and will run lotus, lotus-miner and lotus-seed. The lotus version must match the version in Boost's go.mod.
    cd $HOME/boost
    unset MINER_API_INFO
    unset FULLNODE_API_INFO
    ./devnet
}

function restart_boost_devnet() {
    rm -rf ~/.lotusmarkets && rm -rf ~/.lotus && rm -rf ~/.lotusminer && rm -rf ~/.genesis_sectors
    start_boost_devnet
}

function setup_boost_devnet() {
    clone_boost_repo
}

