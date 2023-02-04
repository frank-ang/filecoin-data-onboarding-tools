#!/bin/bash
# Create random test files.

. $(dirname $(realpath $0))"/filecoin-tools-common.sh" # import common functions and constants

# Creates test data files with pattern: $DATA_SOURCE_ROOT/$DATASET_NAME/file-$FILE_COUNT
# generates and sets a random DATASET_NAME
# Params: FILE_COUNT, FILE_SIZE
function generate_test_files_DEPRECATED() {
    local FILE_COUNT="${1:-1}"
    local FILE_SIZE="${2:-1024}"
    local DIRNAME=${3:-"$DATA_SOURCE_ROOT"}
    export DATASET_NAME=`uuidgen | cut -d'-' -f1`
    local DATASET_SOURCE_DIR=$DIRNAME/$DATASET_NAME
    rm -rf $DATASET_SOURCE_DIR && mkdir -p $DATASET_SOURCE_DIR
    local PREFIX="file"
    echo "Generating test files for dataset: $DATASET_NAME, Files: $FILE_COUNT, Size: $FILE_SIZE, output:$DATASET_SOURCE_DIR, prefix: $PREFIX"
    [[ -z "$FILE_COUNT" ]] && { _error "generate_test_files FILE_COUNT is required"; }
    [[ -z "$FILE_SIZE" ]] && { _error "generate_test_files FILE_SIZE bytes is required"; }
    [[ -z "$PREFIX" ]] && { _error "generate_test_files PREFIX is required" ; }
    [[ -z "$DATASET_SOURCE_DIR" ]] && { _error "generate_test_files DATASET_SOURCE_DIR is required" ; }
    mkdir -p "$DATASET_SOURCE_DIR"
    while [[ "$FILE_COUNT" -gt 0 ]]; do
        BLOCK_SIZE=1 # $(( $FILE_SIZE < 1024 ? 1 : 1024 ))
        COUNT_BLOCKS=$(( $FILE_SIZE/$BLOCK_SIZE ))
        CMD="dd if=/dev/urandom of="$DATASET_SOURCE_DIR/$PREFIX-$FILE_COUNT" bs=$BLOCK_SIZE count=$COUNT_BLOCKS iflag=fullblock"
        _echo "executing: $CMD"
        $CMD
        ((FILE_COUNT--))
    done
    echo "Test files created into $DATASET_SOURCE_DIR"
    echo "export DATASET_NAME=$DATASET_NAME" >> $TEST_CONFIG_FILE
}

# Entry point to generate test data.
function gen_test_data_case() {
    local DIRNAME=${1:-"$DATA_SOURCE_ROOT"}
    export DATASET_NAME=`uuidgen | cut -d'-' -f1`
    local DATASET_SOURCE_DIR=$DIRNAME/$DATASET_NAME
    rm -rf $DATASET_SOURCE_DIR && mkdir -p $DATASET_SOURCE_DIR
    echo "Generating test files for dataset: $DATASET_NAME, output:$DATASET_SOURCE_DIR"
    gen_test_data_to_dir 10 1 "$DATASET_SOURCE_DIR"
    gen_test_data_to_dir 20 1 "$DATASET_SOURCE_DIR/folder1"
    gen_test_data_to_dir 30 1 "$DATASET_SOURCE_DIR/folder1.1"
    gen_test_data_to_dir 40 1 "$DATASET_SOURCE_DIR/folder1.2"
    gen_test_data_to_dir 50 1 "$DATASET_SOURCE_DIR/folder2"
    echo "export DATASET_NAME=$DATASET_NAME" >> $TEST_CONFIG_FILE
}


function gen_test_data_to_dir() {
    local FILE_COUNT="${1:-1}"
    local FILE_SIZE="${2:-1024}"
    local OUTPUT_DIR="${3}"
    [[ -z "$FILE_COUNT" ]] && { _error "FILE_COUNT is required"; }
    [[ -z "$FILE_SIZE" ]] && { _error "FILE_SIZE bytes is required"; }
    [[ -z "$OUTPUT_DIR" ]] && { _error "OUTPUT_DIR is required" ; }
    PREFIX="file"
    echo "Generating test files for dataset: $DATASET_NAME, Files: $FILE_COUNT, Size: $FILE_SIZE, output:$DATASET_SOURCE_DIR, prefix: $PREFIX"
    rm -rf $OUTPUT_DIR && mkdir -p $OUTPUT_DIR
    while [[ "$FILE_COUNT" -gt 0 ]]; do
        BLOCK_SIZE=1 # $(( $FILE_SIZE < 1024 ? 1 : 1024 ))
        COUNT_BLOCKS=$(( $FILE_SIZE/$BLOCK_SIZE ))
        CMD="dd if=/dev/urandom of="$OUTPUT_DIR/$PREFIX-$FILE_COUNT" bs=$BLOCK_SIZE count=$COUNT_BLOCKS iflag=fullblock"
        echo "executing: $CMD"
        $CMD
        ((FILE_COUNT--))
    done
}


gen_test_data_case