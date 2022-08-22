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
                url = "https://ziglang.org/builds/zig-linux-x86_64-0.10.0-dev.3672+cd5a9ba1f.tar.xz";
                sha256 = "0gqlwis8d5mm7rvi6azjl8vwvpy51r8jrby8a06cw3wgz817sv8d";
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
        pkgs.glfw
    ];
    #shellHook = ''
    #    export NIX_PATH=${pkgs.path}:nixpkgs=${pkgs.path}:.
    #'';
}