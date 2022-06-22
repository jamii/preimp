#!/usr/bin/env bash

set -euxo pipefail

cd "$(dirname "$(readlink -f "$0")")"

clj -T:build build/prod
nixops deploy -d preimp