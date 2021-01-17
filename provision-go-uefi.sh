#!/bin/bash
set -euxo pipefail

# install.
# see https://github.com/Foxboron/go-uefi
# TODO lock the version.
go get -v github.com/Foxboron/go-uefi/cmd/efianalyze
