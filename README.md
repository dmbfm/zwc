# zwc: a clone of the `wc` utility written in ZIG

That's it. Just a line/word/character counter written in zig for learning purposes.

## Building and Installation

Assuming you have zig installed and that `~/.local/bin` is in your path:

```
$ zig build -Drelease-fast -p ~/.local/bin
$ echo "hello" | zwc
    1    1    6
```
