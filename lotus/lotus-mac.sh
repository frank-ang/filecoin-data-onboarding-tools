#!/bin/bash

## build and runs lotus miner TODO.

set -e

export LOTUS_PATH=$HOME/.lotusDevnetTest/
export LOTUS_MINER_HOME=$HOME/.lotusminerDevnetTest/
LOTUS_SOURCE=$HOME/lab/lotus/

function _error() {
    echo $1
    exit 1
}

if [[ -z "$HOME" ]]; then
    echo "HOME undefined." 1>&2
    exit 1
fi

rm -rf $LOTUS_PATH
rm -rf $LOTUS_MINER_HOME
rm -rf $LOTUS_SOURCE
cd $HOME/lab/

time git clone https://github.com/filecoin-project/lotus.git
cd lotus/
git checkout releases

export LIBRARY_PATH=/opt/homebrew/lib
export FFI_BUILD_FROM_SOURCE=1
export PATH="$(brew --prefix coreutils)/libexec/gnubin:/usr/local/bin:$PATH"

#make clean
make 2k
sudo make install

