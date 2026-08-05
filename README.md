# Rust Bacon Visuals and Sounds

An animated terminal dashboard for [bacon](https://dystroy.org/bacon), the
background Rust code checker. Drop `bacon.toml` and `bacon-tui.sh` into a Rust
project and get a live scene that turns green when the build is clean, amber
while compiling, and pulses red on errors — with sound.

## Install

Install bacon with the `sound` feature (required for the success/failure chimes
configured in `bacon.toml`):

```sh
cargo install --locked --features sound bacon
```

## Run

The animated dashboard, which runs `bacon --headless` for you and renders its
JSON report:

```sh
./bacon-tui.sh            # job defaults to check
./bacon-tui.sh clippy     # check | check-all | clippy | test
```

Plain bacon, using this repo's `bacon.toml`:

```sh
bacon              # default job: check
bacon clippy       # or check-all, test
```

Keys: `q` quit · `1`-`4` switch job · `r` rerun · `l` cycle log view · `p` pause
animation.

Needs a truecolor terminal (iTerm2, WezTerm, Ghostty, Kitty, or tmux with 24-bit
color).
