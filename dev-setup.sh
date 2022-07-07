#!/usr/bin/env bash

cd "$(dirname "$(readlink -f "$0")")"

rm -rf ./out

swaymsg workspace 0
alacritty --working-directory ./ -e nix-shell --run 'clj -M --main cljs.main --watch src --compile preimp.core' &
alacritty --working-directory ./ -e nix-shell --run 'clj -X preimp.server/-main' &

sleep 1 # :(

swaymsg workspace 1
$EDITOR ./src/preimp/core.clj &

sleep 1 # :(

swaymsg workspace 2
$EDITOR ./src/preimp/core.cljs &
$BROWSER localhost:3000 &