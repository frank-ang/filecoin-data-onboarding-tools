#!/bin/bash
# Run as root.
# Build Lotus devnet from source, configure, run devnet
# Based on: 
# https://lotus.filecoin.io/lotus/install/linux/#building-from-source

set -e

function _error() {
    echo $1
    exit 1
}

if [[ -z "$HOME" ]]; then
    echo "HOME undefined." 1>&2
    exit 1
fi

cd $HOME

echo "## Installing prereqs..."
apt install mesa-opencl-icd ocl-icd-opencl-dev gcc git bzr jq pkg-config curl clang build-essential hwloc libhwloc-dev wget -y && sudo apt upgrade -y

echo "## Installing rust..."
curl https://sh.rustup.rs -sSf > RUSTUP.sh
sh RUSTUP.sh -y
rm RUSTUP.sh

echo "## Installing golang..."
wget -c https://go.dev/dl/go1.18.4.linux-amd64.tar.gz -O - | tar -xz -C /usr/local
echo "export PATH=$PATH:/usr/local/go/bin" >> ~/.bashrc && source ~/.bashrc

echo "## Building lotus..."
rm -rf $HOME/lotus
rm -rf $HOME/.lotus
git clone https://github.com/filecoin-project/lotus.git
cd lotus/
git checkout releases
# Try calibnet, or devnet?
make clean calibnet # Calibration with min 32GiB sectors
make install
which lotus && lotus --version

echo "## Starting lotus daemon..."
nohup lotus daemon >> lotus-daemon.log 2>&1 &

## TODO
## Gettting this:
## ## Awaiting lotus startup...
## ERROR: could not get API info for FullNode: could not get api endpoint: API not running (no endpoint)

echo "## Awaiting lotus startup..."
sleep 2
MAX_SLEEP_SECS=20
while [[ $MAX_SLEEP_SECS -ge 0 ]]; do
    lotus status && break
    MAX_SLEEP_SECS=$(( $MAX_SLEEP_SECS - 1 ))
    if [ $MAX_SLEEP_SECS -lt 1 ]; then _error "Timeout waiting for daemon."; fi
    sleep 1
done

echo "## Creating wallet..."
lotus wallet new
lotus wallet list
lotus wallet balance

echo "## Lotus setup completed."
