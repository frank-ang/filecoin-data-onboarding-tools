#!/bin/bash

## build and runs lotus miner TODO.

set -e

export LOTUS_PATH=$HOME/.lotusDevnetTest/
export LOTUS_MINER_PATH=$HOME/.lotusminerDevnetTest/
export LOTUS_SKIP_GENESIS_CHECK=_yes_
export CGO_CFLAGS_ALLOW="-D__BLST_PORTABLE__"
export CGO_CFLAGS="-D__BLST_PORTABLE__"

LOTUS_SOURCE=$HOME/lab/lotus/
LOTUS_DAEMON_LOG=${LOTUS_SOURCE}lotus-daemon.log
LOTUS_MINER_LOG=${LOTUS_SOURCE}lotus-miner.log
export LIBRARY_PATH=/opt/homebrew/lib
export FFI_BUILD_FROM_SOURCE=1
export PATH="$(brew --prefix coreutils)/libexec/gnubin:/usr/local/bin:$PATH"

function _echo() {
    echo `date -u +"[%Y-%m-%dT%H:%M:%SZ]"`"##:$1"
}

function _error() {
    _echo $1
    exit 1
}

if [[ -z "$HOME" ]]; then
    _echo "HOME undefined." 1>&2
    exit 1
fi

function _waitLotusStartup() {
    echo "## Waiting for lotus startup..."
    sleep 2
    MAX_SLEEP_SECS=20
    while [[ $MAX_SLEEP_SECS -ge 0 ]]; do
        lotus status && break
        MAX_SLEEP_SECS=$(( $MAX_SLEEP_SECS - 1 ))
        if [ $MAX_SLEEP_SECS -lt 1 ]; then _error "Timeout waiting for daemon."; fi
        sleep 1
    done
}

function rebuild() {
    _echo "Rebuilding from source..."
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
    _echo "Initializing Daemons..."
    rm -rf $LOTUS_PATH
    rm -rf $LOTUS_MINER_HOME
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

function restart_daemons() {
    _echo "restarting daemons..."
    _echo "halting existing daemons..."
    killall lotus-miner || true
    killall lotus || true
    sleep 1
    start_daemons
    _echo "daemons restarted."
}

function start_daemons() {
    _echo "starting daemons..."
    cd $LOTUS_SOURCE
    nohup ./lotus daemon >> lotus-daemon.log 2>&1 &
    time _waitLotusStartup
    nohup ./lotus-miner run --nosync >> lotus-miner.log 2>&1 &
    _echo "daemons started."
}

function tail_logs() {
    _echo "Tailing logs..."
    osascript -e 'tell app "Terminal"' -e 'do script "tail -f '${LOTUS_DAEMON_LOG}'"' -e 'end tell'
    osascript -e 'tell app "Terminal"' -e 'do script "tail -f '${LOTUS_MINER_LOG}'"' -e 'end tell'

}

#rebuild

#init_daemons

restart_daemons
tail_logs

_echo "end of script: $0"
