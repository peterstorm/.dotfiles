#!/bin/sh
nix build --impure .#homeManagerConfigurations.$USER.activationPackage
result/activate
