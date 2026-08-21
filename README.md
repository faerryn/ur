# Ur
A Zig / ZLS version manager, written in Zig.

```
A Zig/ZLS version manager, written in zig.

Usage: ur [COMMAND] [<ARGS>]
Usage: zig [<ARGS>]
Usage: zls [<ARGS>]

Commands:
  help                    Display this help message.
  install (SPEC)?         Install SPEC.
  uninstall [SPEC]        Uninstall SPEC
  list (all|installed)?   List versions for your architecture, or all versions, or just the ones installed.
  (SPEC)? [<ARGS>]        Run program specified by SPEC, passing [<ARGS>].
  version                 Print the version of ur.

Specs:
  (zig|zls)?(-ARCH)?(-OS)?(-VERSION)?
```

# Example

```bash
# zig, zls are both symlinked to ur
$ ls
build.zig build.zig.zon src/
$ zig build # ur will check build.zig.zon and match the version specified there
$ "$EDITOR" src/main.zig # ZLS version will match Zig version!
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
Instead of typing `ur zig` or using an alias (which is undetectable by some build tools),
you can install a symlink or shell script shim. Ur will detect its own `argv[0]` being
a valid SPEC and download and shim to the appropriate tool.

```bash
ln -s ur "$HOME/.local/bin/zig"
```

## Ziggurat of Ur

A ziggurat, probably not written in Zig.

<img width="3366" height="1468" alt="image" src="https://github.com/user-attachments/assets/9e64e9b4-be0a-49b2-854c-68197bcae7b8" />
