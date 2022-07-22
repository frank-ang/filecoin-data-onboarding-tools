#!/bin/bash
# Run as root.
# Build Lotus devnet from source, configure, run devnet
# Based on: 
# https://lotus.filecoin.io/lotus/install/linux/#building-from-source

set -e

if [[ -z "$HOME" ]]; then
    echo "HOME undefined." 1>&2
    exit 1
fi

cd $HOME

# Prereqs
apt install mesa-opencl-icd ocl-icd-opencl-dev gcc git bzr jq pkg-config curl clang build-essential hwloc libhwloc-dev wget -y && sudo apt upgrade -y

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
wget -c https://go.dev/dl/go1.18.4.linux-amd64.tar.gz -O - | sudo tar -xz -C /usr/local
echo "export PATH=$PATH:/usr/local/go/bin" >> ~/.bashrc && source ~/.bashrc

# Build and install Lotus
git clone https://github.com/filecoin-project/lotus.git
cd lotus/
git checkout releases

# Try calibnet, as documented.
make clean calibnet # Calibration with min 32GiB sectors
sudo make install
which lotus && lotus --version

nohup lotus daemon >> lotus-daemon.log 2>&1 &

ls $HOME/.lotus

# Create wallet
lotus wallet new
lotus wallet list
