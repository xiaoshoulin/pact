{ rpRef ? "f3ff81d519b226752c83eefd4df6718539c3efdc", rpSha ?  "1ijxfwl36b9b2j4p9j3bv8vf7qfi570m1c5fjyvyac0gy0vi5g8j" }:

let rp = builtins.fetchTarball {
  url = "https://github.com/reflex-frp/reflex-platform/archive/${rpRef}.tar.gz";
  sha256 = rpSha;
};

in
  (import rp {}).project ({ pkgs, ... }: {
    name = "seal";
    overrides = self: super:
      let guardGhcjs = p: if self.ghc.isGhcjs or false then null else p;
       in {
            seal = pkgs.haskell.lib.addBuildDepend super.seal pkgs.z3;
            haskeline = guardGhcjs super.haskeline;

            # Needed to get around a requirement on `hspec-discover`.
            megaparsec = pkgs.haskell.lib.dontCheck super.megaparsec;

            hedgehog = self.callCabal2nix "hedgehog" (pkgs.fetchFromGitHub {
              owner = "hedgehogqa";
              repo = "haskell-hedgehog";
              rev = "38146de29c97c867cff52fb36367ff9a65306d76";
              sha256 = "1z8d3hqrgld1z1fvjd0czksga9lma83caa2fycw0a5gfbs8sh4zh";
            } + "/hedgehog") {};
            hlint = self.callHackage "hlint" "2.0.14" {};
            # hoogle = self.callHackage "hoogle" "5.0.15" {};

            # sbv >= 7.9
            sbv = pkgs.haskell.lib.dontCheck (self.callCabal2nix "sbv" (pkgs.fetchFromGitHub {
              owner = "LeventErkok";
              repo = "sbv";
              rev = "9fe20e5586e1f9fe57badfaa8d7c3277e6822322";
              sha256 = "1n1l3lw6i5h9kvjbcw05548nnsnkgm9j0jwzjmp1kabnc0hiv1c8";
            }) {});
         
            algebraic-graphs = pkgs.haskell.lib.dontCheck (self.callCabal2nix "algebraic-graphs" (pkgs.fetchFromGitHub {
              owner = "snowleopard";
              repo = "alga";
              rev = "ba51378ce960782b959ff3298dd015bc9ef42e46";
              sha256 = "0kzbwdlwqqw7yazlcqwdk5fr5rzrfg011r6cpwrq4qbqgmng9768";
            }) {});

            # Our own custom fork
            thyme = pkgs.haskell.lib.dontCheck (self.callCabal2nix "thyme" (pkgs.fetchFromGitHub {
              owner = "kadena-io";
              repo = "thyme";
              rev = "6ee9fcb026ebdb49b810802a981d166680d867c9";
              sha256 = "09fcf896bs6i71qhj5w6qbwllkv3gywnn5wfsdrcm0w1y6h8i88f";
            }) {});

            # weeder = self.callHackage "weeder" "1.0.5" {};
            weeder = self.callCabal2nix "weeder" (pkgs.fetchFromGitHub {
              owner = "ndmitchell";
              repo = "weeder";
              rev = "56b46fe97782e86198f31c574ac73c8c966fee05";
              sha256 = "005ks2xjkbypq318jd0s4896b9wa5qg3jf8a1qgd4imb4fkm3yh7";
            }) {};
          };
    packages = {
      seal = builtins.filterSource
        (path: type: !(builtins.elem (baseNameOf path)
           ["result" "dist" "dist-ghcjs" ".git" ".stack-work"]))
        ./.;
    };
    shellToolOverrides = ghc: super: {
      z3 = pkgs.z3;
      stack = pkgs.stack;
    };
    shells = {
      ghc = ["seal"];
      # ghcjs = ["seal"];
    };

  })
