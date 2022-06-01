{ }:

let

pkgsSrc = builtins.fetchTarball {
    name = "nixos-21.11";
    url = "https://github.com/NixOS/nixpkgs/archive/21.11.tar.gz";
    sha256 = "162dywda2dvfj1248afxc45kcrg83appjd0nmdb541hl7rnncf02";
};

pkgs = (import pkgsSrc {});

in

pkgs.mkShell rec {
    buildInputs = [
        pkgs.clojure
        pkgs.jre_minimal
        pkgs.nixopsUnstable
    ];
    shellHook = ''
        export NIX_PATH=${pkgs.path}:nixpkgs=${pkgs.path}:.
    '';
}