{ }:

let

#pkgsSrc = builtins.fetchTarball {
#    name = "nixos-21.11";
#    url = "https://github.com/NixOS/nixpkgs/archive/21.11.tar.gz";
#    sha256 = "162dywda2dvfj1248afxc45kcrg83appjd0nmdb541hl7rnncf02";
#};

#pkgs = (import pkgsSrc {});

pkgs = import <nixpkgs> {};

zig = pkgs.stdenv.mkDerivation {
        name = "zig";
        src = fetchTarball (
            if (pkgs.system == "x86_64-linux") then {
                url = "https://ziglang.org/builds/zig-linux-x86_64-0.10.0-dev.3567+95573dbee.tar.xz";
                sha256 = "0l322i5s5ya7jd4fgia29insyaa4wzqxv3rmdmzjw612d3ivdc2v";
            } else
            throw ("Unknown system " ++ pkgs.system)
        );
        dontConfigure = true;
        dontBuild = true;
        installPhase = ''
            mkdir -p $out
            mv ./* $out/
            mkdir -p $out/bin
            mv $out/zig $out/bin
        '';
    };

in

pkgs.mkShell rec {
    buildInputs = [
        #pkgs.clojure
        #pkgs.jre
        #pkgs.nixopsUnstable
        zig
    ];
    #shellHook = ''
    #    export NIX_PATH=${pkgs.path}:nixpkgs=${pkgs.path}:.
    #'';
}