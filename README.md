# Mavenix

Deterministic Maven builds using Nix?

## Install

First you need to install the [Nix package manager](https://nixos.org/nix/), if
you already haven't.

```sh
nix-env -i -f https://github.com/icetan/mavenix/archive/master.tar.gz
```

## Usage

First we need to create some stub Nix expression files. `cd` into your maven
project directory and run:

```sh
mvnix-init
```

Follow the instructions displayed.
