#!/bin/bash

set -o errexit
set -o nounset

export TESTCASE="$1"

export SCRIPT_DIR="$( cd "$( dirname "$0" )" && pwd )"

if [ -d "${TESTCASE}" ]; then
    NUM=$(ls "${TESTCASE}/"*.essence 2> /dev/null | grep -v disabled.essence | wc -l)
    if [ "$NUM" -eq "1" ]; then
        echo "Generating random perturbations in ${TESTCASE}"
        parallel runhaskell ${SCRIPT_DIR}/gen.hs "delete" "${TESTCASE}" "${TESTCASE}/"*.essence ::: $(seq -w 1 10)
        parallel runhaskell ${SCRIPT_DIR}/gen.hs "change" "${TESTCASE}" "${TESTCASE}/"*.essence ::: $(seq -w 1 10)
    fi
fi
