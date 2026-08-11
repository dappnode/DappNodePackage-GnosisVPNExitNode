{ pkgs ? import <nixpkgs> { }, ... }:
let
  linuxPkgs = with pkgs; lib.optional stdenv.isLinux (
    inotifyTools
  );
in
with pkgs;
mkShell {
  buildInputs = [
    ## base
    envsubst

    # build utils
    just
    nodejs_22

    # custom pkg groups
    linuxPkgs
  ];
  shellHook = ''
    npm install
  '';
}
