# Syncthing engine

SeqPoint embeds Syncthing v2.1.7, commit
`d6d0181f7d466381c4b39ec8fd944c364f939b32`, under the Mozilla Public
License 2.0 (see LICENSE).

Copyright © The Syncthing Authors.
Source: https://github.com/syncthing/syncthing/tree/d6d0181f7d466381c4b39ec8fd944c364f939b32

The upstream engine source is unmodified. SeqPoint's lifecycle bridge and
reproducible build instructions are in this directory. Dependencies are pinned
in go.mod and go.sum. Desktop builds use the official command; mobile builds
use the official library through gomobile. GUI assets are excluded; REST and
BEP are unchanged. Generated binaries are packaged with the application.

Android builds set `-checklinkname=0`, as required by the upstream anet network
interface compatibility library on Go 1.23 and later.
