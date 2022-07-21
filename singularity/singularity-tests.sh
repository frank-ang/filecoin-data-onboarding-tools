#!/bin/bash
set -e

if [[ -z "$HOME" ]]; then
    echo "HOME undefined." 1>&2
    exit 1
fi

# increase limits
ulimit -n 100000

function _error() {
    echo $1
    exit 1
}

# Nuke pre-existing config and any crumbs
pkill -f 'node .*singularity daemon' || true
rm -rf $HOME/.singularity

# Initialize.
echo "Initializing Singularity..."
singularity init
ls $HOME/.singularity
echo "Setting up config for deal prep only."
cp $HOME/.singularity/default.toml $HOME/.singularity/default.toml.orig
cp ./deal-prep-only.toml $HOME/.singularity/default.toml
# Start daemon.
echo "Starting singularity daemon..."
nohup singularity daemon 2>&1 &
echo "Started singularity daemon."

# Wait for singularity daemon startup.
sleep 10 && singularity prep list

# Generate test data
echo "Preparing test data..."
export DATASET_PATH=/tmp/source
export OUT_DIR=/tmp/car
export DATASET_NAME="test0000"
rm -rf $DATASET_PATH && mkdir -p $DATASET_PATH
rm -rf $OUT_DIR && mkdir -p $OUT_DIR
cp -r /root/singularity $DATASET_PATH

# Run data prep test
echo "Running test..."
export SINGULARITY_CMD="singularity prep create $DATASET_NAME $DATASET_PATH $OUT_DIR"
echo "executing command: $SINGULARITY_CMD"
$SINGULARITY_CMD

# Await job completion TODO:
echo "awaiting prep status completion."
sleep 5
PREP_STATUS="blank"
MAX_SLEEP_SECS=10
while [[ "$PREP_STATUS" != "completed" && $MAX_SLEEP_SECS -ge 0 ]]; do
    MAX_SLEEP_SECS=$(( $MAX_SLEEP_SECS - 1 ))
    if [ $MAX_SLEEP_SECS -eq 0 ]; then _error "Timeout waiting for prep success status."; fi
    sleep 1
    PREP_STATUS=`singularity prep status --json $DATASET_NAME | jq -r '.generationRequests[].status'`
    echo "PREP_STATUS: $PREP_STATUS"
done

# Verify test result
export EXPECTED_CAR_COUNT=1
echo "Verifying test output..."
echo "listing of $OUT_DIR: "`ls -lh $OUT_DIR`
echo "size of $OUT_DIR: "`du -sh $OUT_DIR`
export ACTUAL_CAR_COUNT=`find $OUT_DIR -type f | wc -l`
echo "count of regular files in $OUT_DIR: $ACTUAL_CAR_COUNT"
if [ $ACTUAL_CAR_COUNT -ne $EXPECTED_CAR_COUNT ]; then _error "unexpected count of files: $ACTUAL_CAR_COUNT -ne $EXPECTED_CAR_COUNT"; fi

# TODO need to dive into the following command: 
#   ```singularity prep  generation-status $GENERATION_ID_TODO.``` 
# which returns CIDs and file index. 

# TODO additional test verification.

# TODO verify database query
# TODO verify CAR structure.
# TODO un-CAR and diff.

# TODO additional tests.

# TODO post test results somewhere.

echo "End of test script."
