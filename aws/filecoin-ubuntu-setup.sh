#!/bin/bash

function install_dependencies() {
    echo "## Installing Dependencies..."
    cd $HOME # assumed as /root
    apt update
    apt install -y git openssl gcc rsync make jq unzip nfs-common
    apt install -y software-properties-common
    apt install -y sysstat iotop
}

function install_node() {
    # Node 16
    echo "## Installing NVM..." 
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.1/install.sh | bash
    source /root/.bashrc

    # Try dot sourcing nvm scripts again just in case.
    export NVM_DIR="$HOME/.nvm"
    . "$NVM_DIR/nvm.sh"
    . "$NVM_DIR/bash_completion"

    echo "## nvm version: "`nvm version`
    echo "## Installing Node..." 
    nvm install 16

    echo "## which node: "`which node`
    echo "## node --version: "`node --version`
}

function install_golang() {
    # Golang 1.18 and stream-commp
    wget --no-verbose -c https://go.dev/dl/go1.18.3.linux-amd64.tar.gz
    tar -C /usr/local/ -xzf go1.18.3.linux-amd64.tar.gz
    echo 'export GOPATH=/root/go' >> ~/.bashrc
    echo 'export GOBIN=$GOPATH/bin' >> ~/.bashrc
    echo 'export GOROOT=/usr/local/go' >> ~/.bashrc
    echo 'export PATH=$PATH:$GOPATH/bin:$GOROOT/bin' >> ~/.bashrc
    # set envars, because sourcing .bashrc appears not to work in userdata.
    export HOME=/root
    export GOPATH=/root/go
    export GOBIN=$GOPATH/bin
    export GOROOT=/usr/local/go
    export PATH=$PATH:$GOPATH/bin:$GOROOT/bin
    go version
    go install github.com/filecoin-project/go-fil-commp-hashhash/cmd/stream-commp@latest
    echo "## which stream-commp:"`which stream-commp`

}

function install_singularity() {
    cd $HOME
    git clone https://github.com/tech-greedy/singularity.git
    echo "## Deploying DealReplicationWorker Devnet workaround patch..."
    cp -f ./singularity-integ-test/singularity/DealReplicationWorker.ts ./singularity/src/replication/DealReplicationWorker.ts
    echo "## Building singularity..."
    cd singularity
    npm ci
    npm run build
    npm link
    npx singularity -h
    echo "Install Generate CAR dependency..."
    cd $HOME
    git clone https://github.com/tech-greedy/go-generate-car.git
    cd go-generate-car
    make
    # singularity cloned locally ./node_modules/.bin
    mv ./generate-car $HOME/singularity/node_modules/.bin
    echo "## Singularity installed: which singularity: "`which singularity`
}

function init_singularity() {
    # Singularity init, run daemon, prep etc. Run a test script
    cd $HOME/singularity
    nohup ./singularity-tests.sh >> ../singularity-tests.log 2>&1 &
}

function build_lotus() {
    # Lotus build, init, start daemon, verify.
    echo "## building lotus..."
    cd $HOME/singularity-integ-test/lotus
    nohup ./lotus-init-devnet.sh run >> ../lotus-init-devnet.log 2>&1 &
}

function run() {
    echo "running script $0"
    install_dependencies
    install_node
    install_golang
}
