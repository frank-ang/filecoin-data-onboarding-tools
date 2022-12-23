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

# increase limits for Singularity
ulimit -n 100000
