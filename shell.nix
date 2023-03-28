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

url = "https://ziglang.org/download/0.10.0/zig-linux-x86_64-0.10.0.tar.xz";
sha256 = "0x0dl4dsanyabmxdvjid4zmd1ba0xzi7gs0n69qy0giwfr6h43vi";

##                url = "https://ziglang.org/builds/zig-linux-x86_64-0.11.0-dev.2287+1de64dba2.tar.xz";
###https://ziglang.org/builds/zig-0.11.0-dev.2287+1de64dba2.tar.xz
##                sha256 = "1ir98lfwzgbkipp0fd6xcsgl2sx05sriabn330ikw94pidy3s1s0";
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
