# Anime4KMetal vendoring notes

This directory is based on `cinemore/anime4k-metal` version `0.1.4`:

https://github.com/cinemore/anime4k-metal/tree/0.1.4

AnimeCloud carries two integration-only changes:

- The command-line target and its unrelated argument-parser dependency are omitted.
- The shader build plugin can locate Xcode 26's downloaded Metal toolchain before
  falling back to the traditional `xcrun --find` lookup.

The original MIT license and upstream third-party notices are included alongside
this file.
