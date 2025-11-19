# Ur
A zig version manager, written in zig.

```
A zig version manager, written in zig.

Usage: ur [COMMAND] [<ARGS>]
Usage: zig (SPEC)? [<ARGS>]

Commands:
  help                    Display this help message.
  install (SPEC)?         Install SPEC.
  uninstall [SPEC]        Uninstall SPEC
  list (all|installed)?   List versions for your architecture, or all versions, or just the ones installed.
  zig (SPEC)? [<ARGS>]    Run SPEC with [<ARGS>].
  version                 Print the version of ur.
```

## Installation
As of now, you need Zig to compile Ur to install Zig...

We'll have binary releases once Ur is stable enough!

```bash
git clone https://github.com/faerryn/ur.git
cd ur/
zig build --prefix "$HOME/.local" --release=fast 
```

## Drop-in replacement
Instead of typing `ur zig` or using an alias, which is not detectable by some tooling, you can install a symlink or shell script shim! You can still specify a verison with `zig SPEC ...`.

### Symlink
```bash
ln -s ur "$HOME/.local/bin/zig"
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
