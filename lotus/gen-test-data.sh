#!/bin/bash
#!/bin/bash
# Create random test files.
# Examples, 
# * create 10 test files of 1KB size
#	gen-test-data.sh -c 10 -s 1024 -p kilo -d /tmp/test
# * create 1 test file of 1MB size
#	gen-test-data.sh -c 1 -s 1048576 -p mega -d /tmp/test
# * create 2 test files of 1GB size
#   gen-test-data.sh -c 2 -s 1073741824 -p giga -d /tmp/test
#

while getopts c:s:p:d: flag
do
    case "${flag}" in
        c) filecount=${OPTARG};;
        s) filesize=${OPTARG};;
        p) prefix=${OPTARG};;
        d) dirname=${OPTARG};;
    esac
done

[[ -z "$filecount" ]] && { echo "filecount is required" ; exit 1; }
[[ -z "$filesize" ]] && { echo "filesize bytes is required" ; exit 1; }
[[ -z "$prefix" ]] && { echo "prefix is required" ; exit 1; }
[[ -z "$dirname" ]] && { echo "dirname is required" ; exit 1; }
echo "count of files to generate: $filecount; size per file (Bytes): $filesize; dir: $dirname; prefix: $prefix";
mkdir -p "$dirname"
while [ $filecount -gt 0 ]; do
    block_size=1024
    count_blocks=$(( $filesize/$block_size ))
    CMD="dd if=/dev/urandom of="$dirname/$prefix-$filecount" bs=$block_size count=$count_blocks iflag=fullblock"
    echo "executing: $CMD"
    $CMD
    ((filecount-=1))
done
