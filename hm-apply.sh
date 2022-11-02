#!/bin/sh
nix build .#homeManagerConfigurations.$USER.activationPackage
result/activate
