#!/bin/sh
nix build .#homeManagerConfigurations.$USER.activationPackage --impure
result/activate
