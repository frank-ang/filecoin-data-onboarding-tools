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
    install_singularity
    init_singularity
    build_lotus
}