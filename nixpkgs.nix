let source =
    rec {
      owner = "NixOS";
      repo = "nixpkgs-channels";
      rev = "0a7e258012b60cbe530a756f09a4f2516786d370";
      sha256 = "1qcnxkqkw7bffyc17mqifcwjfqwbvn0vs0xgxnjvh9w0ssl2s036";
      name = "nixpkgs${rev}";
    };
    fetch = (import <nixpkgs> {}).fetchFromGitHub;
in
import (fetch (source))
