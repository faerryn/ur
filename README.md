A zig version manager, written in zig.
```
Usage: ./zig-out/bin/ur [COMMAND] [<ARGS>]

Commands:
  help                              Display this help message.
  install [VERSION] (TARGET)?       Install VERSION for your architecture, or for TARGET.
  list (*available|all|installed)?  List versions for your architecture; or all zig versions; or installed zig versions.
  zig (VERSION)? [<ARGS>]           Run zig with [<ARGS>], parsing build.zig.zon for the version. Override with VERSION.
```
