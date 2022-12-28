#!/bin/bash
# Common functions.

if [[ -z "$HOME" ]]; then
    echo "HOME undefined." 1>&2
    exit 1
fi

function _echo() {
    echo `date -u +"%Y-%m-%dT%H:%M:%SZ"`"#$1"
}

function _error() {
    _echo "ERROR: $1"
    exit 1
}

function _exec() {
    CMD=$@
    _echo "executing: $CMD"
    $CMD
}

# Retries a command on failure. Increasing backoff interval.
# $1 - the max number of attempts
# $2... - the command to run
# example:
#   retry 5 ls -ltr foo
function retry() {
    local -r -i max_attempts="$1"; shift
    local -r cmd="$@"
    local -i attempt_num=1
    until $cmd
    do
        if (( attempt_num == max_attempts ))
        then
            _error "exceeded $attempt_num retries executing: $cmd"
        else
            echo "Attempt $attempt_num failed. Trying again in $attempt_num seconds..."
            sleep $(( attempt_num++ ))
        fi
    done
}

# increase limits for Singularity
ulimit -n 100000
