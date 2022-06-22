#!/usr/bin/env bash

set -euxo pipefail

cd "$(dirname "$(readlink -f "$0")")"

rm -rf ./out
clj -M --main cljs.main --optimizations simple --compile preimp.core
clj -T:build build/uber
nixops deploy -d preimp