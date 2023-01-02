#!/bin/bash
# Imports car files into boost. Uses Singularity manifest file CSV.
MANIFEST_CSV_FILENAME=$1
CAR_ROOT_PATH=$2
[[ -z "$MANIFEST_CSV_FILENAME" ]] && { echo "MANIFEST_CSV_FILENAME is required"; exit 1; }
[[ -z "$CAR_ROOT_PATH" ]] && { echo "CAR_ROOT_PATH is required"; exit 1; }
{
    read
    while IFS=, read -r miner_id deal_cid filename data_cid piece_cid start_epoch full_url
    do 
        # echo "miner_id deal_cid filename data_cid piece_cid start_epoch full_url: $miner_id, $deal_cid, $filename, $data_cid, $piece_cid, $start_epoch, $full_url"
        # boostd import-data [command options] <proposal CID> <file> or <deal UUID> <file>
        CMD="boostd import-data $deal_cid $CAR_ROOT_PATH/$filename"
        echo "[Importing]: $CMD"
        $CMD
    done
} < $MANIFEST_CSV_FILENAME
