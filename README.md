# Ur
A zig version manager, written in zig.

```
A zig version manager, written in zig.

Usage: ur [COMMAND] [<ARGS>]
Usage: zig [<ARGS>]

Commands:
  help                    Display this help message.
  install (SPEC)?         Install SPEC.
  uninstall [SPEC]        Uninstall SPEC
  list (all|installed)?   List versions for your architecture, or all versions, or just the ones installed.
  zig (SPEC)? [<ARGS>]    Run SPEC with [<ARGS>].
  version                 Print the version of ur.
```

## Drop-in replacement
Instead of typing `ur zig` or using an alias, which is not detectable by some tooling, you can install a symlink or shell script shim!

### Symlink
```bash
ln -s "$HOME/.local/bin/ur" "$HOME/.local/bin/zig"
```

### Shell Shim
In an executable file named `zig` in you `$PATH`:

```bash
#!/bin/sh
exec ur zig "$@"
```

## Ziggurat

A ziggurat, probably not written in zig.

<img width="3366" height="1468" alt="image" src="https://github.com/user-attachments/assets/9e64e9b4-be0a-49b2-854c-68197bcae7b8" />
