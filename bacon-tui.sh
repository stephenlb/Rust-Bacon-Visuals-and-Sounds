#!/bin/bash
# bacon-tui.sh — animated terminal dashboard for bacon
#
#   ./bacon-tui.sh [job]        # job defaults to `check`
#   ./bacon-tui.sh --list-scenes        # every scene name, by state
#   ./bacon-tui.sh --scene carousel     # preview one scene, no bacon needed
#
# It runs `bacon --headless` for you, telling bacon to auto-export a machine
# readable report after every mission (`[exports.json_report]`), and tails
# bacon's own output into a log file. The report drives the animation:
#
#   errors / test failures  ->  one of twenty-seven fail scenes, at random
#                               (red pulse · thunderstorm · signal glitch ·
#                                lava · matrix rain · alarm klaxon ·
#                                crumbling wall · vortex · ember storm ·
#                                shattered glass · bug swarm · meltdown ·
#                                earthquake · corrosion · deep freeze ·
#                                flood · cut cables · sandstorm ·
#                                seized gears · tar pit · derailment ·
#                                avalanche · black hole · locust plague ·
#                                sinking ship · swamp · creeping rot)
#   clean                   ->  one of twenty-seven success scenes, at random
#                               (sunny meadow · starry night · fireworks ·
#                                aurora · sunrise at sea · balloons ·
#                                rainbow · coral reef · confetti ·
#                                cherry blossom · ringed planet · ripples ·
#                                sky lanterns · fireflies · zen garden ·
#                                wheat field · sunlit forest · summit ·
#                                waterfall · hearth · steam train ·
#                                lighthouse · kites · carousel ·
#                                snowy village · desert meteors ·
#                                rainy window with a storm going by)
#   compiling               ->  amber shimmer
#
# A fresh variant is drawn each time the state flips, and never the same one
# twice in a row.
#
# Keys: q quit · 1-4 switch job · r rerun · l cycle log view · p pause anim
#       --scene mode: q quit · n/N next/prev scene · p pause anim
#
# Requires a truecolor terminal (iTerm2, WezTerm, Ghostty, Kitty, tmux with
# `set -g allow-passthrough`/24-bit color, modern Terminal.app fallback ok).
#
# Rendering notes (why this stays flicker-free at ~14fps in bash 3.2):
#   * every frame is one write bracketed in DEC mode 2026 (synchronized
#     output), so the terminal swaps a finished frame instead of showing our
#     paint order. Terminals without 2026 ignore the private mode.
#   * nothing clears the screen mid-loop; a clear is folded into the frame.
#   * anything that does not change per frame (gradient fill strings, per-row
#     styles, the hill ridge, block-font banners, the pulsing backdrops) is
#     computed once and replayed from cache.
#   * forks are kept off the render path: no `date`/`sleep`-per-draw, the
#     report poll and log tail are throttled, and identical frames are not
#     rewritten at all.

set -u

# ---------------------------------------------------------------- setup ------

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
cd "$SCRIPT_DIR" || exit 1

case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *UTF-8*|*utf8*) : ;;
    *) export LC_ALL=en_US.UTF-8 ;;   # substring math on block glyphs
esac

JOBS=(check check-all clippy test)
JOB=check
REPORT=.bacon-report.json
LOG=.bacon-tui.log
FRAME_SLEEP=0.07
POLL_EVERY=7          # frames between report/source polls  (~0.5s)
LOG_EVERY=6           # frames between log tails            (~0.4s)
OK_DELAY_MS=800       # hold the building scene this long after a pass, so the
                      # success sound has time to play before the scene flips
                      # to grass and sky
FRAME_OVERHEAD_MS=30  # render + poll + drain per frame, on top of FRAME_SLEEP;
                      # measured ~30ms, so a frame costs ~100ms not 70ms

BACON_CONFIG='
[exports.json_report]
auto = true
exporter = "json_report"
path = ".bacon-report.json"
'

# ------------------------------------------------------------------- args ----

# SCENE_ONLY pins one variant and runs the loop without bacon, so a scene can be
# looked at on its own. The variant tables live further down (they name functions
# defined between here and there), so --scene only records the request; it is
# resolved in main, once the tables exist.
SCENE_ONLY=""
LIST_SCENES=0

usage() {
    cat <<'EOF'
usage: bacon-tui.sh [job] [options]

  job                  bacon job to run: check (default), check-all, clippy, test

  --scene NAME         skip bacon and show one scene on a loop, for previewing.
                       NAME is a variant from --list-scenes, with or without its
                       scene_ok_ / scene_fail_ prefix ("carousel", "fail:lava").
                       Fail scenes are shown with a sample failure list.
  --list-scenes        print every scene name, grouped by state, and exit
  -h, --help           this message

keys: q quit · 1-4 switch job · r rerun · l cycle log view · p pause anim
      in --scene mode: n/N step to the next/previous scene of that state
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --scene)
            [ $# -ge 2 ] || { echo "--scene needs a scene name" >&2; exit 2; }
            SCENE_ONLY=$2; shift 2 ;;
        --scene=*)   SCENE_ONLY=${1#*=}; shift ;;
        --list-scenes) LIST_SCENES=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        -*)          echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
        *)           JOB=$1; shift ;;
    esac
done

# --scene and --list-scenes never shell out to bacon, so they work anywhere
if [ -z "$SCENE_ONLY" ] && (( ! LIST_SCENES )); then
    command -v bacon >/dev/null 2>&1 ||
        { echo "bacon not found in PATH" >&2; exit 1; }
fi

# sine lookup, 60 steps, scaled 0..999 (no floating point in bash)
SIN=($(awk 'BEGIN{for(i=0;i<60;i++)printf "%d ",500+499*sin(6.28318530718*i/60)}'))

# 5x5 block font, only the letters the banners need
F_A=(" ### " "#   #" "#####" "#   #" "#   #")
F_B=("#### " "#   #" "#### " "#   #" "#### ")
F_D=("#### " "#   #" "#   #" "#   #" "#### ")
F_E=("#####" "#    " "#### " "#    " "#####")
F_F=("#####" "#    " "#### " "#    " "#    ")
F_G=(" ####" "#    " "#  ##" "#   #" " ### ")
F_I=("#####" "  #  " "  #  " "  #  " "#####")
F_L=("#    " "#    " "#    " "#    " "#####")
F_N=("#   #" "##  #" "# # #" "#  ##" "#   #")
F_O=(" ### " "#   #" "#   #" "#   #" " ### ")
F_U=("#   #" "#   #" "#   #" "#   #" " ### ")
F_SP=("     " "     " "     " "     " "     ")

# ------------------------------------------------------------- terminal ------

term_size() {
    local sz
    sz=$(stty size 2>/dev/null <"$TTY")
    H=${sz% *}; W=${sz#* }
    [ -n "${H:-}" ] || H=24
    [ -n "${W:-}" ] || W=80
    (( H < 8 )) && H=8
    (( W < 30 )) && W=30
    # exactly W wide, so fills and padding never need re-slicing
    printf -v SPACES "%${W}s" ""
    DASHES=${SPACES// /─}
    SCENE_H=0          # invalidate the cached palette / scene geometry
    LOG_DIRTY=1
}

RESIZED=0
on_winch() { RESIZED=1; }

stop_bacon() {
    # never `kill 0` — that signals our whole process group, us included
    [ -n "${BACON_PID:-}" ] && [ "$BACON_PID" -gt 0 ] 2>/dev/null &&
        kill "$BACON_PID" 2>/dev/null
    BACON_PID=""
    return 0
}

cleanup() {
    trap - EXIT INT TERM
    stop_bacon
    [ -n "${READER_PID:-}" ] && [ "$READER_PID" -gt 0 ] 2>/dev/null &&
        kill "$READER_PID" 2>/dev/null
    [ -n "${KEYFILE:-}" ] && rm -f "$KEYFILE"
    [ -n "${SAVED_STTY:-}" ] && stty "$SAVED_STTY" <"$TTY" 2>/dev/null
    printf '\033[?2026l\033[?25h\033[0m\033[?1049l'
    exit 0
}

# bash's `read -n1` forces VMIN=1, so it blocks however the tty is configured.
# A background reader keeps the blocking read off the render loop: it drops each
# keystroke into a file the loop drains without ever waiting.
start_reader() {
    KEYFILE=${TMPDIR:-/tmp}/bacon-tui-keys.$$
    : > "$KEYFILE"
    (
        while IFS= read -rn1 k <"$TTY"; do
            [ -n "$k" ] && printf '%s' "$k" >>"$KEYFILE"
        done
    ) &
    READER_PID=$!
}

# KEYS = everything typed since the last frame (usually empty)
drain_keys() {
    KEYS=""
    [ -s "$KEYFILE" ] || return
    IFS= read -rd '' KEYS <"$KEYFILE" 2>/dev/null
    : > "$KEYFILE"
}

# ---------------------------------------------------------------- bacon ------

start_bacon() {
    local old=${BACON_PID:-}
    stop_bacon
    [ -n "$old" ] && wait "$old" 2>/dev/null
    rm -f "$REPORT"
    : > "$LOG"
    bacon --headless -j "$JOB" --config-toml "$BACON_CONFIG" >>"$LOG" 2>&1 &
    BACON_PID=$!
    REPORT_MTIME=0
    BUILD_START=$(now)
    LOG_DIRTY=1
}

# stats from the exported report; leaves previous values on a partial read
read_stats() {
    local out e w t
    out=$(awk '
        /"stats"/          {f=1}
        f && /"errors"/    {s=$0; gsub(/[^0-9]/,"",s); e=s}
        f && /"warnings"/  {s=$0; gsub(/[^0-9]/,"",s); w=s}
        f && /"test_fails"/{s=$0; gsub(/[^0-9]/,"",s); t=s}
        END{ if(e=="")e=0; if(w=="")w=0; if(t=="")t=0; printf "%s %s %s", e, w, t }
    ' "$REPORT" 2>/dev/null)
    set -- $out
    [ $# -eq 3 ] || return
    ERRORS=$1; WARNINGS=$2; TEST_FAILS=$3
    CMD_ERROR=0
    grep -q '"error_code": *[0-9]' "$REPORT" 2>/dev/null && CMD_ERROR=1
}

# the failing items, one display line each (title, then its location)
read_items() {
    ITEMS=()
    local line
    while IFS= read -r line; do
        ITEMS[${#ITEMS[@]}]=$line
    done < <(awk '
        function val(s) {
            sub(/^[[:space:]]*"raw": "/, "", s)
            sub(/",?$/, "", s)
            gsub(/\\"/, "\"", s); gsub(/\\\\/, "\\", s); gsub(/\\n/, " ", s)
            return s
        }
        /"item_idx"/                     { if (keep && txt != "") print txt; txt=""; keep=0; next }
        /"Title": "(Error|TestFail)"/    { keep=1; err=1; next }
        /"line_type": "Location"/        { if (err) keep=1; next }
        /"Title": "Warning"/             { err=0; next }
        /"raw":/                         { if (keep) txt = txt val($0) }
        END                              { if (keep && txt != "") print txt }
    ' "$REPORT" 2>/dev/null | head -n 14)
}

# ----------------------------------------------------------------- clock -----

# `date` is a fork; SECONDS is a builtin. One fork at startup covers the rest.
EPOCH0=$(date +%s)
now() { printf '%s' $(( EPOCH0 + SECONDS )); }

# ---------------------------------------------------------------- colors -----

sty() { # fg r g b, bg r g b -> STY
    STY=$'\033[38;2;'"$1;$2;$3"$'m\033[48;2;'"$4;$5;$6"m
}

# BG_KIND selects how sty_row resolves the backdrop under an overlay. Using
# \033[49m instead would punch default-background holes in the scene.
#   1 fail pulse (formula)  2 building pulse (formula)  3 sky/hill
#   4 per-row table (BGROW_*, filled by the scene)  0 flat
#   5 window pane (PANE_*, filled by the window scene's frame rasterizer)
BG_KIND=0
BG_LVL=0
bg_at() { # row -> BGR BGG BGB
    local t
    case $BG_KIND in
        1) t=$(( BG_LVL * (620 + 380 * $1 / H) / 1000 ))
           BGR=$(( 12 + 210 * t / 1000 ))
           BGG=$(( 6  + 26  * t / 1000 ))
           BGB=$(( 8  + 30  * t / 1000 )) ;;
        2) t=$(( BG_LVL * (500 + 500 * $1 / H) / 1000 ))
           BGR=$(( 40 + 150 * t / 1000 ))
           BGG=$(( 24 + 100 * t / 1000 ))
           BGB=$(( 6  + 20  * t / 1000 )) ;;
        3) if (( $1 < HZ )); then
               BGR=${SKY_R[$1]}; BGG=${SKY_G[$1]}; BGB=${SKY_B[$1]}
           else
               BGR=${HILL_R[$1]:-0}; BGG=${HILL_G[$1]:-0}; BGB=${HILL_B[$1]:-0}
           fi ;;
        4) BGR=${BGROW_R[$1]:-12}; BGG=${BGROW_G[$1]:-12}; BGB=${BGROW_B[$1]:-16} ;;
        5) if [ -n "${PANE_R[$1]:-}" ]; then
               BGR=${PANE_R[$1]}; BGG=${PANE_G[$1]}; BGB=${PANE_B[$1]}
           else
               BGR=${BGROW_R[$1]:-12}; BGG=${BGROW_G[$1]:-12}; BGB=${BGROW_B[$1]:-16}
           fi ;;
        *) BGR=12; BGG=12; BGB=16 ;;
    esac
}

sty_row() { # fg r g b, row
    bg_at "$4"
    sty "$1" "$2" "$3" "$BGR" "$BGG" "$BGB"
}
sty_over() { sty_row "$1" "$2" "$3" "$4"; }   # kept for readability at call sites

# Per-row gradients plus every string derived from them. Called once per
# distinct scene height (resize or view change), not per frame.
palette() {
    HZ=$(( H * 62 / 100 ))          # horizon row
    (( HZ < 4 )) && HZ=4
    (( HZ > H-3 )) && HZ=$((H-3))
    local r t g

    SKY_R=(); SKY_G=(); SKY_B=(); SKY_FILL=(); CLOUD_STY=(); BIRD_STY=()
    for (( r=1; r<=HZ+2; r++ )); do
        t=$(( (r-1)*1000 / HZ ))
        SKY_R[$r]=$(( 30  + (172*t)/1000 ))
        SKY_G[$r]=$(( 104 + (114*t)/1000 ))
        SKY_B[$r]=$(( 196 + (52*t)/1000 ))
        SKY_FILL[$r]=$'\033['"$r;1H"$'\033[39m\033[48;2;'"${SKY_R[$r]};${SKY_G[$r]};${SKY_B[$r]}"m"$SPACES"
        sty 252 253 255 "${SKY_R[$r]}" "${SKY_G[$r]}" "${SKY_B[$r]}"; CLOUD_STY[$r]=$STY
        sty 35 42 58    "${SKY_R[$r]}" "${SKY_G[$r]}" "${SKY_B[$r]}"; BIRD_STY[$r]=$STY
    done

    HILL_R=(); HILL_G=(); HILL_B=(); HILL_FILL=()
    FLW_A=(); FLW_B=(); FLW_C=(); FLW_D=()
    local span=$(( H - HZ ))
    (( span < 1 )) && span=1
    for (( r=HZ; r<=H; r++ )); do
        t=$(( (r-HZ)*1000 / span ))
        HILL_R[$r]=$(( 124 - (98*t)/1000 ))
        HILL_G[$r]=$(( 202 - (94*t)/1000 ))
        HILL_B[$r]=$(( 96  - (48*t)/1000 ))
        HILL_FILL[$r]=$'\033['"$r;1H"$'\033[39m\033[48;2;'"${HILL_R[$r]};${HILL_G[$r]};${HILL_B[$r]}"m"$SPACES"
        sty 250 236 120 "${HILL_R[$r]}" "${HILL_G[$r]}" "${HILL_B[$r]}"; FLW_A[$r]=$STY
        sty 252 200 224 "${HILL_R[$r]}" "${HILL_G[$r]}" "${HILL_B[$r]}"; FLW_B[$r]=$STY
        sty 250 250 250 "${HILL_R[$r]}" "${HILL_G[$r]}" "${HILL_B[$r]}"; FLW_C[$r]=$STY
        g=$(( ${HILL_G[$r]} + 46 )); (( g > 255 )) && g=255
        sty $(( ${HILL_R[$r]} + 20 )) "$g" "${HILL_B[$r]}" \
            "${HILL_R[$r]}" "${HILL_G[$r]}" "${HILL_B[$r]}"; FLW_D[$r]=$STY
    done

    # the cat's feet row: mid-meadow, never on the status bar
    CAT_BASE=$(( HZ + 3 + (H - HZ - 4) / 2 ))
    (( CAT_BASE > H-1 )) && CAT_BASE=$(( H - 1 ))
    (( CAT_BASE < HZ + 3 )) && CAT_BASE=$(( HZ + 3 ))

    build_ridge
    FAILBG=(); BLDBG=()             # pulsing backdrops depend on H
    SCENE_H=$H
}

# ------------------------------------------------------------- primitives ----

OUT=""

# Scenes that need a backdrop the per-row formulas in bg_at() cannot express
# (night gradients, storm slate, glitch bands) fill this table instead: one
# rgb triple plus one ready-to-write fill string per row, rebuilt only when
# BG_KEY changes (scene name + height), then replayed like the cached pulses.
BG_KEY=""
BGROW_R=(); BGROW_G=(); BGROW_B=(); BGFILL=()

bgtable_reset() { BGROW_R=(); BGROW_G=(); BGROW_B=(); BGFILL=(); }

bgtable_row() { # row r g b
    BGROW_R[$1]=$2; BGROW_G[$1]=$3; BGROW_B[$1]=$4
    BGFILL[$1]=$'\033['"$1;1H"$'\033[39m\033[48;2;'"$2;$3;$4"m"$SPACES"
}

bgtable_paint() {
    local r
    for (( r=1; r<=H-1; r++ )); do OUT+=${BGFILL[$r]}; done
}

# style for text sitting on the table's backdrop at that row
bgtable_sty() { # fg r g b, row
    sty "$1" "$2" "$3" "${BGROW_R[$4]:-12}" "${BGROW_G[$4]:-12}" "${BGROW_B[$4]:-16}"
}

put() { # row col style text  (clipped to the screen)
    local r=$1 c=$2 st=$3 t=$4 len cut
    (( r < 1 || r > H )) && return
    if (( c < 1 )); then
        cut=$(( 1 - c ))
        t=${t:cut}
        c=1
    fi
    len=${#t}
    (( len == 0 )) && return
    (( c > W )) && return
    (( c + len - 1 > W )) && t=${t:0:W-c+1}
    [ -n "$t" ] || return
    OUT+=$'\033['"$r;${c}H${st}$t"
}

fill_row() { # row r g b
    OUT+=$'\033['"$1;1H"$'\033[39m\033[48;2;'"$2;$3;$4"m"$SPACES"
}

center() { # -> COL for a string length
    COL=$(( (W - $1) / 2 + 1 ))
    (( COL < 1 )) && COL=1
}

# BIG[] = 5 rows of block text for the given word
bigtext() {
    local word=$1 i n c row var
    BIG=("" "" "" "" "")
    for (( n=0; n<${#word}; n++ )); do
        c=${word:n:1}
        [ "$c" = " " ] && var=F_SP || var=F_$c
        for (( i=0; i<5; i++ )); do
            eval "row=\${$var[$i]}"
            BIG[$i]="${BIG[$i]}${row} "
        done
    done
    for (( i=0; i<5; i++ )); do
        BIG[$i]=${BIG[$i]//\#/█}
    done
    BIG_W=${#BIG[0]}
}

# The three banners never change; rasterize them once instead of per frame.
bigtext "ALL GOOD";     BANNER_OK=("${BIG[@]}");   BANNER_OK_W=$BIG_W
bigtext "BUILD FAILED"; BANNER_FAIL=("${BIG[@]}"); BANNER_FAIL_W=$BIG_W
bigtext "BUILDING";     BANNER_BLD=("${BIG[@]}");  BANNER_BLD_W=$BIG_W

# draw_big <top> <banner array name> <fr fg fb> <sr sg sb>   shadow last
draw_big() {
    local top=$1 arr=$2 fr=$3 fg=$4 fb=$5 sr=${6:-} sg=${7:-} sb=${8:-}
    local i row rows w
    eval "rows=(\"\${${arr}[@]}\"); w=\${${arr}_W}"
    center "$w"
    for (( i=0; i<5; i++ )); do
        row=$(( top + i ))
        (( row > H-2 )) && break
        if [ -n "$sr" ] && (( row+1 <= H-2 )); then
            sty_row "$sr" "$sg" "$sb" $(( row + 1 ))
            put $(( row + 1 )) $(( COL + 1 )) "$STY" "${rows[$i]}"
        fi
        sty_row "$fr" "$fg" "$fb" "$row"
        put "$row" "$COL" "$STY" "${rows[$i]}"
    done
}

# ------------------------------------------------------------- happy scene ---

CLOUD1=("   ▁▄▄▄▁   " " ▄█████████▄ " "▗█████████████▖")
CLOUD2=("  ▁▄▄▁  " "▄████████▄" "▗██████████▖")
CLOUD3=(" ▁▄▁ " "▄█████▄")

draw_clouds() {
    local f=$1 i x y span=$(( W + 34 ))
    local defs="1 3 4 2 6 7 3 9 5"      # cloud# row speed(1/10 col per frame)
    set -- $defs
    while [ $# -ge 3 ]; do
        i=$1; y=$2
        x=$(( (f * $3 / 10 + i * 41) % span - 20 ))
        local n=0 rows
        while :; do
            eval "rows=\${CLOUD$i[$n]:-}"
            [ -n "$rows" ] || break
            (( y+n >= 1 && y+n <= HZ )) &&
                put $((y+n)) $x "${CLOUD_STY[$((y+n))]}" "$rows"
            n=$((n+1))
        done
        shift 3
    done
}

SUN_RING=("      ░░░░░      " "    ░░     ░░    " "   ░         ░   " "  ░           ░  " "   ░         ░   " "    ░░     ░░    " "      ░░░░░      ")
SUN_DISC=("  █████  " " ███████ " "█████████" "█████████" "█████████" " ███████ " "  █████  ")

draw_sun() {
    local f=$1 pulse=$2
    local sr=$(( 4 + HZ / 8 )) sc=$(( W / 7 + 2 ))
    local br=$(( 214 + pulse * 40 / 1000 ))
    local gr=$(( 150 + pulse * 60 / 1000 ))
    local n row
    for n in 0 1 2 3 4 5 6; do
        row=$(( sr - 3 + n ))
        (( row < 1 || row > HZ )) && continue
        sty 255 "$gr" 120 "${SKY_R[$row]}" "${SKY_G[$row]}" "${SKY_B[$row]}"
        put "$row" $(( sc - 8 )) "$STY" "${SUN_RING[$n]}"
        sty 255 "$br" 70 "${SKY_R[$row]}" "${SKY_G[$row]}" "${SKY_B[$row]}"
        put "$row" $(( sc - 4 )) "$STY" "${SUN_DISC[$n]}"
    done
    # spokes, breathing in and out
    local long=$(( pulse > 500 ? 1 : 0 ))
    sty 255 235 130 "${SKY_R[$sr]}" "${SKY_G[$sr]}" "${SKY_B[$sr]}"
    put "$sr" $(( sc - 11 - long )) "$STY" "──"
    put "$sr" $(( sc + 10 + long )) "$STY" "──"
    (( sr-6-long >= 1 )) && {
        sty 255 235 130 "${SKY_R[$((sr-6-long))]}" "${SKY_G[$((sr-6-long))]}" "${SKY_B[$((sr-6-long))]}"
        put $(( sr - 6 - long )) "$sc" "$STY" "│"
    }
    (( sr+6+long <= HZ )) && {
        sty 255 235 130 "${SKY_R[$((sr+6+long))]}" "${SKY_G[$((sr+6+long))]}" "${SKY_B[$((sr+6+long))]}"
        put $(( sr + 6 + long )) "$sc" "$STY" "│"
    }
    for n in 0 1; do
        row=$(( sr - 4 - n ))
        if (( row >= 1 )); then
            sty 255 232 120 "${SKY_R[$row]}" "${SKY_G[$row]}" "${SKY_B[$row]}"
            put "$row" $(( sc - 6 - n )) "$STY" "╲"
            put "$row" $(( sc + 6 + n )) "$STY" "╱"
        fi
        row=$(( sr + 4 + n ))
        if (( row <= HZ )); then
            sty 255 232 120 "${SKY_R[$row]}" "${SKY_G[$row]}" "${SKY_B[$row]}"
            put "$row" $(( sc - 6 - n )) "$STY" "╱"
            put "$row" $(( sc + 6 + n )) "$STY" "╲"
        fi
    done
}

draw_birds() {
    local f=$1 i x y flap
    for i in 0 1 2; do
        x=$(( (f * 4 / 10 + i * 17) % (W + 20) - 10 ))
        y=$(( 2 + i + (HZ / 5) ))
        (( y < 1 || y > HZ )) && continue
        flap=$(( (f / 4 + i) % 2 ))
        if (( flap )); then put "$y" "$x" "${BIRD_STY[$y]}" "╲╱"
        else                put "$y" "$x" "${BIRD_STY[$y]}" "╱╲"; fi
    done
}

# The ridge is static for a given width: rasterize the two crest rows once.
# ~2.5 slow waves across the width, plus a smaller ripple, so the ridge rolls
# instead of buzzing. One style per row keeps this to two writes.
build_ridge() {
    local c blend crest top="" bot="" row
    for (( c=1; c<=W; c++ )); do
        # blend two waves to 0..999, then split the 2-row band at the midpoint
        blend=$(( ( ${SIN[$(( (c * 150 / W) % 60 ))]} * 3
                  + ${SIN[$(( (c * 380 / W) % 60 ))]} ) / 4 ))
        crest=$(( blend > 500 ? HZ : HZ + 1 ))
        if (( crest == HZ )); then
            top+="▄"; bot+="█"
        else
            top+=" "; bot+="▄"
        fi
    done
    sty "${HILL_R[$HZ]}" "${HILL_G[$HZ]}" "${HILL_B[$HZ]}" \
        "${SKY_R[$HZ]}" "${SKY_G[$HZ]}" "${SKY_B[$HZ]}"
    RIDGE_TOP=$'\033['"$HZ;1H${STY}$top"
    row=$(( HZ + 1 ))
    sty "${HILL_R[$row]}" "${HILL_G[$row]}" "${HILL_B[$row]}" \
        "${SKY_R[$row]}" "${SKY_G[$row]}" "${SKY_B[$row]}"
    RIDGE_BOT=$'\033['"$row;1H${STY}$bot"
}

draw_hills() {
    local row
    OUT+=$RIDGE_TOP
    OUT+=$RIDGE_BOT
    for (( row=HZ+2; row<=H-1; row++ )); do OUT+=${HILL_FILL[$row]}; done
}

draw_tree() {
    local tc=$(( W - W/6 )) base=$(( HZ + 3 )) n row
    (( base > H-2 )) && return
    local canopy=("  ▄███▄  " " ███████ " "█████████" " ███████ ")
    for n in 0 1 2 3; do
        row=$(( base - 4 + n ))
        (( row < 1 || row > H-1 )) && continue
        sty_over 26 118 52 "$row"
        put "$row" $(( tc - 4 )) "$STY" "${canopy[$n]}"
    done
    for n in 0 1; do
        row=$(( base + n ))
        (( row > H-1 )) && break
        sty_over 92 62 34 "$row"
        put "$row" "$tc" "$STY" "█"
    done
}

draw_meadow() {
    local f=$1 i x y sway span=$(( H - HZ - 2 ))
    (( span < 1 )) && return
    for (( i=0; i<44; i++ )); do
        # the row stride must not share a factor with span, or every flower
        # lands on the same couple of rows
        y=$(( HZ + 2 + (i * 5 + i / span) % span ))
        (( y > H-1 )) && continue
        sway=$(( ${SIN[$(( (f*2 + i*9) % 60 ))]} / 400 ))     # 0..2
        x=$(( 2 + (i * 23 + i*i*3) % (W - 3) + sway ))
        case $(( i % 5 )) in
            0) put "$y" "$x" "${FLW_A[$y]}" "✿" ;;
            1) put "$y" "$x" "${FLW_B[$y]}" "✿" ;;
            2) put "$y" "$x" "${FLW_C[$y]}" "❀" ;;
            *) put "$y" "$x" "${FLW_D[$y]}" "ψ" ;;
        esac
    done
}

# ---------------------------------------------------------------- the cat ----

# A ginger cat trots across the meadow, stopping now and then to sit and bat at
# a flower. One tick counter drives both position and gait (f/3, so ~4 cols per
# second): the crossing is split into 4 walking segments with a sit between
# each, so `tick` maps to (segment, offset) with no state to carry per frame.
CAT_BACK="    ▁▁▁▁▁"           # arched back, then the ears line up over the eyes
CAT_EARS='/\_/\'
CAT_LEGS=("   ╱▌ ▐╲" "   ▌╲ ╱▐")
CAT_SIT="   ▟▟▟▟"
CAT_TAILS=("⌒" "~" "⌢" "~")
CAT_PAUSE=18                    # ticks spent sitting at each stop

draw_cat() { # frame
    local f=$1 tick chunk seg i rem x sitting=0 sf=0 eyes tail row ear mid pr
    row=${CAT_BASE:-0}
    ear=$(( row - 2 )); mid=$(( row - 1 ))
    (( ear < 1 || row > H-1 )) && return

    seg=$(( (W + 22) / 4 ))
    (( seg < 8 )) && seg=8
    chunk=$(( seg + CAT_PAUSE ))
    tick=$(( (f / 3) % (4 * seg + 4 * CAT_PAUSE) ))
    i=$(( tick / chunk )); rem=$(( tick % chunk ))
    if (( rem < seg )); then
        x=$(( i * seg + rem ))
    else
        sitting=1; sf=$(( rem - seg )); x=$(( i * seg + seg ))
    fi
    x=$(( x - 20 ))

    eyes="o.o"
    (( sitting && (sf / 3) % 5 == 4 )) && eyes="—.—"    # a slow blink mid-sit
    tail=${CAT_TAILS[$(( (f / 4) % 4 ))]}

    sty_over 240 158 84 "$ear"
    put "$ear" "$x" "$STY" "$CAT_BACK"
    put "$ear" $(( x + 9 )) "$STY" "$CAT_EARS"
    sty_over 240 158 84 "$mid"
    put "$mid" $(( x + 2 )) "$STY" "${tail}█████( ${eyes} )"

    sty_over 214 132 66 "$row"
    if (( sitting )); then
        put "$row" "$x" "$STY" "$CAT_SIT"
        # a paw swipes between the two rows at the flower it found
        pr=$(( (sf / 2) % 2 ? mid : row ))
        sty_over 252 218 178 "$pr"
        put "$pr" $(( x + 16 )) "$STY" "▖"
        sty_over 250 236 120 "$row"
        put "$row" $(( x + 18 + (sf / 2) % 2 )) "$STY" "✿"
    else
        put "$row" "$x" "$STY" "${CAT_LEGS[$(( (f / 3) % 2 ))]}"
    fi
}

scene_ok_meadow() {
    local f=$1 r pulse
    pulse=${SIN[$(( f % 60 ))]}     # bash expands all `local` words up front
    BG_KIND=3
    for (( r=1; r<=HZ+1; r++ )); do OUT+=${SKY_FILL[$r]}; done
    draw_sun "$f" "$pulse"
    draw_clouds "$f"
    draw_birds "$f"
    draw_hills
    draw_meadow "$f"
    draw_cat "$f"        # over the flowers, so it walks in front of them
    draw_tree            # last, so flowers never punch through the trunk
    # the banner needs room below the sun (which sits at ~HZ/8 + 4, 7 rows tall)
    local top=$(( HZ - 7 ))
    if (( H >= 22 && W >= 60 && top > HZ / 8 + 8 )); then
        draw_big "$top" BANNER_OK 255 255 $(( 200 + pulse/12 ))  20 90 40
    else
        local msg="✓  ALL GOOD"
        center ${#msg}
        sty_row 255 255 220 1
        put 1 "$COL" $'\033[1m'"$STY" "$msg"
    fi
}

# --------------------------------------------------- happy scene: starry ----

# Deep blue -> indigo down the screen, a moon, drifting stars that twinkle on
# their own phase, and a shooting star that crosses every few seconds.
STAR_GLYPH=("·" "✦" "✧" "*" "⋆")
MOON=("  ▄███▄  " " ███████▖" "████████ " " ███████▘" "  ▀███▀  ")

scene_ok_night() {
    local f=$1 r t i x y ph lum g msg top ch
    BG_KIND=4
    if [ "$BG_KEY" != "night$H" ]; then
        bgtable_reset
        for (( r=1; r<=H-1; r++ )); do
            t=$(( (r-1)*1000 / (H>1 ? H-1 : 1) ))
            bgtable_row "$r" $(( 8 + 34*t/1000 )) $(( 12 + 18*t/1000 )) \
                             $(( 46 + 42*t/1000 ))
        done
        BG_KEY="night$H"
    fi
    bgtable_paint

    # moon, upper right, with a soft halo that breathes
    local mr=$(( 2 + H/10 )) mc=$(( W - W/6 ))
    local halo=$(( 200 + ${SIN[$(( f % 60 ))]} / 20 ))
    for i in 0 1 2 3 4; do
        r=$(( mr + i ))
        (( r < 1 || r > H-2 )) && continue
        bgtable_sty 250 250 "$halo" "$r"
        put "$r" $(( mc - 4 )) "$STY" "${MOON[$i]}"
    done

    # stars: fixed lattice, each with its own twinkle phase and drift
    for (( i=0; i<70; i++ )); do
        y=$(( 1 + (i * 7 + i/5) % (H - 2) ))
        x=$(( 1 + (i * 29 + i*i*5 + f/24) % W ))
        ph=${SIN[$(( (f*2 + i*11) % 60 ))]}
        lum=$(( 120 + ph * 135 / 1000 ))
        bgtable_sty "$lum" "$lum" $(( lum > 235 ? 255 : lum + 20 )) "$y"
        put "$y" "$x" "$STY" "${STAR_GLYPH[$(( i % 5 ))]}"
    done

    # a shooting star every ~7s, drawn as a fading diagonal tail
    local sc=$(( (f / 3) % 100 ))
    if (( sc < 22 )); then
        local sx=$(( 4 + sc * (W - 8) / 22 )) sy=$(( 2 + sc * (H/3) / 22 ))
        for i in 0 1 2 3 4; do
            r=$(( sy - i )); x=$(( sx - i*2 ))
            (( r < 1 || r > H-2 || x < 1 )) && continue
            g=$(( 255 - i * 42 ))
            bgtable_sty "$g" "$g" 255 "$r"
            (( i == 0 )) && ch="✦" || ch="╲"
            put "$r" "$x" "$STY" "$ch"
        done
    fi

    top=$(( H/2 - 4 ))
    (( top < 1 )) && top=1
    if (( H >= 18 && W >= 60 )); then
        draw_big "$top" BANNER_OK 235 240 255  40 60 120
        top=$(( top + 6 ))
    else
        msg="✓  ALL GOOD"
        center ${#msg}
        bgtable_sty 235 240 255 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 2 ))
    fi
    msg="all quiet · nothing to fix"
    center ${#msg}
    bgtable_sty 150 165 210 "$top"
    put "$top" "$COL" "$STY" "$msg"
}

# ------------------------------------------------ happy scene: fireworks ----

# Six shells on staggered cycles: each climbs as a trailed rocket, then bursts
# into an expanding ring of sparks that fades to embers.
FW_SPARK=("✳" "✺" "✷" "·" "˙")

scene_ok_fireworks() {
    local f=$1 r t i x y msg top ch
    BG_KIND=4
    if [ "$BG_KEY" != "fw$H" ]; then
        bgtable_reset
        for (( r=1; r<=H-1; r++ )); do
            t=$(( (r-1)*1000 / (H>1 ? H-1 : 1) ))
            bgtable_row "$r" $(( 10 + 12*t/1000 )) $(( 8 + 10*t/1000 )) \
                             $(( 26 + 26*t/1000 ))
        done
        BG_KEY="fw$H"
    fi
    bgtable_paint

    # city skyline silhouette along the bottom, so the shells have somewhere
    # to launch from
    local sky_row=$(( H - 2 ))
    if (( sky_row > 3 )); then
        local line="" c
        for (( c=1; c<=W; c++ )); do
            if (( ${SIN[$(( (c * 210 / W) % 60 ))]} > 500 )); then
                line+="█"
            else
                line+="▄"
            fi
        done
        bgtable_sty 22 20 40 "$sky_row"
        put "$sky_row" 1 "$STY" "$line"
        bgtable_sty 18 16 34 $(( sky_row + 1 ))
        put $(( sky_row + 1 )) 1 "$STY" "${SPACES// /█}"
    fi

    local cyc=54 launch=$(( H > 12 ? H - 4 : H - 1 ))
    local sh ph cx cy rad ring j dx dy fr fg fb
    for sh in 0 1 2 3 4 5; do
        ph=$(( (f + sh * 9) % cyc ))
        cx=$(( 4 + (sh * 37 + sh*sh*11) % (W - 8) ))
        cy=$(( 3 + (sh * 5) % (H/3 + 1) )); (( cy < 2 )) && cy=2
        # shell hue, one per launcher
        case $(( sh % 3 )) in
            0) fr=255; fg=210; fb=110 ;;
            1) fr=255; fg=130; fb=180 ;;
            *) fr=150; fg=225; fb=255 ;;
        esac
        if (( ph < 18 )); then
            # climbing: head plus a short sparking trail
            y=$(( launch - (launch - cy) * ph / 18 ))
            for i in 0 1 2; do
                r=$(( y + i ))
                (( r < 1 || r > H-1 )) && continue
                bgtable_sty $(( fr - i*40 )) $(( fg - i*40 )) $(( fb > 60 ? fb - i*30 : fb )) "$r"
                (( i == 0 )) && ch="▲" || ch="│"
                put "$r" "$cx" "$STY" "$ch"
            done
        elif (( ph < 40 )); then
            # bursting: ring radius grows, brightness falls
            rad=$(( (ph - 18) * 7 / 22 + 1 ))
            local fade=$(( 1000 - (ph - 18) * 1000 / 22 ))
            local gl=$(( fade / 4 + 1 ))
            ring=$(( (ph - 18) % 4 ))
            for (( j=0; j<12; j++ )); do
                dx=$(( ${SIN[$(( (j * 5 + 15) % 60 ))]} - 500 ))
                dy=$(( ${SIN[$(( (j * 5) % 60 ))]} - 500 ))
                x=$(( cx + dx * rad * 2 / 500 ))
                y=$(( cy + dy * rad / 500 ))
                (( y < 1 || y > H-1 || x < 1 || x > W )) && continue
                bgtable_sty $(( fr * gl / 250 > 255 ? 255 : fr * gl / 250 )) \
                            $(( fg * gl / 250 > 255 ? 255 : fg * gl / 250 )) \
                            $(( fb * gl / 250 > 255 ? 255 : fb * gl / 250 )) "$y"
                put "$y" "$x" "$STY" "${FW_SPARK[$ring]}"
            done
            # the flash at the core, only while the burst is young
            if (( ph < 22 )); then
                bgtable_sty 255 255 240 "$cy"
                put "$cy" "$cx" "$STY" "✺"
            fi
        fi
    done

    top=$(( H/2 - 4 ))
    (( top < 1 )) && top=1
    local pulse=${SIN[$(( f % 60 ))]}
    if (( H >= 18 && W >= 60 )); then
        draw_big "$top" BANNER_OK 255 $(( 235 + pulse/50 )) 200  90 40 20
        top=$(( top + 6 ))
    else
        msg="✓  ALL GOOD"
        center ${#msg}
        bgtable_sty 255 240 200 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 2 ))
    fi
    msg="green across the board"
    center ${#msg}
    bgtable_sty 240 200 150 "$top"
    put "$top" "$COL" "$STY" "$msg"
}

# --------------------------------------------------- happy scene: aurora ----

# A tile long enough to slice a full-width window out of at any offset.
tile_of() { # pattern minlen -> TILE
    TILE=""
    while (( ${#TILE} < $2 )); do TILE+=$1; done
}

# Three aurora curtains rippling over a snowfield. A curtain's shape depends
# only on its phase, so all 30 phases are rasterized on demand and replayed —
# the per-frame cost is 27 writes, not 2700 column tests.
AUR=(); AUR_KEY=""

build_aurora() { # idx
    local idx=$1 b yb amp row c yc depth line blob="" fr fg fb dim
    for b in 0 1 2; do
        yb=$(( 3 + b*3 + H/12 )); amp=3
        case $b in
            0) fr=110; fg=255; fb=170 ;;
            1) fr=100; fg=225; fb=255 ;;
            *) fr=180; fg=150; fb=255 ;;
        esac
        for (( row=yb-amp; row<=yb+amp+2; row++ )); do
            (( row < 1 || row > H-2 )) && continue
            line=""
            for (( c=1; c<=W; c++ )); do
                yc=$(( yb + ( ${SIN[$(( (c*100/W + idx*2 + b*20) % 60 ))]} - 500 ) * amp / 500 ))
                depth=$(( row - yc ))
                case $depth in
                    0) line+="▓" ;;
                    1) line+="▒" ;;
                    2) line+="░" ;;
                    *) line+=" " ;;
                esac
            done
            dim=$(( 1000 - (row - yb + amp) * 90 ))
            (( dim < 500 )) && dim=500
            bgtable_sty $(( fr * dim / 1000 )) $(( fg * dim / 1000 )) \
                        $(( fb * dim / 1000 )) "$row"
            blob+=$'\033['"$row;1H${STY}$line"
        done
    done
    AUR[$idx]=$blob
}

scene_ok_aurora() {
    local f=$1 r t i x y idx top msg lum snow
    BG_KIND=4
    if [ "$BG_KEY" != "aur$H" ]; then
        bgtable_reset
        for (( r=1; r<=H-1; r++ )); do
            t=$(( (r-1)*1000 / (H>1 ? H-1 : 1) ))
            bgtable_row "$r" $(( 6 + 12*t/1000 )) $(( 10 + 16*t/1000 )) \
                             $(( 30 + 34*t/1000 ))
        done
        BG_KEY="aur$H"
    fi
    bgtable_paint

    # curtains first: their spaces repaint the backdrop, so stars go on after
    idx=$(( (f/2) % 30 ))
    [ "$AUR_KEY" = "$H$W" ] || { AUR=(); AUR_KEY="$H$W"; }
    [ -n "${AUR[$idx]:-}" ] || build_aurora "$idx"
    OUT+=${AUR[$idx]}

    for (( i=0; i<34; i++ )); do
        y=$(( 1 + (i * 5 + i/4) % (H - 3) ))
        x=$(( 1 + (i * 31 + i*i*7) % W ))
        lum=$(( 140 + ${SIN[$(( (f*2 + i*13) % 60 ))]} * 115 / 1000 ))
        bgtable_sty "$lum" "$lum" 255 "$y"
        put "$y" "$x" "$STY" "·"
    done

    # snowfield: two crisp rows of drift, then flat snow to the status bar
    snow=$(( H - 3 ))
    if (( snow > 4 )); then
        tile_of "▄▄▅▄▄▃▄▅" $(( W + 4 ))
        bgtable_sty 208 224 246 "$snow"
        put "$snow" 1 "$STY" "${TILE:0:W}"
        for (( r=snow+1; r<=H-1; r++ )); do
            bgtable_sty 226 236 250 "$r"
            put "$r" 1 "$STY" "${SPACES// /█}"
        done
    fi

    top=$(( H/2 - 5 ))
    (( top < 1 )) && top=1
    if (( H >= 18 && W >= 60 )); then
        draw_big "$top" BANNER_OK 225 255 240  30 90 90
        top=$(( top + 6 ))
    else
        msg="✓  ALL GOOD"
        center ${#msg}
        bgtable_sty 225 255 240 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 2 ))
    fi
    msg="clean build under clear skies"
    center ${#msg}
    bgtable_sty 150 210 205 "$top"
    put "$top" "$COL" "$STY" "$msg"
}

# ---------------------------------------------------- happy scene: sunrise ---

# Sunrise over open water: half a sun on the horizon, a shimmering reflection
# column, wave rows that each drift at their own speed, gulls, and a boat.
SUN_SEA=("  ▄███▄  " " ███████ " "█████████")
BOAT=("  ▲  " " ╱|╲ " "╲___╱")

scene_ok_sunrise() {
    local f=$1 r t i x y hz top msg off pulse g
    hz=$(( H * 45 / 100 ))
    (( hz < 4 )) && hz=4
    (( hz > H-4 )) && hz=$(( H-4 ))
    BG_KIND=4
    if [ "$BG_KEY" != "sunrise$H" ]; then
        bgtable_reset
        for (( r=1; r<=hz; r++ )); do
            t=$(( (r-1)*1000 / hz ))
            bgtable_row "$r" $(( 72 + 180*t/1000 )) $(( 38 + 122*t/1000 )) \
                             $(( 96 + 20*t/1000 ))
        done
        for (( r=hz+1; r<=H-1; r++ )); do
            t=$(( (r-hz)*1000 / (H-hz>0 ? H-hz : 1) ))
            bgtable_row "$r" $(( 26 + 10*t/1000 )) $(( 58 + 24*t/1000 )) \
                             $(( 104 - 40*t/1000 ))
        done
        BG_KEY="sunrise$H"
    fi
    bgtable_paint

    pulse=${SIN[$(( f % 60 ))]}
    local sc=$(( W / 3 ))
    # the sun, sitting on the waterline
    for i in 0 1 2; do
        r=$(( hz - 2 + i ))
        (( r < 1 || r > hz )) && continue
        bgtable_sty 255 $(( 168 + pulse * 50 / 1000 )) 90 "$r"
        put "$r" $(( sc - 4 )) "$STY" "${SUN_SEA[$i]}"
    done

    # wave rows: one tile sliced at a per-row offset, so the sea drifts in bands
    tile_of "≈  ~ ˜ ≈~  " $(( W + 16 ))
    for (( r=hz+1; r<=H-1; r++ )); do
        off=$(( (f * (1 + r % 3) / 3 + r * 5) % 12 ))
        t=$(( (r-hz)*1000 / (H-hz>0 ? H-hz : 1) ))
        bgtable_sty $(( 120 - 40*t/1000 )) $(( 190 - 50*t/1000 )) \
                    $(( 235 - 60*t/1000 )) "$r"
        put "$r" 1 "$STY" "${TILE:off:W}"
    done

    # the sun's reflection: a broken gold column under the disc
    for (( r=hz+1; r<=H-1; r++ )); do
        (( (r + f/4) % 3 == 0 )) && continue
        g=$(( 150 + ${SIN[$(( (f*3 + r*9) % 60 ))]} * 90 / 1000 ))
        bgtable_sty 255 "$g" 110 "$r"
        x=$(( sc - 2 + (${SIN[$(( (f*2 + r*17) % 60 ))]} - 500) / 250 ))
        put "$r" "$x" "$STY" "≈≈≈≈"
    done

    # gulls over the water
    for i in 0 1 2; do
        x=$(( (f * 3 / 10 + i * 23) % (W + 16) - 8 ))
        y=$(( 2 + i * 2 + hz / 6 ))
        (( y < 1 || y > hz )) && continue
        bgtable_sty 60 40 60 "$y"
        if (( (f/5 + i) % 2 )); then put "$y" "$x" "$STY" "╲╱"
        else                         put "$y" "$x" "$STY" "╱╲"; fi
    done

    # a boat, bobbing a row as it crosses
    local bx=$(( (f * 2 / 5) % (W + 14) - 7 ))
    local by=$(( hz + 2 + (f / 9) % 2 ))
    for i in 0 1 2; do
        r=$(( by + i ))
        (( r < 1 || r > H-1 )) && continue
        bgtable_sty 250 240 230 "$r"
        put "$r" "$bx" "$STY" "${BOAT[$i]}"
    done

    top=$(( hz - 9 ))
    if (( H >= 20 && W >= 60 && top >= 1 )); then
        draw_big "$top" BANNER_OK 255 250 235  120 50 30
        top=$(( top + 6 ))
    else
        top=1
        msg="✓  ALL GOOD"
        center ${#msg}
        bgtable_sty 255 250 235 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 1 ))
    fi
    msg="smooth sailing"
    center ${#msg}
    bgtable_sty 255 225 190 "$top"
    put "$top" "$COL" "$STY" "$msg"
}

# --------------------------------------------------- happy scene: balloons ---

# Hot-air balloons drifting up past the banner, each on its own cycle so they
# never line up, with a layer of slow clouds behind them.
BALLOON=(" ▄███▄ " "███████" "███████" " █████ " "  ███  " "  ▐▌   " "  ▟▙   ")

scene_ok_balloons() {
    local f=$1 r t i x y top msg cyc sway fr fg fb n
    BG_KIND=4
    if [ "$BG_KEY" != "bal$H" ]; then
        bgtable_reset
        for (( r=1; r<=H-1; r++ )); do
            t=$(( (r-1)*1000 / (H>1 ? H-1 : 1) ))
            bgtable_row "$r" $(( 96 + 110*t/1000 )) $(( 150 + 78*t/1000 )) \
                             $(( 210 + 36*t/1000 ))
        done
        BG_KEY="bal$H"
    fi
    bgtable_paint

    # clouds drifting behind everything
    for i in 0 1 2 3; do
        y=$(( 2 + (i * 7) % (H - 4) ))
        x=$(( (f * (2 + i % 3) / 10 + i * 37) % (W + 30) - 15 ))
        bgtable_sty 250 252 255 "$y"
        put "$y" "$x" "$STY" "▄████▄"
        (( y+1 <= H-1 )) && {
            bgtable_sty 240 245 252 $(( y + 1 ))
            put $(( y + 1 )) $(( x - 2 )) "$STY" "▗██████▖"
        }
    done

    # balloons: rise the full height on staggered cycles, swaying as they go
    cyc=$(( H + 8 ))
    for i in 0 1 2 3 4; do
        y=$(( H - 1 - ((f / 4 + i * cyc / 5) % cyc) ))
        sway=$(( (${SIN[$(( (f*2 + i*15) % 60 ))]} - 500) / 200 ))
        x=$(( 4 + (i * 41 + i*i*13) % (W - 10) + sway ))
        case $(( i % 4 )) in
            0) fr=235; fg=70;  fb=90  ;;
            1) fr=250; fg=180; fb=60  ;;
            2) fr=120; fg=200; fb=140 ;;
            *) fr=170; fg=120; fb=225 ;;
        esac
        for n in 0 1 2 3 4 5 6; do
            r=$(( y + n ))
            (( r < 1 || r > H-1 )) && continue
            if (( n >= 5 )); then bgtable_sty 130 92 56 "$r"
            elif (( n == 4 )); then bgtable_sty $(( fr*7/10 )) $(( fg*7/10 )) $(( fb*7/10 )) "$r"
            else bgtable_sty "$fr" "$fg" "$fb" "$r"
            fi
            put "$r" "$x" "$STY" "${BALLOON[$n]}"
        done
    done

    top=$(( H/2 - 4 ))
    (( top < 1 )) && top=1
    if (( H >= 18 && W >= 60 )); then
        draw_big "$top" BANNER_OK 255 255 255  70 110 160
        top=$(( top + 6 ))
    else
        msg="✓  ALL GOOD"
        center ${#msg}
        bgtable_sty 255 255 255 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 2 ))
    fi
    msg="everything is up and away"
    center ${#msg}
    bgtable_sty 245 250 255 "$top"
    put "$top" "$COL" "$STY" "$msg"
}

# --------------------------------------------------- happy scene: rainbow ----

# A rainbow arc over a rain-washed field. The arc depends only on the window
# size, so all seven bands are rasterized once and replayed as a single write.
# Walking columns (not angles) keeps the bands continuous at the shoulders,
# where an angular sweep would step several rows between samples.
RB=""; RB_KEY=""

# floor(sqrt(n)) by Newton's method, for the ellipse's vertical term
isqrt() { # n -> ISQ
    local n=$1 x=1000 y
    (( n <= 0 )) && { ISQ=0; return; }
    while :; do
        y=$(( (x + n / x) / 2 ))
        (( y >= x )) && break
        x=$y
    done
    ISQ=$x
}

build_rainbow() { # ybase
    local ybase=$1 b c dx u row ytop rx ah cx fr fg fb save=$OUT
    cx=$(( W / 2 ))
    rx=$(( W * 42 / 100 )); (( rx < 6 )) && rx=6
    ah=$(( ybase - 2 ))
    (( ah > H * 50 / 100 )) && ah=$(( H * 50 / 100 ))
    (( ah < 3 )) && ah=3
    OUT=""
    for (( c=1; c<=W; c++ )); do
        dx=$(( c - cx ))
        u=$(( dx * 1000 / rx ))
        (( u > 1000 || u < -1000 )) && continue
        isqrt $(( 1000000 - u * u ))
        ytop=$(( ybase - ah * ISQ / 1000 ))
        for b in 0 1 2 3 4 5 6; do
            row=$(( ytop + b ))
            (( row < 1 || row > ybase )) && continue
            case $b in
                0) fr=255; fg=95;  fb=95  ;;
                1) fr=255; fg=160; fb=60  ;;
                2) fr=250; fg=228; fb=95  ;;
                3) fr=110; fg=220; fb=120 ;;
                4) fr=90;  fg=205; fb=240 ;;
                5) fr=95;  fg=135; fb=235 ;;
                *) fr=175; fg=120; fb=225 ;;
            esac
            bgtable_sty "$fr" "$fg" "$fb" "$row"
            put "$row" "$c" "$STY" "█"
        done
    done
    RB=$OUT
    OUT=$save
}

scene_ok_rainbow() {
    local f=$1 r t i x y top msg hz g
    hz=$(( H * 76 / 100 ))
    (( hz < 4 )) && hz=4
    (( hz > H-3 )) && hz=$(( H-3 ))
    BG_KIND=4
    if [ "$BG_KEY" != "rb$H" ]; then
        bgtable_reset
        for (( r=1; r<=hz; r++ )); do
            t=$(( (r-1)*1000 / hz ))
            bgtable_row "$r" $(( 78 + 104*t/1000 )) $(( 128 + 92*t/1000 )) \
                             $(( 190 + 50*t/1000 ))
        done
        for (( r=hz+1; r<=H-1; r++ )); do
            t=$(( (r-hz)*1000 / (H-hz>0 ? H-hz : 1) ))
            bgtable_row "$r" $(( 72 - 34*t/1000 )) $(( 152 - 56*t/1000 )) \
                             $(( 78 - 32*t/1000 ))
        done
        BG_KEY="rb$H"
    fi
    bgtable_paint

    [ "$RB_KEY" = "$H$W" ] || { build_rainbow "$hz"; RB_KEY="$H$W"; }
    OUT+=$RB

    # the tail of the shower, thinning out as it drifts off to the right
    for (( i=0; i<26; i++ )); do
        y=$(( 1 + (i * 3 + f + i/5) % (hz > 1 ? hz : 1) ))
        x=$(( 1 + (i * 41 + i*i*7 + f * 2) % W ))
        bgtable_sty 190 215 245 "$y"
        put "$y" "$x" "$STY" "╱"
    done

    # wet grass, with dew catching the light
    tile_of "ψ  ' ψ ˇ " $(( W + 12 ))
    for (( r=hz+1; r<=H-1; r++ )); do
        bgtable_sty $(( 120 - (r - hz) * 6 )) $(( 200 - (r - hz) * 8 )) 110 "$r"
        put "$r" 1 "$STY" "${TILE:$(( (r * 5) % 9 )):W}"
    done
    for (( i=0; i<18; i++ )); do
        y=$(( hz + 1 + (i * 3) % (H - hz - 1 > 0 ? H - hz - 1 : 1) ))
        (( y > H-1 )) && continue
        x=$(( 2 + (i * 53 + i*i*5) % (W - 2) ))
        g=$(( 190 + ${SIN[$(( (f*3 + i*17) % 60 ))]} * 65 / 1000 ))
        bgtable_sty "$g" 255 255 "$y"
        put "$y" "$x" "$STY" "˙"
    done

    top=$(( hz - 9 ))
    if (( H >= 20 && W >= 60 && top >= 1 )); then
        draw_big "$top" BANNER_OK 255 255 250  40 80 130
        top=$(( top + 6 ))
    else
        top=1
        msg="✓  ALL GOOD"
        center ${#msg}
        bgtable_sty 255 255 250 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 1 ))
    fi
    msg="the storm has passed"
    center ${#msg}
    bgtable_sty 235 245 255 "$top"
    put "$top" "$COL" "$STY" "$msg"
}

# ------------------------------------------------------ happy scene: reef ----

# Sunlit water: caustic light rippling near the surface, bubbles rising in
# columns, fish crossing at their own depths, and swaying weed on the sand.
FISH_R=("><(((°>" "><(°>" "><)))*>")
FISH_L=("<°)))><" "<°)><" "<*(((><")

scene_ok_reef() {
    local f=$1 r t i x y top msg n fr fg fb sand off lum
    sand=$(( H - 3 ))
    (( sand < 5 )) && sand=$(( H - 1 ))
    BG_KIND=4
    if [ "$BG_KEY" != "reef$H" ]; then
        bgtable_reset
        for (( r=1; r<=H-1; r++ )); do
            t=$(( (r-1)*1000 / (H>1 ? H-1 : 1) ))
            bgtable_row "$r" $(( 16 + 4*t/1000 )) $(( 108 - 52*t/1000 )) \
                             $(( 150 - 40*t/1000 ))
        done
        BG_KEY="reef$H"
    fi
    bgtable_paint

    # caustics: bright ripples near the surface, each row drifting its own way
    tile_of "░▒░    ▒░  " $(( W + 16 ))
    for (( r=1; r<=4 && r<=H-2; r++ )); do
        off=$(( (f * (1 + r % 3) / 2 + r * 4) % 11 ))
        bgtable_sty $(( 170 - r*10 )) $(( 235 - r*12 )) 255 "$r"
        put "$r" 1 "$STY" "${TILE:off:W}"
    done

    # bubbles, rising and wobbling as they go
    for (( i=0; i<34; i++ )); do
        y=$(( H - 2 - (f / 2 + i * 7) % (H - 2 > 1 ? H - 2 : 1) ))
        (( y < 1 || y > H-1 )) && continue
        x=$(( 1 + (i * 43 + i*i*13) % W + (${SIN[$(( (f*2 + i*11) % 60 ))]} - 500) / 300 ))
        lum=$(( 190 + ${SIN[$(( (f + i*9) % 60 ))]} * 60 / 1000 ))
        bgtable_sty "$lum" 250 255 "$y"
        if (( i % 3 )); then put "$y" "$x" "$STY" "∘"
        else                 put "$y" "$x" "$STY" "○"; fi
    done

    # fish: three going right, two coming back the other way
    for i in 0 1 2; do
        y=$(( 3 + (i * 4 + H/8) % (sand > 4 ? sand - 3 : 1) ))
        (( y < 1 || y > H-1 )) && continue
        x=$(( (f * (3 + i) / 8 + i * 29) % (W + 20) - 10 ))
        case $i in
            0) fr=255; fg=170; fb=70  ;;
            1) fr=250; fg=225; fb=120 ;;
            *) fr=140; fg=235; fb=210 ;;
        esac
        bgtable_sty "$fr" "$fg" "$fb" "$y"
        put "$y" "$x" "$STY" "${FISH_R[$i]}"
    done
    for i in 0 1; do
        y=$(( 5 + (i * 6 + H/5) % (sand > 6 ? sand - 4 : 1) ))
        (( y < 1 || y > H-1 )) && continue
        x=$(( W + 8 - (f * (2 + i) / 7 + i * 37) % (W + 20) ))
        bgtable_sty $(( 200 - i*60 )) $(( 190 + i*30 )) 255 "$y"
        put "$y" "$x" "$STY" "${FISH_L[$i]}"
    done

    # weed swaying off the sand, then the sand itself
    if (( sand > 4 )); then
        for (( i=0; i<9; i++ )); do
            x=$(( 3 + (i * 37 + i*i*7) % (W - 4) ))
            for (( n=1; n<=4; n++ )); do
                y=$(( sand - n ))
                (( y < 1 )) && break
                bgtable_sty $(( 40 + n*8 )) $(( 150 - n*10 )) $(( 90 + n*6 )) "$y"
                put "$y" $(( x + (${SIN[$(( (f*2 + i*13 + n*6) % 60 ))]} - 500) * n / 900 )) \
                    "$STY" "❙"
            done
        done
        tile_of "▄▄▅▄▃▄▄▅" $(( W + 8 ))
        bgtable_sty 226 208 164 "$sand"
        put "$sand" 1 "$STY" "${TILE:0:W}"
        for (( r=sand+1; r<=H-1; r++ )); do
            bgtable_sty 214 194 150 "$r"
            put "$r" 1 "$STY" "${SPACES// /█}"
        done
    fi

    top=$(( H/2 - 5 ))
    (( top < 1 )) && top=1
    if (( H >= 18 && W >= 60 )); then
        draw_big "$top" BANNER_OK 235 255 250  10 70 90
        top=$(( top + 6 ))
    else
        msg="✓  ALL GOOD"
        center ${#msg}
        bgtable_sty 235 255 250 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 2 ))
    fi
    msg="swimming along nicely"
    center ${#msg}
    bgtable_sty 170 225 225 "$top"
    put "$top" "$COL" "$STY" "$msg"
}

# -------------------------------------------------- happy scene: confetti ----

# A dark stage under a confetti burst: paper falling and tumbling on its own
# phase, streamers curling down from the top corners, and a spotlight glow.
CONF=("▰" "▱" "▪" "◆" "▬" "▮")

scene_ok_confetti() {
    local f=$1 r t i x y n top msg fr fg fb sp gl ch
    BG_KIND=4
    if [ "$BG_KEY" != "conf$H" ]; then
        bgtable_reset
        for (( r=1; r<=H-1; r++ )); do
            t=$(( (r-1)*1000 / (H>1 ? H-1 : 1) ))
            bgtable_row "$r" $(( 30 + 44*t/1000 )) $(( 14 + 16*t/1000 )) \
                             $(( 46 + 40*t/1000 ))
        done
        BG_KEY="conf$H"
    fi
    bgtable_paint

    # two spotlights washing the middle of the stage; one tile covers every
    # cone width, sliced shorter or longer per row
    tile_of "░" $(( H / 2 + 4 ))
    local cone=$TILE
    for i in 0 1; do
        sp=$(( i == 0 ? W/3 : W - W/3 ))
        for (( r=2; r<=H-2; r++ )); do
            gl=$(( 1000 - (r - 2) * 800 / (H > 4 ? H - 4 : 1) ))
            (( gl < 100 )) && gl=100
            x=$(( sp + (${SIN[$(( (f + i*30) % 60 ))]} - 500) * (r - 1) / 2400 ))
            bgtable_sty $(( 90 + 90*gl/1000 )) $(( 70 + 70*gl/1000 )) \
                        $(( 110 + 90*gl/1000 )) "$r"
            put "$r" $(( x - r/4 - 1 )) "$STY" "${cone:0:$(( r/2 + 2 ))}"
        done
    done

    # streamers curling in from the upper corners
    for i in 0 1 2 3; do
        for (( n=0; n<7; n++ )); do
            y=$(( 1 + n ))
            (( y > H-2 )) && break
            x=$(( i < 2 ? 2 + i*4 + n*2 + (f/6 + n) % 2
                        : W - 2 - (i-2)*4 - n*2 - (f/6 + n) % 2 ))
            (( i < 2 )) && ch="╲" || ch="╱"
            bgtable_sty $(( 250 - i*20 )) $(( 120 + i*40 )) $(( 200 - i*30 )) "$y"
            put "$y" "$x" "$STY" "$ch"
        done
    done

    # confetti: falls, tumbles between glyphs, drifts on a per-piece phase
    for (( i=0; i<64; i++ )); do
        y=$(( 1 + (f * (2 + i % 3) / 4 + i * 5 + i*i) % (H - 1) ))
        x=$(( 1 + (i * 29 + i*i*11) % W + (${SIN[$(( (f*2 + i*7) % 60 ))]} - 500) / 220 ))
        case $(( i % 6 )) in
            0) fr=255; fg=90;  fb=120 ;;
            1) fr=255; fg=200; fb=70  ;;
            2) fr=120; fg=225; fb=160 ;;
            3) fr=110; fg=190; fb=255 ;;
            4) fr=210; fg=140; fb=255 ;;
            *) fr=255; fg=250; fb=235 ;;
        esac
        bgtable_sty "$fr" "$fg" "$fb" "$y"
        put "$y" "$x" "$STY" "${CONF[$(( (f/3 + i) % 6 ))]}"
    done

    top=$(( H/2 - 4 ))
    (( top < 1 )) && top=1
    local pulse=${SIN[$(( f % 60 ))]}
    if (( H >= 18 && W >= 60 )); then
        draw_big "$top" BANNER_OK 255 $(( 240 + pulse/70 )) 245  70 20 60
        top=$(( top + 6 ))
    else
        msg="✓  ALL GOOD"
        center ${#msg}
        bgtable_sty 255 245 250 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 2 ))
    fi
    msg="ship it"
    center ${#msg}
    bgtable_sty 250 215 235 "$top"
    put "$top" "$COL" "$STY" "$msg"
}

# ---------------------------------------------------- happy scene: blossom ---

# A cherry bough across the top with petals coming loose and drifting down on
# the breeze. The bough is static for a given window, so it is rasterized once
# and replayed; only the petals move.
BLSM=""; BLSM_KEY=""
PETAL=("❀" "✿" "❁" "·")

build_blossom() {
    local c y save=$OUT
    OUT=""
    for (( c=1; c<=W*3/4; c++ )); do
        # a slow arc sagging away from the top-left corner
        y=$(( 2 + c * 4 / W + (${SIN[$(( (c * 80 / W) % 60 ))]} - 500) * 2 / 500 ))
        (( y < 1 || y > H-3 )) && continue
        bgtable_sty 96 62 54 "$y"
        put "$y" "$c" "$STY" "▄"
        # blossom clusters hanging under the bough
        if (( c % 6 == 2 )); then
            bgtable_sty 252 196 218 $(( y + 1 ))
            put $(( y + 1 )) "$c" "$STY" "❀❀"
        elif (( c % 6 == 5 )); then
            bgtable_sty 255 220 232 $(( y + 1 ))
            put $(( y + 1 )) "$c" "$STY" "✿"
        fi
    done
    BLSM=$OUT
    OUT=$save
}

scene_ok_blossom() {
    local f=$1 r t i x y top msg lum
    BG_KIND=4
    if [ "$BG_KEY" != "blsm$H" ]; then
        bgtable_reset
        for (( r=1; r<=H-1; r++ )); do
            t=$(( (r-1)*1000 / (H>1 ? H-1 : 1) ))
            bgtable_row "$r" $(( 156 + 84*t/1000 )) $(( 116 + 96*t/1000 )) \
                             $(( 148 + 62*t/1000 ))
        done
        BG_KEY="blsm$H"
        BLSM_KEY=""                 # the bough sits on this backdrop
    fi
    bgtable_paint

    [ "$BLSM_KEY" = "$H$W" ] || { build_blossom; BLSM_KEY="$H$W"; }
    OUT+=$BLSM

    # petals: they fall slowly and drift right, each on its own phase, so the
    # fall reads as a breeze rather than a curtain
    for (( i=0; i<48; i++ )); do
        y=$(( 1 + (f * (2 + i % 3) / 6 + i * 5 + i/4) % (H - 1) ))
        x=$(( 1 + (i * 31 + i*i*7 + f / 2) % W
                + (${SIN[$(( (f*2 + i*9) % 60 ))]} - 500) / 200 ))
        lum=$(( 225 + ${SIN[$(( (f + i*13) % 60 ))]} * 30 / 1000 ))
        bgtable_sty "$lum" $(( 170 + i % 40 )) $(( 200 + i % 30 )) "$y"
        put "$y" "$x" "$STY" "${PETAL[$(( (f/4 + i) % 4 ))]}"
    done

    top=$(( H/2 - 3 ))
    (( top < 1 )) && top=1
    if (( H >= 18 && W >= 60 )); then
        draw_big "$top" BANNER_OK 255 252 252  140 70 100
        top=$(( top + 6 ))
    else
        msg="✓  ALL GOOD"
        center ${#msg}
        bgtable_sty 255 250 252 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 2 ))
    fi
    msg="nothing left to prune"
    center ${#msg}
    bgtable_sty 250 220 232 "$top"
    put "$top" "$COL" "$STY" "$msg"
}

# ------------------------------------------------------ happy scene: orbit ----

# A ringed planet hanging in a starfield with a probe sailing past it. The
# planet's disc and rings depend only on the window size, so they are rasterized
# once (using isqrt for the limb) and replayed.
PLANET=""; PLANET_KEY=""
PROBE=("   ▄▖ " "≡▟███▶" "   ▀▘ ")

build_planet() {
    local pr pc rx ry row dy u half c line save=$OUT lat
    pc=$(( W - W/4 )); pr=$(( H/2 - 1 ))
    ry=$(( H / 5 )); (( ry < 2 )) && ry=2
    rx=$(( ry * 2 ))
    OUT=""
    for (( row=pr-ry; row<=pr+ry; row++ )); do
        (( row < 1 || row > H-2 )) && continue
        dy=$(( row - pr ))
        u=$(( dy * 1000 / ry ))
        isqrt $(( 1000000 - u * u ))
        half=$(( rx * ISQ / 1000 ))
        (( half < 1 )) && continue
        # banded surface: the latitude decides the band's shade
        lat=$(( dy < 0 ? -dy : dy ))
        line=""
        for (( c=0; c<half*2+1; c++ )); do line+="█"; done
        if (( (lat + pr) % 3 == 0 )); then
            bgtable_sty 214 158 96 "$row"
        elif (( (lat + pr) % 3 == 1 )); then
            bgtable_sty 188 128 78 "$row"
        else
            bgtable_sty 232 184 122 "$row"
        fi
        put "$row" $(( pc - half )) "$STY" "$line"
    done
    # rings: two flat ellipses crossing the disc, drawn as dashed spans
    for (( row=pr-1; row<=pr+1; row+=2 )); do
        (( row < 1 || row > H-2 )) && continue
        line=""
        for (( c=0; c<rx*3; c++ )); do
            (( c % 3 == 2 )) && line+=" " || line+="─"
        done
        bgtable_sty 236 214 176 "$row"
        put "$row" $(( pc - rx*3/2 )) "$STY" "$line"
    done
    PLANET=$OUT
    OUT=$save
}

scene_ok_orbit() {
    local f=$1 r t i x y top msg lum n
    BG_KIND=4
    if [ "$BG_KEY" != "orb$H" ]; then
        bgtable_reset
        for (( r=1; r<=H-1; r++ )); do
            t=$(( (r-1)*1000 / (H>1 ? H-1 : 1) ))
            bgtable_row "$r" $(( 10 + 14*t/1000 )) $(( 8 + 8*t/1000 )) \
                             $(( 22 + 22*t/1000 ))
        done
        BG_KEY="orb$H"
        PLANET_KEY=""
    fi
    bgtable_paint

    # starfield behind the planet, twinkling on its own phase
    for (( i=0; i<56; i++ )); do
        y=$(( 1 + (i * 5 + i/6) % (H - 2) ))
        x=$(( 1 + (i * 37 + i*i*11) % W ))
        lum=$(( 130 + ${SIN[$(( (f*2 + i*17) % 60 ))]} * 125 / 1000 ))
        bgtable_sty "$lum" "$lum" $(( lum > 235 ? 255 : lum + 20 )) "$y"
        put "$y" "$x" "$STY" "${STAR_GLYPH[$(( i % 5 ))]}"
    done

    [ "$PLANET_KEY" = "$H$W" ] || { build_planet; PLANET_KEY="$H$W"; }
    OUT+=$PLANET

    # the probe, crossing left to right with a flickering ion trail
    local px=$(( (f * 3 / 5) % (W + 24) - 12 ))
    local py=$(( 3 + H/6 + (f / 11) % 2 ))
    for n in 0 1 2; do
        r=$(( py + n ))
        (( r < 1 || r > H-2 )) && continue
        bgtable_sty 226 232 244 "$r"
        put "$r" "$px" "$STY" "${PROBE[$n]}"
    done
    for (( i=1; i<=6; i++ )); do
        r=$(( py + 1 ))
        (( r < 1 || r > H-2 )) && break
        bgtable_sty $(( 140 + ${SIN[$(( (f*4 + i*9) % 60 ))]} * 100 / 1000 )) \
                    $(( 180 - i*18 )) 255 "$r"
        put "$r" $(( px - i )) "$STY" "·"
    done

    top=$(( H/2 - 5 ))
    (( top < 1 )) && top=1
    if (( H >= 18 && W >= 60 )); then
        draw_big "$top" BANNER_OK 240 246 255  30 40 90
        top=$(( top + 6 ))
    else
        msg="✓  ALL GOOD"
        center ${#msg}
        bgtable_sty 240 246 255 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 2 ))
    fi
    msg="all systems nominal"
    center ${#msg}
    bgtable_sty 160 175 220 "$top"
    put "$top" "$COL" "$STY" "$msg"
}

# ----------------------------------------------------- happy scene: ripple ----

# Concentric rings spreading out over still water. A ring's shape depends only
# on its radius, so the whole set for a phase is rasterized on demand and
# replayed — the per-frame cost is a handful of writes, not W*H distance tests.
RIP=(); RIP_KEY=""
RIP_PHASES=14

build_ripple() { # idx
    local idx=$1 rad k c dx u ry rows cy cx blob="" save=$OUT dim top bot
    cx=$(( W / 2 )); cy=$(( H / 2 ))
    OUT=""
    # four rings in flight at once, each RIP_PHASES apart in its life
    for k in 0 1 2 3; do
        rad=$(( idx + k * RIP_PHASES ))
        (( rad < 2 )) && continue
        ry=$(( rad / 2 ))
        (( ry > H )) && continue
        dim=$(( 1000 - rad * 900 / (RIP_PHASES * 4) ))
        (( dim < 120 )) && dim=120
        for (( c=1; c<=W; c++ )); do
            dx=$(( c - cx ))
            u=$(( dx * 1000 / rad ))
            (( u > 1000 || u < -1000 )) && continue
            isqrt $(( 1000000 - u * u ))
            rows=$(( ry * ISQ / 1000 ))
            # both crests must be on screen before they can be styled: the row
            # is a bgtable subscript, and a ring taller than the window is not
            top=$(( cy - rows )); bot=$(( cy + rows ))
            if (( top >= 1 && top <= H-1 )); then
                bgtable_sty $(( 150 * dim / 1000 )) $(( 210 * dim / 1000 + 40 )) \
                            $(( 235 * dim / 1000 + 20 )) "$top"
                put "$top" "$c" "$STY" "‾"
            fi
            if (( bot >= 1 && bot <= H-1 )); then
                bgtable_sty $(( 150 * dim / 1000 )) $(( 210 * dim / 1000 + 40 )) \
                            $(( 235 * dim / 1000 + 20 )) "$bot"
                put "$bot" "$c" "$STY" "_"
            fi
        done
    done
    blob=$OUT
    OUT=$save
    RIP[$idx]=$blob
}

scene_ok_ripple() {
    local f=$1 r t i x y top msg idx lum
    BG_KIND=4
    if [ "$BG_KEY" != "rip$H" ]; then
        bgtable_reset
        for (( r=1; r<=H-1; r++ )); do
            t=$(( (r-1)*1000 / (H>1 ? H-1 : 1) ))
            bgtable_row "$r" $(( 14 + 10*t/1000 )) $(( 62 + 30*t/1000 )) \
                             $(( 78 + 34*t/1000 ))
        done
        BG_KEY="rip$H"
    fi
    bgtable_paint

    idx=$(( (f / 2) % RIP_PHASES ))
    [ "$RIP_KEY" = "$H$W" ] || { RIP=(); RIP_KEY="$H$W"; }
    [ -n "${RIP[$idx]:-}" ] || build_ripple "$idx"
    OUT+=${RIP[$idx]}

    # the drop that started it, dipping in and out at the centre
    local dy=$(( H/2 - 4 + (f / 2) % 4 ))
    if (( dy >= 1 && dy <= H-2 )); then
        bgtable_sty 220 250 255 "$dy"
        put "$dy" $(( W/2 )) "$STY" "◦"
    fi

    # lily pads floating, each rocking on the swell
    for i in 0 1 2 3; do
        y=$(( 3 + (i * 5 + H/7) % (H - 4) ))
        x=$(( 4 + (i * 47 + i*i*9) % (W - 8) + (${SIN[$(( (f + i*15) % 60 ))]} - 500) / 400 ))
        bgtable_sty $(( 60 + i*10 )) $(( 160 + i*12 )) 110 "$y"
        put "$y" "$x" "$STY" "◖◗"
    done

    # a dragonfly skimming the surface
    local gx=$(( (f * 4 / 7) % (W + 18) - 9 ))
    local gy=$(( 2 + H/5 + (${SIN[$(( (f*3) % 60 ))]} - 500) / 300 ))
    if (( gy >= 1 && gy <= H-2 )); then
        bgtable_sty 210 235 250 "$gy"
        if (( (f/2) % 2 )); then put "$gy" "$gx" "$STY" "≺═≻"
        else                     put "$gy" "$gx" "$STY" "⋉═⋊"; fi
    fi

    top=$(( H/2 - 3 ))
    (( top < 1 )) && top=1
    if (( H >= 18 && W >= 60 )); then
        draw_big "$top" BANNER_OK 240 255 255  10 60 80
        top=$(( top + 6 ))
    else
        msg="✓  ALL GOOD"
        center ${#msg}
        bgtable_sty 240 255 255 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 2 ))
    fi
    msg="still waters"
    center ${#msg}
    bgtable_sty 170 220 230 "$top"
    put "$top" "$COL" "$STY" "$msg"
}

# --------------------------------------------------- happy scene: lanterns ---

# A festival of paper lanterns lifting off over dark rooftops: each lantern
# climbs on its own cycle, flickering with the flame inside it, and the whole
# field of them reflects off a low mist near the ground.
LANTERN=(" ▄▄▄ " "█████" "█████" " ███ " "  ▀  ")

scene_ok_lanterns() {
    local f=$1 r t i x y n top msg fr fg fb cyc sway flick
    BG_KIND=4
    if [ "$BG_KEY" != "lant$H" ]; then
        bgtable_reset
        for (( r=1; r<=H-1; r++ )); do
            t=$(( (r-1)*1000 / (H>1 ? H-1 : 1) ))
            bgtable_row "$r" $(( 14 + 46*t/1000 )) $(( 12 + 26*t/1000 )) \
                             $(( 34 + 30*t/1000 ))
        done
        BG_KEY="lant$H"
    fi
    bgtable_paint

    # rooftops along the bottom: a stepped silhouette the lanterns rise from
    local roof=$(( H - 3 ))
    if (( roof > 4 )); then
        local line="" c step
        for (( c=1; c<=W; c++ )); do
            step=$(( ${SIN[$(( (c * 170 / W) % 60 ))]} ))
            (( step > 550 )) && line+="█" || line+="▄"
        done
        bgtable_sty 26 22 40 "$roof"
        put "$roof" 1 "$STY" "$line"
        for (( r=roof+1; r<=H-1; r++ )); do
            bgtable_sty 20 17 32 "$r"
            put "$r" 1 "$STY" "${SPACES// /█}"
        done
        # lit windows, a few of them blinking out
        for (( i=0; i<14; i++ )); do
            y=$(( roof + 1 + (i % 2) ))
            (( y > H-1 )) && continue
            x=$(( 2 + (i * 29 + i*i*5) % (W - 2) ))
            if (( ${SIN[$(( (f + i*23) % 60 ))]} > 300 )); then
                bgtable_sty 250 210 130 "$y"
            else
                bgtable_sty 90 74 60 "$y"
            fi
            put "$y" "$x" "$STY" "▪"
        done
    fi

    # the lanterns, rising and swaying, each with a warm halo under it
    cyc=$(( H + 10 ))
    for i in 0 1 2 3 4 5; do
        y=$(( H - 2 - ((f / 5 + i * cyc / 6) % cyc) ))
        sway=$(( (${SIN[$(( (f*2 + i*13) % 60 ))]} - 500) / 240 ))
        x=$(( 3 + (i * 43 + i*i*11) % (W - 8) + sway ))
        flick=$(( ${SIN[$(( (f*4 + i*19) % 60 ))]} ))
        case $(( i % 3 )) in
            0) fr=255; fg=$(( 170 + flick / 14 )); fb=90  ;;
            1) fr=255; fg=$(( 140 + flick / 12 )); fb=140 ;;
            *) fr=250; fg=$(( 200 + flick / 20 )); fb=120 ;;
        esac
        for n in 0 1 2 3 4; do
            r=$(( y + n ))
            (( r < 1 || r > H-1 )) && continue
            if (( n == 4 )); then bgtable_sty 255 240 190 "$r"
            elif (( n == 0 )); then bgtable_sty $(( fr*8/10 )) $(( fg*8/10 )) $(( fb*8/10 )) "$r"
            else bgtable_sty "$fr" "$fg" "$fb" "$r"
            fi
            put "$r" "$x" "$STY" "${LANTERN[$n]}"
        done
        # the glow it throws on the air just beneath it
        r=$(( y + 5 ))
        (( r >= 1 && r <= H-1 )) && {
            bgtable_sty $(( fr/2 )) $(( fg/2 )) $(( fb/2 )) "$r"
            put "$r" $(( x + 1 )) "$STY" "░░░"
        }
    done

    # embers of ash drifting up between them
    for (( i=0; i<20; i++ )); do
        y=$(( H - 2 - (f / 4 + i * 7) % (H - 2 > 1 ? H - 2 : 1) ))
        (( y < 1 || y > H-1 )) && continue
        x=$(( 1 + (i * 37 + i*i*13) % W ))
        bgtable_sty 240 $(( 180 + i % 40 )) 120 "$y"
        put "$y" "$x" "$STY" "·"
    done

    top=$(( H/2 - 5 ))
    (( top < 1 )) && top=1
    if (( H >= 18 && W >= 60 )); then
        draw_big "$top" BANNER_OK 255 244 220  70 40 20
        top=$(( top + 6 ))
    else
        msg="✓  ALL GOOD"
        center ${#msg}
        bgtable_sty 255 244 220 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 2 ))
    fi
    msg="wishes sent up"
    center ${#msg}
    bgtable_sty 240 200 150 "$top"
    put "$top" "$COL" "$STY" "$msg"
}

# -------------------------------------------------- happy scene: fireflies ---

# Dusk over tall grass: fireflies wander on looping paths, blinking in slow
# waves, over a treeline silhouette with a last band of light behind it.
scene_ok_fireflies() {
    local f=$1 r t i x y top msg lum hz ph n g

    hz=$(( H * 58 / 100 ))
    (( hz < 4 )) && hz=4
    (( hz > H-4 )) && hz=$(( H-4 ))
    BG_KIND=4
    if [ "$BG_KEY" != "ffly$H" ]; then
        bgtable_reset
        for (( r=1; r<=hz; r++ )); do
            # deep dusk overhead warming to a band of amber at the treeline
            t=$(( (r-1)*1000 / hz ))
            bgtable_row "$r" $(( 26 + 154*t/1000 )) $(( 26 + 84*t/1000 )) \
                             $(( 64 + 6*t/1000 ))
        done
        for (( r=hz+1; r<=H-1; r++ )); do
            t=$(( (r-hz)*1000 / (H-hz>0 ? H-hz : 1) ))
            bgtable_row "$r" $(( 20 + 8*t/1000 )) $(( 34 + 14*t/1000 )) \
                             $(( 24 + 8*t/1000 ))
        done
        BG_KEY="ffly$H"
    fi
    bgtable_paint

    # treeline: a ragged silhouette sitting on the amber band
    local line="" c
    for (( c=1; c<=W; c++ )); do
        if (( ${SIN[$(( (c * 260 / W) % 60 ))]} + ${SIN[$(( (c * 90 / W) % 60 ))]} > 1050 )); then
            line+="▲"
        else
            line+="▀"
        fi
    done
    bgtable_sty 22 30 26 "$hz"
    put "$hz" 1 "$STY" "$line"

    # tall grass in front, swaying in the breeze
    tile_of "❙ ψ ❙  ❙ ψ" $(( W + 12 ))
    for (( r=hz+1; r<=H-1; r++ )); do
        bgtable_sty $(( 34 + (r - hz) * 4 )) $(( 66 + (r - hz) * 6 )) 40 "$r"
        put "$r" 1 "$STY" "${TILE:$(( (f/6 + r * 3) % 10 )):W}"
    done

    # fireflies: each drifts on its own loop and blinks on its own phase, so the
    # field pulses unevenly the way a real one does
    for (( i=0; i<30; i++ )); do
        ph=$(( (f * (2 + i % 3) / 4 + i * 9) % 60 ))
        x=$(( W/2 + (${SIN[$ph]} - 500) * (W/2 - 2) / 520 + (i % 9) * 3 - 12 ))
        y=$(( hz - 2 + (${SIN[$(( (ph * 2 + i * 7) % 60 ))]} - 500) * (hz/2) / 620
                     + (i % 5) ))
        (( y < 1 || y > H-1 || x < 1 || x > W )) && continue
        g=$(( ${SIN[$(( (f*3 + i*17) % 60 ))]} ))
        if (( g > 620 )); then
            lum=$(( 200 + g / 20 ))
            bgtable_sty "$lum" 255 $(( 120 + g / 12 )) "$y"
            put "$y" "$x" "$STY" "✦"
        elif (( g > 400 )); then
            bgtable_sty 150 200 90 "$y"
            put "$y" "$x" "$STY" "·"
        fi
    done

    # the first stars, out above the dusk
    for (( i=0; i<18; i++ )); do
        y=$(( 1 + (i * 3) % (hz / 2 > 1 ? hz / 2 : 1) ))
        x=$(( 1 + (i * 47 + i*i*7) % W ))
        lum=$(( 150 + ${SIN[$(( (f + i*21) % 60 ))]} * 90 / 1000 ))
        bgtable_sty "$lum" "$lum" 255 "$y"
        put "$y" "$x" "$STY" "·"
    done

    top=$(( hz / 2 - 3 ))
    (( top < 1 )) && top=1
    if (( H >= 20 && W >= 60 )); then
        draw_big "$top" BANNER_OK 245 255 220  30 50 30
        top=$(( top + 6 ))
    else
        top=1
        msg="✓  ALL GOOD"
        center ${#msg}
        bgtable_sty 245 255 220 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 1 ))
    fi
    msg="quiet evening, everything green"
    center ${#msg}
    bgtable_sty 200 225 160 "$top"
    put "$top" "$COL" "$STY" "$msg"
}

# --------------------------------------------------------- happy scene: zen ---

# A raked gravel garden: combed lines curving around three standing stones, moss
# at their feet, and a maple leaf tumbling across. The rake pattern is fixed for
# a window size, so it is rasterized once and replayed; only the leaf moves.
ZEN=""; ZEN_KEY=""

build_zen() {
    local r c line save=$OUT sx1 sx2 sx3 d1 d2 d3 near
    OUT=""
    sx1=$(( W / 4 )); sx2=$(( W / 2 + 4 )); sx3=$(( W - W/5 ))
    for (( r=1; r<=H-2; r++ )); do
        line=""
        for (( c=1; c<=W; c++ )); do
            # the comb bends around each stone: distance to the nearest one
            # decides which of the two rake glyphs lands here
            d1=$(( c - sx1 )); (( d1 < 0 )) && d1=$(( -d1 ))
            d2=$(( c - sx2 )); (( d2 < 0 )) && d2=$(( -d2 ))
            d3=$(( c - sx3 )); (( d3 < 0 )) && d3=$(( -d3 ))
            near=$d1
            (( d2 < near )) && near=$d2
            (( d3 < near )) && near=$d3
            if (( (r * 3 + near) % 4 == 0 )); then line+="≈"
            elif (( (r * 3 + near) % 4 == 2 )); then line+="~"
            else line+=" "
            fi
        done
        bgtable_sty 178 170 152 "$r"
        put "$r" 1 "$STY" "$line"
    done
    # three stones, each with moss on the shaded side
    local sy=$(( H / 2 )) i sx sh
    for i in 0 1 2; do
        case $i in
            0) sx=$sx1; sh=3 ;;
            1) sx=$sx2; sh=4 ;;
            *) sx=$sx3; sh=2 ;;
        esac
        for (( r=sy-sh; r<=sy; r++ )); do
            (( r < 1 || r > H-2 )) && continue
            local half=$(( sh - (sy - r) / 2 ))
            (( half < 1 )) && half=1
            tile_of "█" $(( half * 2 + 2 ))
            bgtable_sty $(( 96 + (sy - r) * 6 )) $(( 92 + (sy - r) * 6 )) \
                        $(( 96 + (sy - r) * 6 )) "$r"
            put "$r" $(( sx - half )) "$STY" "${TILE:0:$(( half * 2 + 1 ))}"
        done
        (( sy >= 1 && sy <= H-2 )) && {
            bgtable_sty 96 138 76 "$sy"
            put "$sy" $(( sx - sh )) "$STY" "▁▁"
        }
    done
    ZEN=$OUT
    OUT=$save
}

MAPLE=("❦" "✿" "❧" "◕")

scene_ok_zen() {
    local f=$1 r t i x y top msg lx ly
    BG_KIND=4
    if [ "$BG_KEY" != "zen$H" ]; then
        bgtable_reset
        for (( r=1; r<=H-1; r++ )); do
            t=$(( (r-1)*1000 / (H>1 ? H-1 : 1) ))
            bgtable_row "$r" $(( 208 - 26*t/1000 )) $(( 200 - 26*t/1000 )) \
                             $(( 182 - 24*t/1000 ))
        done
        BG_KEY="zen$H"
        ZEN_KEY=""                  # the gravel sits on this backdrop
    fi
    bgtable_paint

    [ "$ZEN_KEY" = "$H$W" ] || { build_zen; ZEN_KEY="$H$W"; }
    OUT+=$ZEN

    # a maple leaf tumbling across the gravel on the breeze
    lx=$(( (f * 2 / 5) % (W + 12) - 6 ))
    ly=$(( H/3 + (${SIN[$(( (f*2) % 60 ))]} - 500) * (H/4) / 700 + H/6 ))
    if (( ly >= 1 && ly <= H-1 && lx >= 1 )); then
        bgtable_sty 196 96 48 "$ly"
        put "$ly" "$lx" "$STY" "${MAPLE[$(( (f/3) % 4 ))]}"
    fi

    # a few more leaves settled in the gravel, and grains catching the light
    for (( i=0; i<7; i++ )); do
        y=$(( 2 + (i * 5 + H/6) % (H - 3) ))
        x=$(( 3 + (i * 53 + i*i*7) % (W - 4) ))
        bgtable_sty $(( 180 - i*6 )) $(( 110 + i*5 )) 60 "$y"
        put "$y" "$x" "$STY" "❧"
    done
    for (( i=0; i<16; i++ )); do
        y=$(( 1 + (i * 7 + i/3) % (H - 2) ))
        x=$(( 1 + (i * 41 + i*i*11) % W ))
        (( ${SIN[$(( (f*2 + i*23) % 60 ))]} > 700 )) || continue
        bgtable_sty 245 240 226 "$y"
        put "$y" "$x" "$STY" "˙"
    done

    top=$(( H/2 - 7 ))
    (( top < 1 )) && top=1
    if (( H >= 20 && W >= 60 )); then
        draw_big "$top" BANNER_OK 84 90 78  220 214 196
        top=$(( top + 6 ))
    else
        top=1
        msg="✓  ALL GOOD"
        center ${#msg}
        bgtable_sty 84 90 78 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 1 ))
    fi
    msg="nothing out of place"
    center ${#msg}
    bgtable_sty 110 114 100 "$top"
    put "$top" "$COL" "$STY" "$msg"
}

# ------------------------------------------------------ happy scene: wheat ----

# Late afternoon over a wheat field: a mill turning on the ridge, the crop
# combed into rows that ripple as the wind crosses them, poppies through it and
# swifts cutting over the top. Four sails only ever land in two positions, so
# the wheel is two glyph sets rather than trigonometry per frame.
scene_ok_wheat() {
    local f=$1 r t i x y top msg hz off n ph mx my arm ch

    hz=$(( H * 52 / 100 ))
    (( hz < 3 )) && hz=3
    (( hz > H-3 )) && hz=$(( H-3 ))
    BG_KIND=4
    if [ "$BG_KEY" != "wheat$H" ]; then
        bgtable_reset
        for (( r=1; r<=hz; r++ )); do
            t=$(( (r-1)*1000 / (hz>1 ? hz : 1) ))
            bgtable_row "$r" $(( 96 + 150*t/1000 )) $(( 150 + 80*t/1000 )) \
                             $(( 214 - 46*t/1000 ))
        done
        for (( r=hz+1; r<=H-1; r++ )); do
            t=$(( (r-hz)*1000 / (H-hz>0 ? H-hz : 1) ))
            bgtable_row "$r" $(( 206 - 34*t/1000 )) $(( 160 - 46*t/1000 )) \
                             $(( 70 - 26*t/1000 ))
        done
        BG_KEY="wheat$H"
    fi
    bgtable_paint

    # a low hazy sun, off to the right of the mill
    local sr=$(( 2 + hz / 5 )) sc=$(( W - W/4 ))
    for i in 0 1 2; do
        r=$(( sr + i ))
        (( r < 1 || r > hz )) && continue
        bgtable_sty 255 $(( 206 + ${SIN[$(( f % 60 ))]} * 40 / 1000 )) 130 "$r"
        put "$r" $(( sc - 4 )) "$STY" "${SUN_SEA[$i]}"
    done

    # the mill: tower down to the ridge, then the sails on the hub
    mx=$(( W/4 )); my=$(( hz - 5 ))
    (( my < 2 )) && my=2
    for (( r=my+1; r<=hz; r++ )); do
        bgtable_sty $(( 112 - (r - my) * 3 )) 78 54 "$r"
        put "$r" $(( mx - 1 )) "$STY" "███"
    done
    bgtable_sty 146 104 70 "$my"
    put "$my" $(( mx - 1 )) "$STY" "▟█▙"
    ph=$(( (f / 3) % 2 ))
    arm=$(( 3 + hz / 8 ))
    for (( n=1; n<=arm; n++ )); do
        if (( ph )); then
            for i in 0 1 2 3; do
                case $i in
                    0) y=$(( my - n )); x=$(( mx + n*2 )); ch="╱" ;;
                    1) y=$(( my + n )); x=$(( mx - n*2 )); ch="╱" ;;
                    2) y=$(( my + n )); x=$(( mx + n*2 )); ch="╲" ;;
                    *) y=$(( my - n )); x=$(( mx - n*2 )); ch="╲" ;;
                esac
                (( y < 1 || y > hz )) && continue
                bgtable_sty 250 244 226 "$y"
                put "$y" "$x" "$STY" "$ch"
            done
        else
            bgtable_sty 250 244 226 "$my"
            put "$my" $(( mx + n*2 )) "$STY" "─"
            put "$my" $(( mx - n*2 )) "$STY" "─"
            for i in 0 1; do
                y=$(( i ? my + n : my - n ))
                (( y < 1 || y > hz )) && continue
                bgtable_sty 250 244 226 "$y"
                put "$y" "$mx" "$STY" "│"
            done
        fi
    done

    # swifts working the air over the ridge
    for i in 0 1 2; do
        x=$(( (f * 5 / 10 + i * 21) % (W + 18) - 9 ))
        y=$(( 2 + i + hz / 4 ))
        (( y < 1 || y > hz )) && continue
        bgtable_sty 58 44 40 "$y"
        if (( (f/4 + i) % 2 )); then put "$y" "$x" "$STY" "╲╱"
        else                         put "$y" "$x" "$STY" "╱╲"; fi
    done

    # the crop: one comb tile, each row drifting at its own speed
    tile_of "ψ❙ψ  ❙ ψ ❙" $(( W + 14 ))
    for (( r=hz+1; r<=H-1; r++ )); do
        off=$(( (f * (1 + r % 2) / 4 + r * 3) % 10 ))
        bgtable_sty $(( 232 - (r - hz) * 5 )) $(( 192 - (r - hz) * 7 )) 86 "$r"
        put "$r" 1 "$STY" "${TILE:off:W}"
    done

    # poppies nodding in it
    for (( i=0; i<14; i++ )); do
        y=$(( hz + 1 + (i * 3) % (H - hz - 1 > 0 ? H - hz - 1 : 1) ))
        (( y > H-1 )) && continue
        x=$(( 2 + (i * 43 + i*i*7) % (W - 2)
                + ${SIN[$(( (f*2 + i*11) % 60 ))]} / 400 ))
        bgtable_sty 226 74 62 "$y"
        put "$y" "$x" "$STY" "✿"
    done

    top=$(( hz / 2 - 3 ))
    (( top < 1 )) && top=1
    if (( H >= 20 && W >= 60 )); then
        draw_big "$top" BANNER_OK 255 252 240  120 80 20
        top=$(( top + 6 ))
    else
        top=1
        msg="✓  ALL GOOD"
        center ${#msg}
        bgtable_sty 255 252 240 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 1 ))
    fi
    msg="the harvest is in"
    center ${#msg}
    bgtable_sty 250 226 170 "$top"
    put "$top" "$COL" "$STY" "$msg"
}

# ----------------------------------------------------- happy scene: forest ----

# Deep woodland with sun coming through the canopy: trunks in the middle
# distance, three light shafts leaning across them, motes turning over in the
# beams, and ferns and mushrooms on the floor.
scene_ok_forest() {
    local f=$1 r t i x y top msg n g lum floor off sx wide

    floor=$(( H - 4 ))
    (( floor < 4 )) && floor=$(( H - 1 ))
    BG_KIND=4
    if [ "$BG_KEY" != "frst$H" ]; then
        bgtable_reset
        for (( r=1; r<=floor; r++ )); do
            t=$(( (r-1)*1000 / (floor>1 ? floor : 1) ))
            bgtable_row "$r" $(( 16 + 34*t/1000 )) $(( 40 + 44*t/1000 )) \
                             $(( 22 + 20*t/1000 ))
        done
        for (( r=floor+1; r<=H-1; r++ )); do
            t=$(( (r-floor)*1000 / (H-floor>0 ? H-floor : 1) ))
            bgtable_row "$r" $(( 62 - 14*t/1000 )) $(( 48 - 12*t/1000 )) \
                             $(( 32 - 8*t/1000 ))
        done
        BG_KEY="frst$H"
    fi
    bgtable_paint

    # canopy across the top, stirring a little
    tile_of "▓▒▓▓▒░▓▒" $(( W + 12 ))
    for (( r=1; r<=2 && r<=H-2; r++ )); do
        off=$(( (f / 6 + r * 4) % 8 ))
        bgtable_sty $(( 30 + r*8 )) $(( 96 + r*14 )) $(( 44 + r*6 )) "$r"
        put "$r" 1 "$STY" "${TILE:off:W}"
    done

    # trunks, thinner and paler the further back they stand
    for i in 0 1 2 3 4; do
        x=$(( 3 + (i * 47 + i*i*11) % (W - 5) ))
        wide=$(( i % 2 ))
        for (( r=3; r<=floor; r++ )); do
            bgtable_sty $(( 68 + i*6 )) $(( 48 + i*4 )) $(( 34 + i*3 )) "$r"
            (( wide )) && put "$r" "$x" "$STY" "██" || put "$r" "$x" "$STY" "█"
        done
    done

    # light shafts: pale wedges leaning down through the trunks
    for i in 0 1 2; do
        sx=$(( 4 + i * (W / 3) + (${SIN[$(( (f + i*20) % 60 ))]} - 500) / 160 ))
        for (( r=2; r<=floor; r++ )); do
            g=$(( 1000 - (r - 2) * 800 / (floor > 3 ? floor - 2 : 1) ))
            (( g < 120 )) && g=120
            tile_of "░" $(( r / 2 + 4 ))
            bgtable_sty $(( 110 + 130*g/1000 )) $(( 116 + 128*g/1000 )) \
                        $(( 60 + 70*g/1000 )) "$r"
            put "$r" $(( sx + r*2 )) "$STY" "${TILE:0:$(( r/3 + 2 ))}"
        done
    done

    # motes turning over slowly in the beams
    for (( i=0; i<26; i++ )); do
        y=$(( 2 + (f / 6 + i * 5) % (floor > 2 ? floor - 1 : 1) ))
        x=$(( 1 + (i * 37 + i*i*7) % W
                + (${SIN[$(( (f*2 + i*13) % 60 ))]} - 500) / 300 ))
        lum=$(( 200 + ${SIN[$(( (f + i*9) % 60 ))]} * 55 / 1000 ))
        bgtable_sty "$lum" "$lum" 170 "$y"
        if (( i % 3 )); then put "$y" "$x" "$STY" "·"
        else                 put "$y" "$x" "$STY" "˙"; fi
    done

    # the floor: leaf litter, then ferns and a few mushrooms on it
    tile_of "❧ ˙ ❦  ˙ ❧" $(( W + 12 ))
    for (( r=floor+1; r<=H-1; r++ )); do
        bgtable_sty $(( 128 - (r - floor) * 8 )) $(( 88 - (r - floor) * 6 )) 48 "$r"
        put "$r" 1 "$STY" "${TILE:$(( (r * 5) % 10 )):W}"
    done
    for (( i=0; i<12; i++ )); do
        y=$(( floor - (i % 2) ))
        (( y < 1 || y > H-1 )) && continue
        x=$(( 2 + (i * 41 + i*i*5) % (W - 3) ))
        if (( i % 3 == 0 )); then
            bgtable_sty 216 108 96 "$y"
            put "$y" "$x" "$STY" "⌂"
        else
            bgtable_sty $(( 54 + i*4 )) $(( 138 + i*6 )) 64 "$y"
            put "$y" $(( x + (${SIN[$(( (f*2 + i*17) % 60 ))]} - 500) / 500 )) \
                "$STY" "ψ"
        fi
    done

    top=$(( floor / 2 - 3 ))
    (( top < 1 )) && top=1
    if (( H >= 20 && W >= 60 )); then
        draw_big "$top" BANNER_OK 240 255 225  20 50 26
        top=$(( top + 6 ))
    else
        top=1
        msg="✓  ALL GOOD"
        center ${#msg}
        bgtable_sty 240 255 225 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 1 ))
    fi
    msg="quiet in the woods"
    center ${#msg}
    bgtable_sty 186 220 170 "$top"
    put "$top" "$COL" "$STY" "$msg"
}

# ----------------------------------------------------- happy scene: summit ----

# Above the weather: a snow-capped peak with a flag on it standing out of a sea
# of cloud, further ranges behind, and an eagle turning overhead. The peak and
# the ranges depend only on the window size, so they are rasterized once and
# replayed; the cloud sea and the flag are all that move.
SUMMIT=""; SUMMIT_KEY=""

build_summit() { # cloudline
    local cl=$1 r half apex px save=$OUT line c
    OUT=""
    px=$(( W/2 - W/9 ))
    apex=$(( cl - cl * 3 / 5 ))
    (( apex < 2 )) && apex=2
    # the ranges behind, a low ragged silhouette on the cloud line
    line=""
    for (( c=1; c<=W; c++ )); do
        if (( ${SIN[$(( (c * 190 / W) % 60 ))]} + ${SIN[$(( (c * 70 / W) % 60 ))]} > 1150 )); then
            line+="▲"
        else
            line+="▄"
        fi
    done
    (( cl-1 >= 1 )) && {
        bgtable_sty 78 96 138 $(( cl - 1 ))
        put $(( cl - 1 )) 1 "$STY" "$line"
    }
    # the near peak: rock below, snow on the last few rows near the top
    for (( r=apex; r<=cl; r++ )); do
        half=$(( (r - apex) * (W / 7) / (cl - apex > 0 ? cl - apex : 1) ))
        tile_of "█" $(( half * 2 + 3 ))
        if (( r - apex < 3 )); then
            bgtable_sty 244 248 255 "$r"
        elif (( (r + half) % 4 == 0 )); then
            bgtable_sty 226 232 244 "$r"
        else
            bgtable_sty $(( 92 + (r - apex) * 3 )) $(( 88 + (r - apex) * 3 )) \
                        $(( 104 + (r - apex) * 3 )) "$r"
        fi
        put "$r" $(( px - half )) "$STY" "${TILE:0:$(( half * 2 + 1 ))}"
    done
    # the pole, planted just below the apex
    for (( r=apex-2; r<apex; r++ )); do
        (( r < 1 )) && continue
        bgtable_sty 210 214 226 "$r"
        put "$r" "$px" "$STY" "│"
    done
    SUMMIT=$OUT
    OUT=$save
}

scene_ok_summit() {
    local f=$1 r t i x y top msg cl off lum apex px

    cl=$(( H * 62 / 100 ))
    (( cl < 5 )) && cl=5
    (( cl > H-3 )) && cl=$(( H-3 ))
    BG_KIND=4
    if [ "$BG_KEY" != "smt$H" ]; then
        bgtable_reset
        for (( r=1; r<=cl; r++ )); do
            t=$(( (r-1)*1000 / (cl>1 ? cl : 1) ))
            bgtable_row "$r" $(( 24 + 104*t/1000 )) $(( 56 + 106*t/1000 )) \
                             $(( 126 + 76*t/1000 ))
        done
        for (( r=cl+1; r<=H-1; r++ )); do
            t=$(( (r-cl)*1000 / (H-cl>0 ? H-cl : 1) ))
            bgtable_row "$r" $(( 196 - 40*t/1000 )) $(( 208 - 38*t/1000 )) \
                             $(( 226 - 34*t/1000 ))
        done
        BG_KEY="smt$H"
        SUMMIT_KEY=""               # the peak sits on this backdrop
    fi
    bgtable_paint

    # a small hard sun, the way it looks with no air in the way
    local sr=$(( 2 + cl / 8 )) sc=$(( W - W/5 ))
    for i in 0 1 2; do
        r=$(( sr + i ))
        (( r < 1 || r > cl )) && continue
        bgtable_sty 255 250 $(( 206 + ${SIN[$(( f % 60 ))]} * 40 / 1000 )) "$r"
        put "$r" $(( sc - 4 )) "$STY" "${SUN_SEA[$i]}"
    done

    [ "$SUMMIT_KEY" = "$H$W" ] || { build_summit "$cl"; SUMMIT_KEY="$H$W"; }
    OUT+=$SUMMIT

    # the flag, snapping at the top of the pole
    px=$(( W/2 - W/9 ))
    apex=$(( cl - cl * 3 / 5 ))
    (( apex < 2 )) && apex=2
    if (( apex-2 >= 1 )); then
        bgtable_sty 236 92 88 $(( apex - 2 ))
        if (( (f/3) % 2 )); then put $(( apex - 2 )) $(( px + 1 )) "$STY" "▰▰▬"
        else                     put $(( apex - 2 )) $(( px + 1 )) "$STY" "▬▰▰"; fi
    fi

    # the cloud sea, each band rolling at its own pace
    tile_of "▄▂▃▄▅▃▄▂" $(( W + 12 ))
    for (( r=cl; r<=H-1; r++ )); do
        off=$(( (f * (1 + r % 3) / 5 + r * 3) % 8 ))
        lum=$(( 236 - (r - cl) * 6 ))
        bgtable_sty "$lum" "$lum" 255 "$r"
        put "$r" 1 "$STY" "${TILE:off:W}"
    done

    # an eagle turning on the thermals, high up
    local ex=$(( (f * 3 / 8) % (W + 20) - 10 ))
    local ey=$(( 2 + cl / 3 + (${SIN[$(( (f*2) % 60 ))]} - 500) / 300 ))
    if (( ey >= 1 && ey <= cl )); then
        bgtable_sty 42 40 52 "$ey"
        if (( (f/5) % 2 )); then put "$ey" "$ex" "$STY" "╲╱"
        else                     put "$ey" "$ex" "$STY" "‾╲╱‾"; fi
    fi

    top=$(( apex / 2 ))
    (( top < 1 )) && top=1
    if (( H >= 20 && W >= 60 )); then
        draw_big "$top" BANNER_OK 255 255 255  40 70 120
        top=$(( top + 6 ))
    else
        top=1
        msg="✓  ALL GOOD"
        center ${#msg}
        bgtable_sty 255 255 255 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 1 ))
    fi
    msg="nothing left to climb"
    center ${#msg}
    bgtable_sty 220 234 255 "$top"
    put "$top" "$COL" "$STY" "$msg"
}

# --------------------------------------------------- happy scene: waterfall ---

# A cliff waterfall dropping into a plunge pool. The rock face, the lip and the
# side shelves depend only on the window size, so they are rasterized once and
# replayed; the cascade is one glyph tile sliced at a per-row offset, so the
# whole drop costs a dozen writes a frame instead of a test per cell.
FALLS=""; FALLS_KEY=""

build_falls() { # lip pool fx fw
    local lip=$1 pool=$2 fx=$3 fw=$4 r c t save=$OUT half
    OUT=""
    # the dry rock face, banded and flecked
    tile_of "▓▒▓▓░▒▓░" $(( W + 12 ))
    for (( r=1; r<=pool; r++ )); do
        t=$(( (r-1)*1000 / (pool>1 ? pool : 1) ))
        bgtable_sty $(( 78 + 18*t/1000 )) $(( 84 + 16*t/1000 )) \
                    $(( 76 + 14*t/1000 )) "$r"
        put "$r" 1 "$STY" "${TILE:$(( (r * 3) % 8 )):W}"
    done
    # the wet chute the water runs down, darker than the face around it
    tile_of "░" $(( fw + 2 ))
    for (( r=lip; r<=pool; r++ )); do
        bgtable_sty 44 62 74 "$r"
        put "$r" "$fx" "$STY" "${TILE:0:fw}"
    done
    # moss on the lip it goes over
    tile_of "▄" $(( fw + 4 ))
    bgtable_sty 96 150 92 "$lip"
    put "$lip" $(( fx - 1 )) "$STY" "${TILE:0:$(( fw + 2 ))}"
    # two shelves either side, catching a little of the spray
    half=$(( W / 7 )); (( half < 3 )) && half=3
    for c in 0 1; do
        r=$(( lip + 3 + c * 5 ))
        (( r < 1 || r > pool-1 )) && continue
        tile_of "▀" $(( half + 2 ))
        bgtable_sty $(( 104 - c*10 )) $(( 110 - c*10 )) $(( 100 - c*10 )) "$r"
        if (( c == 0 )); then
            put "$r" 2 "$STY" "${TILE:0:half}"
        else
            put "$r" $(( W - half )) "$STY" "${TILE:0:half}"
        fi
    done
    FALLS=$OUT
    OUT=$save
}

scene_ok_waterfall() {
    local f=$1 r t i x y top msg off lum pool lip fx fw g n

    pool=$(( H * 74 / 100 ))
    (( pool < 5 )) && pool=5
    (( pool > H-3 )) && pool=$(( H-3 ))
    lip=$(( pool / 4 + 2 ))
    (( lip > pool-2 )) && lip=$(( pool - 2 ))
    (( lip < 2 )) && lip=2
    fw=$(( W / 6 )); (( fw < 5 )) && fw=5
    fx=$(( W/2 - fw/2 + W/14 )); (( fx < 2 )) && fx=2
    BG_KIND=4
    if [ "$BG_KEY" != "wfall$H" ]; then
        bgtable_reset
        for (( r=1; r<=pool; r++ )); do
            t=$(( (r-1)*1000 / (pool>1 ? pool : 1) ))
            bgtable_row "$r" $(( 62 + 20*t/1000 )) $(( 68 + 18*t/1000 )) \
                             $(( 60 + 16*t/1000 ))
        done
        for (( r=pool+1; r<=H-1; r++ )); do
            t=$(( (r-pool)*1000 / (H-pool>0 ? H-pool : 1) ))
            bgtable_row "$r" $(( 32 + 8*t/1000 )) $(( 104 - 26*t/1000 )) \
                             $(( 120 - 30*t/1000 ))
        done
        BG_KEY="wfall$H"
        FALLS_KEY=""                # the rock sits on this backdrop
    fi
    bgtable_paint

    [ "$FALLS_KEY" = "$H$W" ] ||
        { build_falls "$lip" "$pool" "$fx" "$fw"; FALLS_KEY="$H$W"; }
    OUT+=$FALLS

    # the cascade: the tile slides faster the further the water has fallen
    tile_of "║│┃║┆│┃│" $(( fw + 12 ))
    for (( r=lip+1; r<=pool; r++ )); do
        off=$(( (f * (3 + (r - lip) / 3) + r * 2) % 8 ))
        lum=$(( 206 + (r % 3) * 14 ))
        bgtable_sty "$lum" $(( lum + 20 > 255 ? 255 : lum + 20 )) 255 "$r"
        put "$r" "$fx" "$STY" "${TILE:off:fw}"
    done
    # white water right at the lip, where it breaks over the moss
    if (( lip+1 <= H-1 )); then
        tile_of "▀▔▀▀▔▀▀▔" $(( fw + 4 ))
        bgtable_sty 250 253 255 $(( lip + 1 ))
        put $(( lip + 1 )) "$fx" "$STY" "${TILE:$(( (f*2) % 8 )):fw}"
    fi

    # spray boiling up out of the plunge
    for (( i=0; i<26; i++ )); do
        y=$(( pool - (f / 2 + i * 5) % 5 ))
        (( y < 1 || y > H-1 )) && continue
        x=$(( fx - 3 + (i * 7 + f * 2) % (fw + 6) ))
        g=$(( 226 + (i % 4) * 7 ))
        bgtable_sty "$g" 250 255 "$y"
        if (( i % 3 )); then put "$y" "$x" "$STY" "∘"
        else                 put "$y" "$x" "$STY" "˙"; fi
    done

    # the sun catching the mist: a short band of colour beside the fall
    for (( i=0; i<7; i++ )); do
        y=$(( pool - 4 + i / 2 ))
        (( y < 1 || y > H-1 )) && continue
        x=$(( fx + fw + 2 + i ))
        case $(( i % 7 )) in
            0) bgtable_sty 255 130 130 "$y" ;;
            1) bgtable_sty 255 180 110 "$y" ;;
            2) bgtable_sty 250 235 130 "$y" ;;
            3) bgtable_sty 140 225 150 "$y" ;;
            4) bgtable_sty 130 210 240 "$y" ;;
            5) bgtable_sty 140 165 235 "$y" ;;
            *) bgtable_sty 190 150 230 "$y" ;;
        esac
        (( ${SIN[$(( (f*2 + i*9) % 60 ))]} > 340 )) &&
            put "$y" "$x" "$STY" "░"
    done

    # the pool: bands of ripple spreading away from where it lands
    tile_of "≈ ~ ˜≈  ~" $(( W + 12 ))
    for (( r=pool+1; r<=H-1; r++ )); do
        off=$(( (f * (1 + r % 3) / 3 + r * 4) % 9 ))
        bgtable_sty $(( 130 - (r - pool) * 8 )) $(( 208 - (r - pool) * 10 )) \
                    $(( 218 - (r - pool) * 8 )) "$r"
        put "$r" 1 "$STY" "${TILE:off:W}"
    done
    # the foam ring, churning where the water goes in
    for (( r=pool+1; r<=pool+2 && r<=H-1; r++ )); do
        tile_of "▓▒░▒▓░▒" $(( fw + 10 ))
        bgtable_sty 240 250 255 "$r"
        put "$r" $(( fx - 2 )) "$STY" "${TILE:$(( (f + r) % 7 )):$(( fw + 4 ))}"
    done

    # ferns on the wet rock, nodding in the draught off the fall
    for (( i=0; i<12; i++ )); do
        y=$(( lip + 2 + (i * 3 + i/3) % (pool - lip - 1 > 0 ? pool - lip - 1 : 1) ))
        (( y < 1 || y > H-1 )) && continue
        x=$(( 2 + (i * 43 + i*i*7) % (W - 3) ))
        (( x > fx - 2 && x < fx + fw + 2 )) && continue
        bgtable_sty $(( 70 + i*4 )) $(( 148 + i*6 )) 78 "$y"
        put "$y" $(( x + (${SIN[$(( (f*2 + i*13) % 60 ))]} - 500) / 500 )) \
            "$STY" "ψ"
    done

    top=$(( lip - 6 ))
    if (( H >= 20 && W >= 60 && top >= 1 )); then
        draw_big "$top" BANNER_OK 250 255 255  20 60 70
        top=$(( top + 6 ))
    else
        top=1
        msg="✓  ALL GOOD"
        center ${#msg}
        bgtable_sty 250 255 255 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 1 ))
    fi
    msg="running clear"
    center ${#msg}
    bgtable_sty 190 225 235 "$top"
    put "$top" "$COL" "$STY" "$msg"
}

# ----------------------------------------------------- happy scene: hearth ----

# Indoors for once: a brick fireplace with the fire settled in, a cat asleep on
# the rug and a mug going cold on the mantel. The brickwork, the opening and
# everything on the shelf are fixed for a window size, so they are rasterized
# once; the flames, the embers and the glow on the bricks are all that move.
HEARTH=""; HEARTH_KEY=""
FLAME_CH=("█" "▓" "▒" "░")

build_hearth() { # fb_top fb_bot fbx fbw floor
    local ft=$1 fb=$2 fbx=$3 fbw=$4 floor=$5 r c save=$OUT span
    OUT=""
    # brick courses, each one offset half a brick from the last
    for (( r=1; r<=floor; r++ )); do
        tile_of "█████▏" $(( W + 12 ))
        bgtable_sty $(( 118 - (r % 3) * 6 )) $(( 66 - (r % 3) * 4 )) 56 "$r"
        put "$r" 1 "$STY" "${TILE:$(( (r * 3) % 6 )):W}"
    done
    # the firebox: a dark opening with a stone lintel over it
    tile_of "█" $(( fbw + 2 ))
    for (( r=ft; r<=fb; r++ )); do
        bgtable_sty $(( 16 + (r - ft) * 2 )) 12 14 "$r"
        put "$r" "$fbx" "$STY" "${TILE:0:fbw}"
    done
    if (( ft-1 >= 1 )); then
        bgtable_sty 168 158 146 $(( ft - 1 ))
        tile_of "▄" $(( fbw + 6 ))
        put $(( ft - 1 )) $(( fbx - 2 )) "$STY" "${TILE:0:$(( fbw + 4 ))}"
    fi
    # the mantel, running most of the width, with a few things stood on it
    span=$(( fbw + 14 )); (( span > W - 4 )) && span=$(( W - 4 ))
    if (( ft-3 >= 1 )); then
        tile_of "▀" $(( span + 2 ))
        bgtable_sty 186 172 156 $(( ft - 2 ))
        put $(( ft - 2 )) $(( (W - span) / 2 )) "$STY" "${TILE:0:span}"
        bgtable_sty 148 136 122 $(( ft - 3 ))
        put $(( ft - 3 )) $(( (W - span) / 2 + 4 )) "$STY" "▟▙"
        bgtable_sty 226 226 232 $(( ft - 3 ))
        put $(( ft - 3 )) $(( W/2 - 6 )) "$STY" "◷"
        bgtable_sty 214 226 236 $(( ft - 3 ))
        put $(( ft - 3 )) $(( W/2 + 6 )) "$STY" "▄▟"
    fi
    # hearthstone, then the rug in front of it
    for (( r=floor+1; r<=H-1; r++ )); do
        bgtable_sty 150 142 132 "$r"
        put "$r" 1 "$STY" "${SPACES// /█}"
    done
    for (( r=floor+2; r<=H-1; r++ )); do
        tile_of "▬▬▭▬▬▭▬" $(( W + 8 ))
        bgtable_sty $(( 132 - (r - floor) * 8 )) $(( 46 - (r - floor) * 4 )) 52 "$r"
        put "$r" $(( W/6 )) "$STY" "${TILE:$(( (r * 2) % 7 )):$(( W - W/3 ))}"
    done
    HEARTH=$OUT
    OUT=$save
}

scene_ok_hearth() {
    local f=$1 r c t i x y top msg n g lum ft fb fbx fbw floor hgt

    floor=$(( H - 4 ))
    (( floor < 6 )) && floor=$(( H - 2 ))
    fb=$(( floor - 1 ))
    ft=$(( fb - H/3 )); (( ft < 4 )) && ft=4
    (( ft > fb - 2 )) && ft=$(( fb - 2 ))
    fbw=$(( W / 5 )); (( fbw < 9 )) && fbw=9
    fbx=$(( W/2 - fbw/2 ))
    (( fbx < 2 )) && fbx=2
    BG_KIND=4
    if [ "$BG_KEY" != "hrth$H" ]; then
        bgtable_reset
        for (( r=1; r<=H-1; r++ )); do
            t=$(( (r-1)*1000 / (H>1 ? H-1 : 1) ))
            bgtable_row "$r" $(( 46 + 40*t/1000 )) $(( 26 + 20*t/1000 )) \
                             $(( 24 + 16*t/1000 ))
        done
        BG_KEY="hrth$H"
        HEARTH_KEY=""               # the brickwork sits on this backdrop
    fi
    bgtable_paint

    [ "$HEARTH_KEY" = "$H$W" ] ||
        { build_hearth "$ft" "$fb" "$fbx" "$fbw" "$floor"; HEARTH_KEY="$H$W"; }
    OUT+=$HEARTH

    # the fire: one column of flame per cell of the grate, each on its own phase
    # so the whole thing licks up and dies back unevenly
    hgt=$(( fb - ft - 1 )); (( hgt < 2 )) && hgt=2
    (( hgt > 6 )) && hgt=6
    for (( c=1; c<fbw-1; c++ )); do
        x=$(( fbx + c ))
        n=$(( 2 + ${SIN[$(( (f*3 + c*9) % 60 ))]} * (hgt - 1) / 1000 ))
        for (( i=0; i<=n; i++ )); do
            r=$(( fb - i ))
            (( r < 1 || r > H-1 )) && continue
            if (( i == n )); then
                bgtable_sty 250 $(( 130 + i*10 )) 60 "$r"
                put "$r" "$x" "$STY" "▲"
            else
                bgtable_sty 255 $(( 236 - i*30 )) $(( 130 - i*22 )) "$r"
                put "$r" "$x" "$STY" "${FLAME_CH[$(( i % 4 ))]}"
            fi
        done
    done

    # logs and embers under it, breathing on their own slower cycle
    if (( fb >= 1 && fb <= H-1 )); then
        bgtable_sty 92 60 40 "$fb"
        put "$fb" $(( fbx + 1 )) "$STY" "▙▄▄▄▟"
        put "$fb" $(( fbx + fbw - 6 )) "$STY" "▟▄▄▄▙"
    fi
    for (( i=0; i<10; i++ )); do
        g=$(( ${SIN[$(( (f*2 + i*23) % 60 ))]} ))
        x=$(( fbx + 1 + (i * 5 + i*i) % (fbw - 2) ))
        bgtable_sty 255 $(( 90 + g / 8 )) $(( 40 + g / 20 )) "$fb"
        put "$fb" "$x" "$STY" "▪"
    done

    # sparks going up the flue, and the glow they throw on the lintel
    for (( i=0; i<14; i++ )); do
        y=$(( ft + 1 - (f / 3 + i * 3) % 4 ))
        (( y < 1 || y > H-1 )) && continue
        x=$(( fbx + 2 + (i * 7 + f / 4) % (fbw - 3) ))
        bgtable_sty 255 $(( 170 + i % 40 )) 90 "$y"
        put "$y" "$x" "$STY" "·"
    done
    lum=$(( ${SIN[$(( (f * 2) % 60 ))]} ))
    for (( r=ft; r<=fb; r++ )); do
        (( r < 1 || r > H-1 )) && continue
        bgtable_sty $(( 150 + lum / 12 )) $(( 88 + lum / 24 )) 62 "$r"
        put "$r" $(( fbx - 2 )) "$STY" "░"
        put "$r" $(( fbx + fbw )) "$STY" "░"
    done

    # the cat, asleep on the rug, its tail twitching now and then
    y=$(( H - 2 ))
    if (( y > floor && y <= H-1 )); then
        bgtable_sty 240 168 96 $(( y - 1 ))
        put $(( y - 1 )) $(( W/2 - 5 )) "$STY" "  ▁▄▄▄▄▁"
        bgtable_sty 236 158 88 "$y"
        put "$y" $(( W/2 - 5 )) "$STY" "▟███████▙"
        bgtable_sty 214 132 66 "$y"
        if (( (f/8) % 4 == 0 )); then
            put "$y" $(( W/2 + 4 )) "$STY" "⌒"
        else
            put "$y" $(( W/2 + 4 )) "$STY" "~"
        fi
        bgtable_sty 120 74 44 $(( y - 1 ))
        put $(( y - 1 )) $(( W/2 - 4 )) "$STY" "︶︶"
    fi

    top=$(( ft / 2 - 3 ))
    (( top < 1 )) && top=1
    if (( H >= 20 && W >= 60 )); then
        draw_big "$top" BANNER_OK 255 244 222  70 34 22
        top=$(( top + 6 ))
    else
        top=1
        msg="✓  ALL GOOD"
        center ${#msg}
        bgtable_sty 255 244 222 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 1 ))
    fi
    msg="nothing to do but sit by the fire"
    center ${#msg}
    bgtable_sty 232 190 150 "$top"
    put "$top" "$COL" "$STY" "$msg"
}

# ------------------------------------------------------ happy scene: train ----

# A steam train running through the fields at golden hour. The embankment, the
# rails and the hedgerows are fixed for a window size and rasterized once; the
# train crosses, the poles scroll past and the smoke lifts off the stack.
TRAIN=("     ▂▂▂▂▂▂▂   ▂▂▂▂▂ "
       "  ▄▟███████▙  ▟█████▙"
       " ▐███████████▌▐██████▌"
       "   ●●   ●●     ○○  ○○ ")
RAILS=""; RAILS_KEY=""

build_rails() { # hz rr
    local hz=$1 rr=$2 r c line save=$OUT
    OUT=""
    # the ranges in the far distance, sitting on the horizon
    line=""
    for (( c=1; c<=W; c++ )); do
        if (( ${SIN[$(( (c * 150 / W) % 60 ))]} + ${SIN[$(( (c * 60 / W) % 60 ))]} > 1120 )); then
            line+="▲"
        else
            line+="▄"
        fi
    done
    bgtable_sty 104 116 128 "$hz"
    put "$hz" 1 "$STY" "$line"
    # a hedgerow between the fields, then the embankment ballast
    if (( hz+2 <= H-1 )); then
        tile_of "▃▄▃▄▅▄▃▄" $(( W + 10 ))
        bgtable_sty 62 118 66 $(( hz + 2 ))
        put $(( hz + 2 )) 1 "$STY" "${TILE:0:W}"
    fi
    for (( r=rr+1; r<=H-1; r++ )); do
        tile_of "▚▞▚▞▚▞" $(( W + 8 ))
        bgtable_sty $(( 122 - (r - rr) * 8 )) $(( 108 - (r - rr) * 8 )) 92 "$r"
        put "$r" 1 "$STY" "${TILE:$(( (r * 2) % 6 )):W}"
    done
    # sleepers, then the two rails over them
    tile_of "▬ ▬ ▬ " $(( W + 8 ))
    bgtable_sty 96 74 58 "$rr"
    put "$rr" 1 "$STY" "${TILE:0:W}"
    bgtable_sty 198 202 210 "$rr"
    put "$rr" 1 "$STY" "${DASHES// /═}"
    RAILS=$OUT
    OUT=$save
}

scene_ok_train() {
    local f=$1 r t i x y top msg hz rr tx ty n g lum off

    hz=$(( H * 46 / 100 ))
    (( hz < 4 )) && hz=4
    (( hz > H-7 )) && hz=$(( H-7 ))
    (( hz < 3 )) && hz=3
    rr=$(( H - 3 ))
    (( rr < hz + 4 )) && rr=$(( hz + 4 ))
    (( rr > H-1 )) && rr=$(( H-1 ))
    BG_KIND=4
    if [ "$BG_KEY" != "trn$H" ]; then
        bgtable_reset
        for (( r=1; r<=hz; r++ )); do
            t=$(( (r-1)*1000 / (hz>1 ? hz : 1) ))
            bgtable_row "$r" $(( 96 + 154*t/1000 )) $(( 118 + 86*t/1000 )) \
                             $(( 176 - 30*t/1000 ))
        done
        for (( r=hz+1; r<=H-1; r++ )); do
            t=$(( (r-hz)*1000 / (H-hz>0 ? H-hz : 1) ))
            bgtable_row "$r" $(( 148 - 34*t/1000 )) $(( 158 - 32*t/1000 )) \
                             $(( 86 - 22*t/1000 ))
        done
        BG_KEY="trn$H"
        RAILS_KEY=""                # the track sits on this backdrop
    fi
    bgtable_paint

    # a low sun behind it all, hazy at this time of day
    local sr=$(( hz - 4 )) sc=$(( W - W/5 ))
    for i in 0 1 2; do
        r=$(( sr + i ))
        (( r < 1 || r > hz )) && continue
        bgtable_sty 255 $(( 208 + ${SIN[$(( f % 60 ))]} * 40 / 1000 )) 150 "$r"
        put "$r" $(( sc - 4 )) "$STY" "${SUN_SEA[$i]}"
    done

    [ "$RAILS_KEY" = "$H$W" ] || { build_rails "$hz" "$rr"; RAILS_KEY="$H$W"; }
    OUT+=$RAILS

    # the crop in the fields, combed into rows that lean with the breeze
    tile_of "ψ ˌ ψ  ˌ ψ" $(( W + 12 ))
    for (( r=hz+3; r<=rr-1; r++ )); do
        off=$(( (f / 5 + r * 3) % 10 ))
        bgtable_sty $(( 168 - (r - hz) * 4 )) $(( 176 - (r - hz) * 5 )) 92 "$r"
        put "$r" 1 "$STY" "${TILE:off:W}"
    done

    # telegraph poles going by, faster than the fields behind them
    for i in 0 1 2 3; do
        x=$(( W + 12 - (f * 3 / 2 + i * 33) % (W + 26) ))
        for (( n=0; n<4; n++ )); do
            r=$(( rr - 5 + n ))
            (( r < 1 || r > H-1 )) && continue
            bgtable_sty 92 78 66 "$r"
            if (( n == 0 )); then
                put "$r" $(( x - 1 )) "$STY" "╤"
            else
                put "$r" "$x" "$STY" "│"
            fi
        done
    done

    # the train, and the smoke it has been leaving behind it
    tx=$(( (f * 3 / 4) % (W + 44) - 30 ))
    ty=$(( rr - 4 ))
    for (( n=0; n<10; n++ )); do
        y=$(( ty - 1 - n ))
        (( y < 1 || y > H-1 )) && continue
        x=$(( tx + 6 - n * 3 ))
        g=$(( 226 - n * 14 ))
        bgtable_sty "$g" $(( g - 8 )) $(( g - 14 )) "$y"
        if (( n < 3 )); then      put "$y" "$x" "$STY" "▄██▄"
        elif (( n < 6 )); then    put "$y" "$x" "$STY" "▒▒▒"
        else                      put "$y" "$x" "$STY" "░░"; fi
    done
    for (( n=0; n<4; n++ )); do
        r=$(( ty + n ))
        (( r < 1 || r > H-1 )) && continue
        case $n in
            0) bgtable_sty 210 214 222 "$r" ;;
            3) bgtable_sty 60 58 66 "$r" ;;
            *) bgtable_sty $(( 56 + n*10 )) $(( 62 + n*12 )) $(( 74 + n*14 )) "$r" ;;
        esac
        put "$r" "$tx" "$STY" "${TRAIN[$n]}"
    done
    # steam venting off the pistons as the wheels come round
    if (( (f/3) % 3 == 0 )); then
        r=$(( ty + 3 ))
        (( r >= 1 && r <= H-1 )) && {
            bgtable_sty 236 240 246 "$r"
            put "$r" $(( tx - 2 )) "$STY" "≡≡"
        }
    fi

    # swifts over the field, out of the way of the smoke
    for i in 0 1 2; do
        x=$(( (f * 4 / 10 + i * 21) % (W + 18) - 9 ))
        y=$(( 2 + i * 2 + hz / 5 ))
        (( y < 1 || y > hz )) && continue
        bgtable_sty 52 46 58 "$y"
        if (( (f/4 + i) % 2 )); then put "$y" "$x" "$STY" "╲╱"
        else                         put "$y" "$x" "$STY" "╱╲"; fi
    done

    top=$(( hz / 2 - 3 ))
    (( top < 1 )) && top=1
    if (( H >= 20 && W >= 60 )); then
        draw_big "$top" BANNER_OK 255 252 240  110 70 40
        top=$(( top + 6 ))
    else
        top=1
        msg="✓  ALL GOOD"
        center ${#msg}
        bgtable_sty 255 252 240 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 1 ))
    fi
    msg="right on schedule"
    center ${#msg}
    bgtable_sty 250 226 190 "$top"
    put "$top" "$COL" "$STY" "$msg"
}

# ------------------------------------------------- happy scene: lighthouse ---

# A lighthouse on a headland at night: the lamp turns, throwing a pair of beams
# out over a calm sea, the swell catches them, and a boat comes home. The beams
# are stepped every other column, so the sweep costs a few dozen writes.
LIGHT_TOWER=("▟███▙" "█████" "▐███▌" "▐███▌" "▐███▌")

scene_ok_lighthouse() {
    local f=$1 r t i x y top msg hz lum lx ly n k dy sl g off half

    hz=$(( H * 64 / 100 ))
    (( hz < 8 )) && hz=8
    (( hz > H-3 )) && hz=$(( H-3 ))
    BG_KIND=4
    if [ "$BG_KEY" != "lhs$H" ]; then
        bgtable_reset
        for (( r=1; r<=hz; r++ )); do
            t=$(( (r-1)*1000 / (hz>1 ? hz : 1) ))
            bgtable_row "$r" $(( 10 + 26*t/1000 )) $(( 16 + 32*t/1000 )) \
                             $(( 42 + 44*t/1000 ))
        done
        for (( r=hz+1; r<=H-1; r++ )); do
            t=$(( (r-hz)*1000 / (H-hz>0 ? H-hz : 1) ))
            bgtable_row "$r" $(( 12 + 4*t/1000 )) $(( 30 + 10*t/1000 )) \
                             $(( 52 + 14*t/1000 ))
        done
        BG_KEY="lhs$H"
    fi
    bgtable_paint

    # stars, thinning out toward the horizon haze
    for (( i=0; i<40; i++ )); do
        y=$(( 1 + (i * 5 + i/4) % (hz > 2 ? hz - 2 : 1) ))
        x=$(( 1 + (i * 43 + i*i*7) % W ))
        lum=$(( 130 + ${SIN[$(( (f*2 + i*19) % 60 ))]} * 110 / 1000 ))
        bgtable_sty "$lum" "$lum" 255 "$y"
        put "$y" "$x" "$STY" "${STAR_GLYPH[$(( i % 5 ))]}"
    done

    # the lamp room, and the two beams it throws in opposite directions
    lx=$(( W - W/6 )); ly=$(( hz - 6 ))
    (( ly < 2 )) && ly=2
    sl=$(( ${SIN[$(( (f*2) % 60 ))]} - 500 ))
    for (( k=2; k<=W; k+=2 )); do
        dy=$(( k * sl / 2600 ))
        g=$(( 245 - k * 130 / (W > 1 ? W : 1) ))
        for n in 0 1; do
            if (( n == 0 )); then x=$(( lx - k )); y=$(( ly + dy ))
            else                  x=$(( lx + k )); y=$(( ly - dy ))
            fi
            (( x < 1 || x > W || y < 1 || y > hz )) && continue
            bgtable_sty "$g" "$g" $(( g * 3 / 4 )) "$y"
            put "$y" "$x" "$STY" "░"
            # the beam widens as it gets further from the lens
            if (( k > W/3 && y+1 <= hz )); then
                bgtable_sty $(( g * 3 / 4 )) $(( g * 3 / 4 )) $(( g / 2 )) $(( y + 1 ))
                put $(( y + 1 )) "$x" "$STY" "░"
            fi
        done
    done

    # the sea, each band of swell sliding at its own pace
    tile_of "~ ≈  ˜ ≈ " $(( W + 12 ))
    for (( r=hz+1; r<=H-1; r++ )); do
        off=$(( (f * (1 + r % 3) / 4 + r * 5) % 9 ))
        t=$(( (r-hz)*1000 / (H-hz>0 ? H-hz : 1) ))
        bgtable_sty $(( 70 - 30*t/1000 )) $(( 120 - 44*t/1000 )) \
                    $(( 170 - 50*t/1000 )) "$r"
        put "$r" 1 "$STY" "${TILE:off:W}"
    done
    # what the lamp leaves on the water, broken up by the swell
    for (( r=hz+1; r<=H-1; r++ )); do
        (( (r + f/5) % 3 == 0 )) && continue
        g=$(( 170 + ${SIN[$(( (f*3 + r*11) % 60 ))]} * 70 / 1000 ))
        bgtable_sty "$g" "$g" 200 "$r"
        put "$r" $(( lx - 2 + (${SIN[$(( (f*2 + r*17) % 60 ))]} - 500) / 250 )) \
            "$STY" "≈≈≈"
    done

    # the headland the tower stands on
    for (( r=hz; r<=H-1; r++ )); do
        half=$(( W/9 - (r - hz) * 2 ))
        (( half < 2 )) && half=2
        tile_of "█" $(( half * 2 + 2 ))
        bgtable_sty $(( 44 + (r - hz) * 3 )) $(( 46 + (r - hz) * 3 )) \
                    $(( 54 + (r - hz) * 3 )) "$r"
        put "$r" $(( lx - half )) "$STY" "${TILE:0:$(( half * 2 + 1 ))}"
    done

    # the tower itself, with a lit window partway up
    for n in 0 1 2 3 4; do
        r=$(( ly + 1 + n ))
        (( r < 1 || r > H-1 )) && continue
        if (( n % 2 )); then bgtable_sty 236 238 244 "$r"
        else                 bgtable_sty 210 84 80 "$r"
        fi
        put "$r" $(( lx - 2 )) "$STY" "${LIGHT_TOWER[$n]}"
    done
    (( ly+3 >= 1 && ly+3 <= H-1 )) && {
        bgtable_sty 255 224 150 $(( ly + 3 ))
        put $(( ly + 3 )) "$lx" "$STY" "▪"
    }
    # the lens, flaring as it comes round to face us
    lum=$(( 200 + ${SIN[$(( (f*2) % 60 ))]} * 55 / 1000 ))
    bgtable_sty 255 "$lum" 140 "$ly"
    put "$ly" $(( lx - 2 )) "$STY" "▁███▁"

    # a boat making for the harbour, bobbing a row as it comes
    local bx=$(( (f * 2 / 5) % (W + 14) - 7 ))
    local by=$(( hz + 2 + (f / 9) % 2 ))
    for i in 0 1 2; do
        r=$(( by + i ))
        (( r < 1 || r > H-1 )) && continue
        bgtable_sty 226 232 242 "$r"
        put "$r" "$bx" "$STY" "${BOAT[$i]}"
    done

    top=$(( hz / 2 - 4 ))
    (( top < 1 )) && top=1
    if (( H >= 20 && W >= 60 )); then
        draw_big "$top" BANNER_OK 255 250 230  40 50 90
        top=$(( top + 6 ))
    else
        top=1
        msg="✓  ALL GOOD"
        center ${#msg}
        bgtable_sty 255 250 230 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 1 ))
    fi
    msg="all clear, steady as she goes"
    center ${#msg}
    bgtable_sty 215 225 245 "$top"
    put "$top" "$COL" "$STY" "$msg"
}

# ------------------------------------------------------ happy scene: kites ----

# A blustery afternoon on a hill: kites riding the wind on their own phases,
# each on a string that runs all the way back down to whoever is flying it.
KITE=(" ▲ " "◀◆▶" " ▼ ")

scene_ok_kites() {
    local f=$1 r t i x y top msg hz n g kx ky ax s steps sx sy fr fg fb

    hz=$(( H * 72 / 100 ))
    (( hz < 6 )) && hz=6
    (( hz > H-3 )) && hz=$(( H-3 ))
    BG_KIND=4
    if [ "$BG_KEY" != "kite$H" ]; then
        bgtable_reset
        for (( r=1; r<=hz; r++ )); do
            t=$(( (r-1)*1000 / (hz>1 ? hz : 1) ))
            bgtable_row "$r" $(( 74 + 130*t/1000 )) $(( 138 + 90*t/1000 )) \
                             $(( 216 + 30*t/1000 ))
        done
        for (( r=hz+1; r<=H-1; r++ )); do
            t=$(( (r-hz)*1000 / (H-hz>0 ? H-hz : 1) ))
            bgtable_row "$r" $(( 96 - 34*t/1000 )) $(( 172 - 52*t/1000 )) \
                             $(( 82 - 28*t/1000 ))
        done
        BG_KEY="kite$H"
    fi
    bgtable_paint

    # fat fair-weather clouds scudding along
    for i in 0 1 2 3; do
        y=$(( 2 + (i * 5) % (hz - 3 > 1 ? hz - 3 : 1) ))
        x=$(( (f * (3 + i % 3) / 10 + i * 43) % (W + 34) - 17 ))
        bgtable_sty 252 253 255 "$y"
        put "$y" "$x" "$STY" "▄██████▄"
        (( y+1 <= hz )) && {
            bgtable_sty 240 246 252 $(( y + 1 ))
            put $(( y + 1 )) $(( x - 2 )) "$STY" "▗██████████▖"
        }
    done

    # the hill, with the grass combed over by the same wind
    tile_of "ψ ˌ ψ  ˌ ψ" $(( W + 12 ))
    for (( r=hz+1; r<=H-1; r++ )); do
        bgtable_sty $(( 70 + (r - hz) * 4 )) $(( 150 - (r - hz) * 6 )) 70 "$r"
        put "$r" 1 "$STY" "${TILE:$(( (f/4 + r * 3) % 10 )):W}"
    done

    # three kites, each with a flyer standing on the hill below it
    for i in 0 1 2; do
        ax=$(( W/6 + i * (W/3) )); (( ax > W-2 )) && ax=$(( W - 2 ))
        kx=$(( ax + 6 + (${SIN[$(( (f*2 + i*17) % 60 ))]} - 500) * (W/8) / 500 ))
        ky=$(( 2 + i + (${SIN[$(( (f*3 + i*23) % 60 ))]} - 500) * (hz/4) / 700
                     + hz / 5 ))
        (( ky < 1 )) && ky=1
        (( ky > hz - 5 )) && ky=$(( hz - 5 ))
        (( ky < 1 )) && ky=1
        case $i in
            0) fr=240; fg=80;  fb=90  ;;
            1) fr=250; fg=196; fb=70  ;;
            *) fr=130; fg=110; fb=235 ;;
        esac
        # the string, sagging a little as it runs down to the flyer's hands
        steps=$(( hz + 1 - ky - 3 )); (( steps < 1 )) && steps=1
        for (( s=1; s<=steps; s++ )); do
            sy=$(( ky + 3 + s ))
            (( sy < 1 || sy > H-1 )) && continue
            sx=$(( kx + (ax - kx) * s / steps ))
            bgtable_sty 236 240 248 "$sy"
            put "$sy" "$sx" "$STY" "·"
        done
        # the kite, and the ribbon tail snapping under it
        for n in 0 1 2; do
            r=$(( ky + n ))
            (( r < 1 || r > hz )) && continue
            if (( n == 1 )); then bgtable_sty "$fr" "$fg" "$fb" "$r"
            else bgtable_sty $(( fr*8/10 )) $(( fg*8/10 )) $(( fb*8/10 )) "$r"
            fi
            put "$r" $(( kx - 1 )) "$STY" "${KITE[$n]}"
        done
        for (( n=1; n<=4; n++ )); do
            r=$(( ky + 2 + n ))
            (( r < 1 || r > hz )) && continue
            bgtable_sty 255 236 200 "$r"
            put "$r" $(( kx + (${SIN[$(( (f*3 + i*11 + n*9) % 60 ))]} - 500) * n / 700 )) \
                "$STY" "◦"
        done
        # the flyer, arms up, leaning back against the pull
        r=$(( hz + 1 ))
        (( r <= H-1 )) && {
            bgtable_sty 250 240 230 "$r"
            put "$r" "$ax" "$STY" "○"
            (( r+1 <= H-1 )) && {
                bgtable_sty 60 70 110 $(( r + 1 ))
                put $(( r + 1 )) $(( ax - 1 )) "$STY" "╱▌╲"
            }
        }
    done

    # gulls inland for the weather, and grass seed blowing past
    for i in 0 1; do
        x=$(( (f * 4 / 10 + i * 27) % (W + 18) - 9 ))
        y=$(( 2 + i * 2 + hz / 8 ))
        (( y < 1 || y > hz )) && continue
        bgtable_sty 70 80 110 "$y"
        if (( (f/5 + i) % 2 )); then put "$y" "$x" "$STY" "╲╱"
        else                         put "$y" "$x" "$STY" "╱╲"; fi
    done
    for (( i=0; i<14; i++ )); do
        y=$(( hz - 2 + (i * 3) % 4 ))
        (( y < 1 || y > H-1 )) && continue
        x=$(( 1 + (i * 37 + i*i*5 + f * 3) % W ))
        bgtable_sty 240 240 210 "$y"
        put "$y" "$x" "$STY" "˙"
    done

    top=$(( hz / 3 - 2 ))
    (( top < 1 )) && top=1
    if (( H >= 20 && W >= 60 )); then
        draw_big "$top" BANNER_OK 255 255 255  60 110 170
        top=$(( top + 6 ))
    else
        top=1
        msg="✓  ALL GOOD"
        center ${#msg}
        bgtable_sty 255 255 255 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 1 ))
    fi
    msg="the wind is with us"
    center ${#msg}
    bgtable_sty 240 248 255 "$top"
    put "$top" "$COL" "$STY" "$msg"
}

# -------------------------------------------------- happy scene: carousel ----

# A carousel turning at a night fair: a scalloped canopy with the stripes
# walking round it, bulbs chasing the valance, horses swinging past on brass
# poles — the near side low and lit, the far side small, high and behind the
# mirrored drum — and warm light pooling on the ground with the crowd in it.
#
# The canopy's shape depends only on the window and the stripe phase, so all
# CAR_PHASES phases are rasterized on demand and replayed; the tents pitched
# beside the ride are fixed for a window size and cached the same way. Only the
# horses, the bulbs, the mirrors and the crowd are redrawn per frame.
# facing right: ears and head, then the neck, the body with its tail, the legs
CAR_NEAR=("        ▄▟▖" "    ▗▄▄███▛" "▚▄█████████" "  ▐▌   ▐▌  ")
CAR_FAR=("     ▄▟" "  ▄████" "▚██████" " ▌   ▌ ")
CAR_STRIPE=3                    # columns per stripe
CAR_PHASES=6                    # 2 * CAR_STRIPE, so the stripes loop seamlessly
CAR_CANOPY=(); CAR_CANOPY_KEY=""
CAR_FAIR=""; CAR_FAIR_KEY=""

# one canopy phase: four sloping rows of stripes, then the scalloped valance
build_carousel_canopy() { # idx apex cx unit
    local idx=$1 apex=$2 cx=$3 unit=$4
    local n r half c lo hi len start k stripe dim fr fg fb lobe save=$OUT
    local sh=$(( CAR_PHASES - idx ))    # so a rising phase walks the stripes right
    OUT=""
    for n in 0 1 2 3 4; do
        r=$(( apex + n ))
        (( r < 1 || r > H-1 )) && continue
        half=$(( (n + 1) * unit + 2 ))
        (( n == 4 )) && lobe="▙█▟" || lobe="███"
        # the stripe grid is offset by the phase, so the run boundaries walk
        # sideways and the whole canopy reads as turning
        start=$(( -half - (half + sh) % CAR_STRIPE ))
        for (( c=start; c<=half; c+=CAR_STRIPE )); do
            lo=$(( c < -half ? -half : c ))
            hi=$(( c + CAR_STRIPE - 1 )); (( hi > half )) && hi=$half
            len=$(( hi - lo + 1 ))
            (( len < 1 )) && continue
            k=$(( c + half + sh + 300 ))     # kept positive: bash truncates to 0
            stripe=$(( (k / CAR_STRIPE) % 2 ))
            dim=$(( 1000 - (c < 0 ? -c : c) * 420 / half ))
            (( dim < 300 )) && dim=300
            if (( stripe )); then fr=232; fg=72; fb=78
            else                  fr=248; fg=242; fb=232
            fi
            bgtable_sty $(( fr*dim/1000 )) $(( fg*dim/1000 )) $(( fb*dim/1000 )) "$r"
            put "$r" $(( cx + lo )) "$STY" "${lobe:$(( lo - c )):len}"
        done
    done
    CAR_CANOPY[$idx]=$OUT
    OUT=$save
}

# the tents pitched either side of the ride, with bunting strung between them
build_carousel_fair() { # cy cx
    local cy=$1 cx=$2 i n r c x y w half line save=$OUT
    OUT=""
    for i in 0 1; do
        x=$(( i == 0 ? W/9 : W - W/9 ))
        for n in 0 1 2 3 4; do
            r=$(( cy - 4 + n ))
            (( r < 1 || r > H-1 )) && continue
            half=$(( n + 1 ))
            line=""
            for (( c=-half; c<=half; c++ )); do
                (( (c + 60 + i) % 3 )) && line+="█" || line+="▓"
            done
            bgtable_sty $(( 122 - n*8 )) $(( 78 - n*6 )) $(( 100 - n*7 )) "$r"
            put "$r" $(( x - half )) "$STY" "$line"
        done
        r=$(( cy - 5 ))
        (( r >= 1 )) && {
            bgtable_sty 190 150 90 "$r"
            put "$r" "$x" "$STY" "╽"
        }
    done
    # bunting sagging between the two tent poles, behind the ride
    r=$(( cy - 5 ))
    if (( r >= 1 )); then
        for (( c=W/9; c<=W-W/9; c+=4 )); do
            y=$(( r + (c / 4) % 2 ))
            (( y < 1 || y > H-1 )) && continue
            case $(( (c / 4) % 3 )) in
                0) bgtable_sty 208 88 84 "$y" ;;
                1) bgtable_sty 226 186 96 "$y" ;;
                *) bgtable_sty 110 168 186 "$y" ;;
            esac
            put "$y" "$c" "$STY" "▾"
        done
    fi
    CAR_FAIR=$OUT
    OUT=$save
}

scene_ok_carousel() {
    local f=$1 r t i x y top msg cx cy apex unit half n g c ph depth bob idx
    local lum sway drum

    cy=$(( H * 68 / 100 ))
    (( cy < 10 )) && cy=10
    (( cy > H-4 )) && cy=$(( H-4 ))
    unit=$(( W / 14 )); (( unit < 2 )) && unit=2
    # the canopy and its valance need six rows over the far-side horses, which
    # ride at cy-6
    apex=$(( cy - 12 ))
    (( apex < 1 )) && apex=1
    drum=$(( apex + 6 ))
    cx=$(( W / 2 ))
    BG_KIND=4
    if [ "$BG_KEY" != "car$H" ]; then
        bgtable_reset
        for (( r=1; r<=H-1; r++ )); do
            t=$(( (r-1)*1000 / (H>1 ? H-1 : 1) ))
            bgtable_row "$r" $(( 18 + 46*t/1000 )) $(( 14 + 30*t/1000 )) \
                             $(( 40 + 34*t/1000 ))
        done
        BG_KEY="car$H"
        CAR_CANOPY_KEY=""; CAR_FAIR_KEY=""   # both sit on this backdrop
    fi
    bgtable_paint

    # the rest of the fair, lit up behind it
    [ "$CAR_FAIR_KEY" = "$H$W" ] ||
        { build_carousel_fair "$cy" "$cx"; CAR_FAIR_KEY="$H$W"; }
    OUT+=$CAR_FAIR
    for (( i=0; i<22; i++ )); do
        y=$(( 2 + (i * 3) % (apex > 2 ? apex : 2) ))
        x=$(( 1 + (i * 41 + i*i*7) % W ))
        if (( ${SIN[$(( (f*2 + i*13) % 60 ))]} > 200 )); then
            bgtable_sty $(( 220 + i % 35 )) $(( 170 + i % 60 )) 110 "$y"
            put "$y" "$x" "$STY" "·"
        fi
    done

    # the far side of the ride, behind the drum: small, dim, riding high
    for (( i=0; i<8; i++ )); do
        ph=$(( (f + i * 8) % 60 ))
        depth=${SIN[$(( (ph + 15) % 60 ))]}
        (( depth > 500 )) && continue
        x=$(( cx + (${SIN[$ph]} - 500) * (W/6) / 500 ))
        bob=$(( (${SIN[$(( (f*3 + i*15) % 60 ))]} - 500) / 400 ))
        y=$(( cy - 7 + bob ))
        for (( r=y+4; r<=cy-1; r++ )); do
            (( r < 1 || r > H-1 )) && continue
            bgtable_sty 120 104 62 "$r"
            put "$r" $(( x + 3 )) "$STY" "│"
        done
        for n in 0 1 2 3; do
            r=$(( y + n ))
            (( r < 1 || r > H-1 )) && continue
            case $n in
                0) bgtable_sty 152 132 120 "$r" ;;
                1) bgtable_sty 142 122 112 "$r" ;;
                2) bgtable_sty 130 112 104 "$r" ;;
                *) bgtable_sty 110 94 88 "$r" ;;
            esac
            put "$r" "$x" "$STY" "${CAR_FAR[$n]}"
        done
    done

    # the drum in the middle, with mirror panels catching the bulbs
    for (( r=drum; r<=cy-1; r++ )); do
        (( r < 1 )) && continue
        bgtable_sty 206 180 132 "$r"
        put "$r" $(( cx - 2 )) "$STY" "▐██▌"
        # mirror panels: a highlight sliding down the drum as it turns
        if (( (r + f/2) % 4 == 0 )); then
            lum=$(( 218 + ${SIN[$(( (f*3 + r*11) % 60 ))]} * 37 / 1000 ))
            bgtable_sty "$lum" $(( lum - 18 )) $(( lum - 64 )) "$r"
            put "$r" $(( cx - 1 )) "$STY" "▀▀"
        fi
    done

    # the canopy, over the top of the drum and the far-side horses
    idx=$(( (f / 2) % CAR_PHASES ))
    [ "$CAR_CANOPY_KEY" = "$H$W$apex" ] ||
        { CAR_CANOPY=(); CAR_CANOPY_KEY="$H$W$apex"; }
    [ -n "${CAR_CANOPY[$idx]:-}" ] || build_carousel_canopy "$idx" "$apex" "$cx" "$unit"
    OUT+=${CAR_CANOPY[$idx]}
    # the finial, and a pennant snapping in the breeze above it
    for n in 1 2; do
        r=$(( apex - n ))
        (( r < 1 )) && break
        bgtable_sty 226 196 120 "$r"
        put "$r" "$cx" "$STY" "│"
    done
    r=$(( apex - 2 ))
    if (( r >= 1 )); then
        bgtable_sty 232 84 88 "$r"
        (( (f/4) % 2 )) && put "$r" $(( cx + 1 )) "$STY" "◤" \
                        || put "$r" $(( cx + 1 )) "$STY" "◥"
    fi
    # bulbs chasing each other round under the valance
    r=$(( apex + 5 ))
    half=$(( 5 * unit + 2 ))
    if (( r >= 1 && r <= H-1 )); then
        for (( c=-half; c<=half; c+=3 )); do
            if (( ((c + half) / 3 + f / 2) % 3 == 0 )); then
                bgtable_sty 255 238 168 "$r"
                put "$r" $(( cx + c )) "$STY" "◉"
            else
                bgtable_sty 148 118 78 "$r"
                put "$r" $(( cx + c )) "$STY" "◦"
            fi
        done
    fi

    # the platform it all stands on
    for (( r=cy; r<=cy+1 && r<=H-1; r++ )); do
        half=$(( W/6 - (r - cy) * 2 ))
        (( half < 3 )) && half=3
        tile_of "█" $(( half * 2 + 2 ))
        bgtable_sty $(( 130 - (r - cy) * 20 )) $(( 96 - (r - cy) * 16 )) 70 "$r"
        put "$r" $(( cx - half )) "$STY" "${TILE:0:$(( half * 2 + 1 ))}"
    done

    # the near side, in front of everything: bigger, warmly lit, riding low
    for (( i=0; i<8; i++ )); do
        ph=$(( (f + i * 8) % 60 ))
        depth=${SIN[$(( (ph + 15) % 60 ))]}
        (( depth > 500 )) || continue
        x=$(( cx + (${SIN[$ph]} - 500) * (W/6) / 500 ))
        bob=$(( (${SIN[$(( (f*3 + i*15) % 60 ))]} - 500) / 340 ))
        y=$(( cy - 4 + bob ))
        # the brass pole it rides on, running the full height of the ride
        for (( r=apex+6; r<=cy-1; r++ )); do
            (( r < 1 || r > H-1 )) && continue
            bgtable_sty 224 186 104 "$r"
            put "$r" $(( x + 4 )) "$STY" "│"
        done
        for n in 0 1 2 3; do
            r=$(( y + n ))
            (( r < 1 || r > H-1 )) && continue
            case $n in
                0) bgtable_sty 250 240 222 "$r" ;;
                1) bgtable_sty 244 230 206 "$r" ;;
                2) bgtable_sty 234 216 186 "$r" ;;
                *) bgtable_sty 206 184 156 "$r" ;;
            esac
            put "$r" "$x" "$STY" "${CAR_NEAR[$n]}"
        done
        # saddle and bridle, so each horse has some colour of its own
        r=$(( y + 2 ))
        (( r >= 1 && r <= H-1 )) && {
            case $(( i % 3 )) in
                0) bgtable_sty 214 76 92 "$r" ;;
                1) bgtable_sty 110 160 210 "$r" ;;
                *) bgtable_sty 226 176 84 "$r" ;;
            esac
            put "$r" $(( x + 4 )) "$STY" "▬▬"
            bgtable_sty 220 60 76 $(( y + 1 ))
            put $(( y + 1 )) $(( x + 8 )) "$STY" "▪"
        }
    done

    # the light the ride throws down onto the fairground, brightest under it
    tile_of "  ░   ░ " $(( W + 12 ))
    for (( r=cy+2; r<=H-1; r++ )); do
        lum=$(( 96 - (r - cy) * 8 )); (( lum < 34 )) && lum=34
        bgtable_sty "$lum" $(( lum * 4 / 5 )) $(( lum / 2 )) "$r"
        put "$r" 1 "$STY" "${TILE:$(( (f/5 + r * 3) % 8 )):W}"
        half=$(( W/6 - (r - cy) * 4 ))
        if (( half > 2 )); then
            tile_of "▒░▒ ░" $(( half * 2 + 6 ))
            bgtable_sty $(( lum + 60 )) $(( lum + 34 )) $(( lum / 2 + 16 )) "$r"
            put "$r" $(( cx - half )) "$STY" \
                "${TILE:$(( (f/5 + r) % 5 )):$(( half * 2 + 1 ))}"
        fi
    done
    # the crowd watching from the front, shifting on their feet
    for (( i=0; i<7; i++ )); do
        (( H - 2 > cy + 1 )) || break
        x=$(( 2 + (i * 31 + i*i*13) % (W - 4) ))
        sway=$(( (${SIN[$(( (f + i*17) % 60 ))]} - 500) / 460 ))
        bgtable_sty 46 32 36 $(( H - 2 ))
        put $(( H - 2 )) $(( x + sway )) "$STY" "▄"
        bgtable_sty 36 25 30 $(( H - 1 ))
        put $(( H - 1 )) "$x" "$STY" "▐▌"
    done

    top=$(( apex / 2 - 3 ))
    (( top < 1 )) && top=1
    if (( H >= 22 && W >= 60 && apex > 8 )); then
        draw_big "$top" BANNER_OK 255 248 230  90 40 50
        top=$(( top + 6 ))
    else
        top=1
        msg="✓  ALL GOOD"
        center ${#msg}
        bgtable_sty 255 248 230 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 1 ))
    fi
    msg="round and round, all green"
    center ${#msg}
    bgtable_sty 250 210 170 "$top"
    put "$top" "$COL" "$STY" "$msg"
}

# ---------------------------------------------------- happy scene: village ----

# A snowed-in village after dark: lit windows under white roofs, smoke lifting
# off the chimneys, a pine line behind them and snow coming down in three layers
# at three speeds. The houses and the treeline are fixed for a window size, so
# they are rasterized once and replayed; the snow, the smoke and the windows are
# all that move.
VILLAGE=""; VILLAGE_KEY=""

build_village() { # ground
    local gr=$1 i x w top r c save=$OUT line lum
    OUT=""
    # the pines standing behind the roofs
    line=""
    for (( c=1; c<=W; c++ )); do
        if (( ${SIN[$(( (c * 230 / W) % 60 ))]} > 620 )); then line+="▲"
        else                                                   line+="▁"
        fi
    done
    (( gr-4 >= 1 )) && {
        bgtable_sty 30 56 48 $(( gr - 4 ))
        put $(( gr - 4 )) 1 "$STY" "$line"
    }
    w=$(( W / 10 )); (( w < 5 )) && w=5
    for i in 0 1 2 3; do
        x=$(( 3 + i * (W / 4) ))
        top=$(( gr - 3 - (i % 2) ))
        (( top < 2 )) && top=2
        tile_of "█" $(( w + 2 ))
        for (( r=top; r<=gr-1; r++ )); do
            (( r < 1 || r > H-1 )) && continue
            lum=$(( 74 - (r - top) * 4 )); (( lum < 30 )) && lum=30
            bgtable_sty "$lum" $(( lum - 20 )) $(( lum - 22 )) "$r"
            put "$r" "$x" "$STY" "${TILE:0:w}"
        done
        # snow settled on the roof, and the chimney at the near end of it
        (( top-1 >= 1 )) && {
            tile_of "▄" $(( w + 4 ))
            bgtable_sty 238 244 252 $(( top - 1 ))
            put $(( top - 1 )) $(( x - 1 )) "$STY" "${TILE:0:$(( w + 2 ))}"
        }
        (( top-2 >= 1 )) && {
            bgtable_sty 92 66 62 $(( top - 2 ))
            put $(( top - 2 )) $(( x + w - 2 )) "$STY" "▟▙"
        }
    done
    # the snow they are all standing in, drifted into low banks
    for (( r=gr; r<=H-1; r++ )); do
        lum=$(( 236 - (r - gr) * 6 )); (( lum < 150 )) && lum=150
        bgtable_sty "$lum" $(( lum + 6 > 255 ? 255 : lum + 6 )) 252 "$r"
        put "$r" 1 "$STY" "${SPACES// /█}"
        # only the first couple of rows get drift, so the field below stays flat
        # the way settled snow does
        (( r > gr + 1 )) && continue
        tile_of "▁▁   ▁▂▁    ▁▁▂  ▁  " $(( W + 24 ))
        bgtable_sty $(( lum - 26 )) $(( lum - 18 )) 246 "$r"
        put "$r" 1 "$STY" "${TILE:$(( (r * 7) % 20 )):W}"
    done
    VILLAGE=$OUT
    OUT=$save
}

scene_ok_village() {
    local f=$1 r t i x y top msg gr lum w n g
    gr=$(( H * 78 / 100 ))
    (( gr < 6 )) && gr=6
    (( gr > H-2 )) && gr=$(( H-2 ))
    BG_KIND=4
    if [ "$BG_KEY" != "vlg$H" ]; then
        bgtable_reset
        for (( r=1; r<=gr-1; r++ )); do
            t=$(( (r-1)*1000 / (gr>1 ? gr-1 : 1) ))
            bgtable_row "$r" $(( 14 + 40*t/1000 )) $(( 20 + 44*t/1000 )) \
                             $(( 44 + 56*t/1000 ))
        done
        for (( r=gr; r<=H-1; r++ )); do
            t=$(( (r-gr)*1000 / (H-gr>0 ? H-gr : 1) ))
            bgtable_row "$r" $(( 196 - 30*t/1000 )) $(( 206 - 30*t/1000 )) \
                             $(( 224 - 24*t/1000 ))
        done
        BG_KEY="vlg$H"
        VILLAGE_KEY=""              # the houses sit on this backdrop
    fi
    bgtable_paint

    # what stars get through the snow, up above the roofs
    for (( i=0; i<26; i++ )); do
        y=$(( 1 + (i * 3) % (gr / 2 > 1 ? gr / 2 : 1) ))
        x=$(( 1 + (i * 43 + i*i*7) % W ))
        lum=$(( 150 + ${SIN[$(( (f + i*19) % 60 ))]} * 90 / 1000 ))
        bgtable_sty "$lum" "$lum" 255 "$y"
        put "$y" "$x" "$STY" "·"
    done

    [ "$VILLAGE_KEY" = "$H$W" ] || { build_village "$gr"; VILLAGE_KEY="$H$W"; }
    OUT+=$VILLAGE

    # lit windows, one or two of them turning in for the night, and the smoke
    # off each chimney leaning with the breeze
    w=$(( W / 10 )); (( w < 5 )) && w=5
    for i in 0 1 2 3; do
        x=$(( 3 + i * (W / 4) ))
        top=$(( gr - 3 - (i % 2) ))
        (( top < 2 )) && top=2
        y=$(( top + 1 ))
        if (( y <= H-1 )); then
            if (( ${SIN[$(( (f + i*27) % 60 ))]} > 250 )); then
                bgtable_sty 255 214 130 "$y"
            else
                bgtable_sty 96 78 62 "$y"
            fi
            put "$y" $(( x + 1 )) "$STY" "▪ ▪"
        fi
        for (( n=0; n<5; n++ )); do
            r=$(( top - 3 - n ))
            (( r < 1 )) && break
            g=$(( 200 - n * 22 ))
            bgtable_sty "$g" "$g" $(( g + 10 > 255 ? 255 : g + 10 )) "$r"
            put "$r" $(( x + w - 2 + n
                         + (${SIN[$(( (f*2 + i*13 + n*7) % 60 ))]} - 500) / 400 )) \
                "$STY" "░"
        done
    done

    # snow in three layers: the near flakes are bigger and fall faster
    for (( i=0; i<70; i++ )); do
        n=$(( i % 3 ))
        y=$(( 1 + (f * (2 + n) / 4 + i * 5 + i/3) % (H - 1) ))
        x=$(( 1 + (i * 31 + i*i*11 + f / 2) % W
                + (${SIN[$(( (f*2 + i*9) % 60 ))]} - 500) / 250 ))
        (( x < 1 || x > W )) && continue
        bgtable_sty $(( 210 + n*15 )) $(( 224 + n*10 )) 255 "$y"
        case $n in
            0) put "$y" "$x" "$STY" "·" ;;
            1) put "$y" "$x" "$STY" "✳" ;;
            *) put "$y" "$x" "$STY" "✦" ;;
        esac
    done

    top=$(( gr / 2 - 4 ))
    (( top < 1 )) && top=1
    if (( H >= 20 && W >= 60 )); then
        draw_big "$top" BANNER_OK 250 252 255  40 50 90
        top=$(( top + 6 ))
    else
        top=1
        msg="✓  ALL GOOD"
        center ${#msg}
        bgtable_sty 250 252 255 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 1 ))
    fi
    msg="all quiet, everyone warm inside"
    center ${#msg}
    bgtable_sty 200 214 240 "$top"
    put "$top" "$COL" "$STY" "$msg"
}

# ----------------------------------------------------- happy scene: desert ----

# A meteor shower over high desert: the milky way leaning across the sky, four
# meteors on staggered cycles, saguaro silhouettes on the dune line and a
# campfire down on the pan throwing a little light around itself.
scene_ok_desert() {
    local f=$1 r t i x y top msg hz lum n k ph sx sy g off fx fy
    hz=$(( H * 70 / 100 ))
    (( hz < 5 )) && hz=5
    (( hz > H-3 )) && hz=$(( H-3 ))
    BG_KIND=4
    if [ "$BG_KEY" != "dsrt$H" ]; then
        bgtable_reset
        for (( r=1; r<=hz-1; r++ )); do
            t=$(( (r-1)*1000 / (hz>1 ? hz-1 : 1) ))
            bgtable_row "$r" $(( 8 + 22*t/1000 )) $(( 10 + 16*t/1000 )) \
                             $(( 28 + 26*t/1000 ))
        done
        for (( r=hz; r<=H-1; r++ )); do
            t=$(( (r-hz)*1000 / (H-hz>0 ? H-hz : 1) ))
            bgtable_row "$r" $(( 62 - 22*t/1000 )) $(( 46 - 18*t/1000 )) \
                             $(( 40 - 14*t/1000 ))
        done
        BG_KEY="dsrt$H"
    fi
    bgtable_paint

    # the milky way: a band of haze leaning across the sky, thinning at its
    # edges — one tile per row, offset so the grain never lines up vertically
    tile_of "░  ▒ ░   ░ ▒  ░   " $(( W + 20 ))
    for (( r=1; r<=hz-1; r++ )); do
        off=$(( (r * 11 + r * r) % 18 ))
        lum=$(( 96 + (r % 4) * 10 ))
        bgtable_sty "$lum" "$lum" $(( lum + 60 )) "$r"
        put "$r" $(( W / 8 + r * 3 - hz )) "$STY" "${TILE:off:$(( W / 4 + 4 ))}"
    done

    # the fixed stars behind it all
    for (( i=0; i<56; i++ )); do
        y=$(( 1 + (i * 5 + i/6) % (hz > 1 ? hz : 1) ))
        x=$(( 1 + (i * 37 + i*i*13) % W ))
        lum=$(( 130 + ${SIN[$(( (f*2 + i*17) % 60 ))]} * 125 / 1000 ))
        bgtable_sty "$lum" "$lum" $(( lum > 235 ? 255 : lum + 20 )) "$y"
        put "$y" "$x" "$STY" "${STAR_GLYPH[$(( i % 5 ))]}"
    done

    # meteors: each streak lives 20 frames of a 70-frame cycle, so several are
    # usually in flight and none of them line up
    for k in 0 1 2 3; do
        ph=$(( (f * 2 + k * 17) % 70 ))
        (( ph > 20 )) && continue
        sx=$(( 6 + (k * 29 + k*k*7) % (W - 12 > 1 ? W - 12 : 1) + ph * 3 ))
        sy=$(( 1 + (k * 3) % (hz / 2 > 1 ? hz / 2 : 1) + ph ))
        for (( n=0; n<6; n++ )); do
            r=$(( sy - n )); x=$(( sx - n * 2 ))
            (( r < 1 || r > hz || x < 1 || x > W )) && continue
            g=$(( 255 - n * 36 ))
            bgtable_sty "$g" "$g" $(( g > 200 ? 255 : g + 40 )) "$r"
            if (( n == 0 )); then put "$r" "$x" "$STY" "✦"
            else                  put "$r" "$x" "$STY" "╲"; fi
        done
    done

    # the dune line, then the pan in front of it: scrub and stones, sparser the
    # closer it gets, so the ground has some grain to it
    tile_of "▄▃▄▅▄▃▄▂" $(( W + 10 ))
    bgtable_sty 96 72 58 "$hz"
    put "$hz" 1 "$STY" "${TILE:0:W}"
    for (( r=hz+1; r<=H-1; r++ )); do
        lum=$(( 84 - (r - hz) * 5 )); (( lum < 30 )) && lum=30
        bgtable_sty "$lum" $(( lum - 16 )) $(( lum - 24 )) "$r"
        put "$r" 1 "$STY" "${SPACES// /█}"
    done
    # scrub and stones scattered over the pan, not combed into rows
    for (( i=0; i<24; i++ )); do
        y=$(( hz + 1 + (i * 3 + i/4) % (H - hz - 1 > 0 ? H - hz - 1 : 1) ))
        (( y > H-1 )) && continue
        x=$(( 1 + (i * 53 + i*i*17) % W ))
        lum=$(( 100 - (y - hz) * 5 ))
        bgtable_sty "$lum" $(( lum - 14 )) $(( lum - 22 )) "$y"
        case $(( i % 3 )) in
            0) put "$y" "$x" "$STY" "▪" ;;
            1) put "$y" "$x" "$STY" "ˌ" ;;
            *) put "$y" "$x" "$STY" "˙" ;;
        esac
    done

    # saguaro on the ridge, a couple of them with an arm out
    for i in 0 1 2 3; do
        x=$(( 4 + (i * 47 + i*i*11) % (W - 6 > 1 ? W - 6 : 1) ))
        n=$(( 3 + i % 3 ))
        for (( k=0; k<n; k++ )); do
            r=$(( hz - k ))
            (( r < 1 )) && break
            bgtable_sty 34 52 40 "$r"
            put "$r" "$x" "$STY" "█"
        done
        r=$(( hz - n + 2 ))
        (( r >= 1 && i % 2 == 0 )) && {
            bgtable_sty 34 52 40 "$r"
            put "$r" $(( x - 1 )) "$STY" "▟"
            put "$r" $(( x + 1 )) "$STY" "▙"
        }
    done

    # a campfire on the pan, flickering, with sparks going up off it
    fx=$(( W / 6 )); fy=$(( H - 2 ))
    if (( fy > hz && fy <= H-1 )); then
        g=${SIN[$(( (f*4) % 60 ))]}
        bgtable_sty $(( 110 + g / 14 )) 76 48 "$fy"
        put "$fy" $(( fx - 3 )) "$STY" "░"
        put "$fy" $(( fx + 4 )) "$STY" "░"
        bgtable_sty 255 $(( 140 + g / 10 )) 70 "$fy"
        put "$fy" $(( fx )) "$STY" "▄▲▄"
        (( fy-1 >= 1 )) && {
            bgtable_sty 255 $(( 198 + g / 20 )) 120 $(( fy - 1 ))
            put $(( fy - 1 )) $(( fx + 1 )) "$STY" "▲"
        }
        for (( i=0; i<8; i++ )); do
            y=$(( fy - 2 - (f / 3 + i * 3) % 4 ))
            (( y < 1 || y > H-1 )) && continue
            bgtable_sty 255 $(( 170 + i % 40 )) 90 "$y"
            put "$y" $(( fx + 1 + (i % 3) - 1 )) "$STY" "·"
        done
    fi

    top=$(( hz / 3 - 2 ))
    (( top < 1 )) && top=1
    if (( H >= 20 && W >= 60 )); then
        draw_big "$top" BANNER_OK 245 248 255  30 30 70
        top=$(( top + 6 ))
    else
        top=1
        msg="✓  ALL GOOD"
        center ${#msg}
        bgtable_sty 245 248 255 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 1 ))
    fi
    msg="clear all the way out"
    center ${#msg}
    bgtable_sty 180 190 230 "$top"
    put "$top" "$COL" "$STY" "$msg"
}

# ----------------------------------------------------- happy scene: window ----
#
# Indoors, looking out: rain running down the glass of a lit room's window, a
# stepped town skyline blurred into soft lights beyond it, distant lightning
# silhouetting the roofs, a mug steaming on the sill and a plant leaning into
# the frame. The frame, the sill, the skyline and everything standing on the
# sill are fixed for a window size and rasterized once; the rain, the lights,
# the flashes and the steam are all that move.
#
# The cache comes in two halves: WINDOW is everything seen *through* the glass,
# WINDOW_FG everything standing in front of it (frame, mullions, sill, boards,
# mug, plant). The rain is drawn between them, so drops stay out in the night
# instead of running down the woodwork and over the mug.
WINDOW=""; WINDOW_FG=""; WINDOW_KEY=""

# Anything drawn over the glass with a glyph that is not a solid block shows its
# background through, and bgtable_sty would hand it the room's warm brown. These
# hold the pane's own colour per row, filled while the frame is rasterized, so
# rain, town lights and reflections sit on night instead of on the wall.
PANE_R=(); PANE_G=(); PANE_B=()

# A lightning flash brightens the pane for a frame or two. Rather than rewrite
# the cached table (and have to put it back afterwards), the lift is a pair of
# globals the lookup adds in, for rows above the roofline only.
PANE_LIFT=0; PANE_LIFT_TO=0

pane_sty() { # fg r g b, row
    local br=${PANE_R[$4]:-20} bg=${PANE_G[$4]:-26} bb=${PANE_B[$4]:-46}
    if (( PANE_LIFT && $4 < PANE_LIFT_TO )); then
        br=$(( br + PANE_LIFT )); bg=$(( bg + PANE_LIFT )); bb=$(( bb + PANE_LIFT ))
    fi
    sty "$1" "$2" "$3" "$br" "$bg" "$bb"
}

build_window() { # py1 py2 px1 px2 sill skyline_row
    local py1=$1 py2=$2 px1=$3 px2=$4 sill=$5 sk=$6
    local r c wide save=$OUT lum g bt=() dep
    wide=$(( px2 - px1 + 1 ))
    OUT=""
    # the night outside: overcast slate up top, warming a touch at the roofline
    # from the town's own light, so the silhouette has something to stand against
    PANE_R=(); PANE_G=(); PANE_B=()
    tile_of "█" $(( wide + 2 ))
    for (( r=py1; r<=py2; r++ )); do
        g=$(( (r - py1) * 1000 / (sk - py1 > 0 ? sk - py1 : 1) ))
        (( g > 1000 )) && g=1000
        bgtable_sty $(( 34 + 34*g/1000 )) $(( 42 + 30*g/1000 )) \
                    $(( 62 + 20*g/1000 )) "$r"
        put "$r" "$px1" "$STY" "${TILE:0:wide}"
        if (( r < sk )); then
            PANE_R[$r]=$(( 34 + 34*g/1000 ))
            PANE_G[$r]=$(( 42 + 30*g/1000 ))
            PANE_B[$r]=$(( 62 + 20*g/1000 ))
        else
            # below the roofline the town fills most of the glass, so the colour
            # a raindrop sits on is the buildings, not the sky
            PANE_R[$r]=20; PANE_G[$r]=23; PANE_B[$r]=34
        fi
    done
    # the town: blocks five columns wide, each with its own roof height, a gap
    # column between them so the night shows through. Column-at-a-time because
    # the run of sky beside a roof must stay the pane's colour, not the room's.
    for (( c=0; c<wide; c++ )); do
        g=$(( c / 5 ))
        (( c % 5 == 4 )) && continue                  # the alley between blocks
        bt[$c]=$(( sk + (py2 - sk) * (1000 - ${SIN[$(( (g * 13) % 60 ))]}) / 2400 ))
    done
    for (( c=0; c<wide; c++ )); do
        [ -n "${bt[$c]:-}" ] || continue
        g=$(( (c / 5) % 3 ))
        dep=$(( 14 + g * 7 ))
        for (( r=${bt[$c]}; r<=py2; r++ )); do
            (( r < py1 || r > H-1 )) && continue
            bgtable_sty "$dep" $(( dep + 3 )) $(( dep + 14 )) "$r"
            put "$r" $(( px1 + c )) "$STY" "█"
        done
        # a lit window here and there, dim enough for the flicker pass to own
        if (( c % 5 == 1 && (c * 7 + sk) % 3 == 0 )); then
            r=$(( ${bt[$c]} + 1 + (c % 3) ))
            (( r >= py1 && r <= py2 )) && {
                pane_sty 132 106 62 "$r"
                put "$r" $(( px1 + c )) "$STY" "▪"
            }
        fi
    done
    # the lamp behind us, reflected in the glass as a soft slanted smear
    for (( r=py1; r<=py2; r++ )); do
        lum=$(( 54 - (r - py1) * 5 )); (( lum < 14 )) && lum=14
        pane_sty $(( 96 + lum )) $(( 84 + lum )) $(( 62 + lum )) "$r"
        put "$r" $(( px1 + 2 + (r - py1) / 2 )) "$STY" "░"
    done
    # condensation hazing the corners of the pane, where the glass is coldest
    for (( r=py1; r<=py1+2 && r<=py2; r++ )); do
        pane_sty $(( 150 - (r - py1) * 20 )) $(( 168 - (r - py1) * 20 )) \
                 $(( 190 - (r - py1) * 18 )) "$r"
        tile_of "░▒░ " $(( wide + 4 ))
        put "$r" "$px1" "$STY" "${TILE:0:$(( 4 - (r - py1) ))}"
        put "$r" $(( px2 - 3 + (r - py1) )) "$STY" "${TILE:0:$(( 4 - (r - py1) ))}"
    done
    WINDOW=$OUT
    # ---- foreground: everything indoors, drawn after the rain ----
    OUT=""
    # the frame, and the two mullions crossing the pane
    tile_of "█" $(( wide + 6 ))
    for r in $(( py1 - 1 )) $(( py2 + 1 )); do
        (( r < 1 || r > H-1 )) && continue
        bgtable_sty 128 88 62 "$r"
        put "$r" $(( px1 - 2 )) "$STY" "${TILE:0:$(( wide + 4 ))}"
    done
    for (( r=py1; r<=py2; r++ )); do
        bgtable_sty 128 88 62 "$r"
        put "$r" $(( px1 - 2 )) "$STY" "██"
        put "$r" $(( px2 + 1 )) "$STY" "██"
        bgtable_sty 112 78 54 "$r"
        put "$r" $(( (px1 + px2) / 2 )) "$STY" "▐▌"
    done
    r=$(( (py1 + py2) / 2 ))
    if (( r >= 1 && r <= H-1 )); then
        tile_of "▬" $(( wide + 2 ))
        bgtable_sty 112 78 54 "$r"
        put "$r" "$px1" "$STY" "${TILE:0:wide}"
    fi
    # the sill, then the boards of the room below it
    if (( sill >= 1 && sill <= H-1 )); then
        tile_of "▀" $(( W + 4 ))
        bgtable_sty 152 108 74 "$sill"
        put "$sill" 1 "$STY" "${TILE:0:W}"
    fi
    for (( r=sill+1; r<=H-1; r++ )); do
        lum=$(( 96 - (r - sill) * 8 )); (( lum < 40 )) && lum=40
        bgtable_sty "$lum" $(( lum * 2 / 3 )) $(( lum / 2 )) "$r"
        put "$r" 1 "$STY" "${SPACES// /█}"
        # the seams between the boards, staggered course to course
        tile_of "██████████▏" $(( W + 14 ))
        bgtable_sty $(( lum - 18 )) $(( lum / 2 )) $(( lum / 3 )) "$r"
        put "$r" 1 "$STY" "${TILE:$(( (r * 4) % 11 )):W}"
    done
    # the mug, two rows tall with a handle, and the plant beside the far jamb
    r=$(( sill - 1 ))
    if (( r >= 1 && r <= H-1 )); then
        bgtable_sty 238 232 222 "$r"
        put "$r" $(( px1 + 2 )) "$STY" "▙▄▟"
        (( r-1 >= 1 )) && {
            bgtable_sty 246 242 236 $(( r - 1 ))
            put $(( r - 1 )) $(( px1 + 2 )) "$STY" "▛▀▜"
            bgtable_sty 214 206 196 $(( r - 1 ))
            put $(( r - 1 )) $(( px1 + 5 )) "$STY" "╮"
            bgtable_sty 214 206 196 "$r"
            put "$r" $(( px1 + 5 )) "$STY" "╯"
        }
        bgtable_sty 118 78 58 "$r"
        put "$r" $(( px2 - 5 )) "$STY" "▟█▙"
        (( r-1 >= 1 )) && {
            bgtable_sty 92 158 88 $(( r - 1 ))
            put $(( r - 1 )) $(( px2 - 6 )) "$STY" "ψ❦ψ"
        }
        (( r-2 >= 1 )) && {
            bgtable_sty 108 174 100 $(( r - 2 ))
            put $(( r - 2 )) $(( px2 - 5 )) "$STY" "❦"
        }
    fi
    WINDOW_FG=$OUT
    OUT=$save
}

scene_ok_window() {
    local f=$1 r t i x y top msg py1 py2 px1 px2 sill sk wide lum g n
    local cyc p flash slant
    py1=$(( 2 + H/12 )); (( py1 < 2 )) && py1=2
    sill=$(( H - 4 )); (( sill > H-2 )) && sill=$(( H - 2 ))
    (( sill < py1 + 3 )) && sill=$(( py1 + 3 ))
    (( sill > H-1 )) && sill=$(( H - 1 ))
    py2=$(( sill - 2 ))
    (( py2 < py1 )) && py2=$py1
    px1=$(( W/2 - W/4 )); (( px1 < 4 )) && px1=4
    px2=$(( W/2 + W/4 )); (( px2 > W-3 )) && px2=$(( W - 3 ))
    (( px2 < px1 + 6 )) && px2=$(( px1 + 6 ))
    (( px2 > W )) && px2=$W
    wide=$(( px2 - px1 + 1 ))
    sk=$(( py2 - (py2 - py1) / 3 ))
    (( sk < py1 + 1 )) && sk=$(( py1 + 1 ))
    (( sk > py2 )) && sk=$py2
    BG_KIND=4
    if [ "$BG_KEY" != "wnd$H" ]; then
        bgtable_reset
        for (( r=1; r<=H-1; r++ )); do
            t=$(( (r-1)*1000 / (H>1 ? H-1 : 1) ))
            bgtable_row "$r" $(( 84 + 34*t/1000 )) $(( 58 + 24*t/1000 )) \
                             $(( 44 + 18*t/1000 ))
        done
        BG_KEY="wnd$H"
        WINDOW_KEY=""               # the frame sits on this backdrop
    fi
    bgtable_paint

    # the lamp behind us, washing the wall to one side of the window
    tile_of "░" $(( W / 4 + 4 ))
    for (( r=1; r<=H-1; r++ )); do
        g=$(( 1000 - (r - 1) * 700 / (H > 2 ? H - 2 : 1) ))
        (( g < 120 )) && g=120
        bgtable_sty $(( 120 + 90*g/1000 )) $(( 92 + 66*g/1000 )) \
                    $(( 60 + 40*g/1000 )) "$r"
        put "$r" 1 "$STY" "${TILE:0:$(( r / 3 + 2 ))}"
    done

    [ "$WINDOW_KEY" = "$H$W" ] ||
        { build_window "$py1" "$py2" "$px1" "$px2" "$sill" "$sk"
          WINDOW_KEY="$H$W"; }
    OUT+=$WINDOW
    # from here on everything lands on the glass, so overlays resolve their
    # backdrop from the pane table (rows off the pane fall back to the room).
    # The frame and the things on the sill go on last, over the top of the rain.
    BG_KIND=5

    # a storm going by somewhere out there: two flashes, close together, every
    # ~18s. Only the sky above the roofline lights up, so the town stays a
    # silhouette the way it does through real weather. The flash paints the sky
    # itself and lifts the pane colour, so the rain over it lights up too.
    flash=0
    p=$(( (f + 41) % 250 ))
    (( p < 2 )) && flash=$(( 60 - p * 22 ))
    (( p > 3 && p < 6 )) && flash=26
    PANE_LIFT=$flash; PANE_LIFT_TO=$sk
    if (( flash )); then
        tile_of "█" $(( wide + 2 ))
        for (( r=py1; r<sk; r++ )); do
            lum=$(( flash * 2 - (sk - r) * 3 )); (( lum < 0 )) && lum=0
            pane_sty $(( ${PANE_R[$r]:-20} + lum )) $(( ${PANE_G[$r]:-26} + lum )) \
                     $(( ${PANE_B[$r]:-46} + lum + 10 )) "$r"
            put "$r" "$px1" "$STY" "${TILE:0:wide}"
        done
    fi

    # the town's windows, blurred into soft lights by the wet glass
    for (( i=0; i<20; i++ )); do
        y=$(( sk + (i * 3 + i/2) % (py2 - sk + 1) ))
        (( y < py1 || y > py2 )) && continue
        x=$(( px1 + (i * 7 + i*i*3) % wide ))
        (( ${SIN[$(( (f + i*21) % 60 ))]} > 260 )) || continue
        if (( i % 3 )); then pane_sty 226 $(( 180 + i % 40 )) 110 "$y"
        else                 pane_sty 130 170 220 "$y"
        fi
        put "$y" "$x" "$STY" "░"
    done

    # rain falling out there, leaning with the gusts. It sits behind the beads
    # on the glass, and it is dim, so the pane reads as two layers deep.
    slant=$(( ${SIN[$(( (f / 3) % 60 ))]} > 500 ? 1 : 0 ))
    for (( i=0; i<26; i++ )); do
        y=$(( py1 + (f * 3 + i * 7 + i/2) % (py2 - py1 + 1) ))
        x=$(( px1 + (i * 13 + i*i*5 + f / 2) % wide ))
        pane_sty $(( 82 + i % 20 )) $(( 104 + i % 20 )) 148 "$y"
        (( slant )) && put "$y" "$x" "$STY" "╱" || put "$y" "$x" "$STY" "╲"
    done

    # rain on the pane: beads gathering, then running. A bead's progress is
    # squared over its cycle, so it creeps at the top of the glass and picks up
    # speed on the way down, dragging a longer tail as it goes.
    cyc=$(( py2 - py1 + 7 ))
    for (( i=0; i<30; i++ )); do
        p=$(( (f * (2 + i % 3) / 3 + i * 11 + i*i) % cyc ))
        y=$(( py1 + p * p / cyc ))
        (( y > py2 )) && continue
        x=$(( px1 + (i * 11 + i*i*7) % wide ))
        lum=$(( 170 + ${SIN[$(( (f + i*13) % 60 ))]} * 60 / 1000 ))
        pane_sty "$lum" $(( lum + 30 > 255 ? 255 : lum + 30 )) 255 "$y"
        if (( i % 4 )); then put "$y" "$x" "$STY" "·"
        else                 put "$y" "$x" "$STY" "╷"; fi
        # the streak it left, as long as it is travelling fast
        for (( n=1; n<=p*3/cyc; n++ )); do
            r=$(( y - n ))
            (( r < py1 )) && break
            pane_sty $(( lum - 40 - n*24 )) $(( lum - 20 - n*20 )) \
                     $(( 240 - n*20 )) "$r"
            put "$r" "$x" "$STY" "╵"
        done
    done
    # two fat drops chasing all the way down, wobbling around the ones ahead
    for i in 0 1; do
        y=$(( py1 + (f / 2 + i * 9) % (py2 - py1 + 1) ))
        x=$(( px1 + 3 + (i * 13) % (wide > 4 ? wide - 4 : 1) ))
        for (( n=0; n<5; n++ )); do
            r=$(( y - n ))
            (( r < py1 || r > py2 )) && continue
            pane_sty $(( 226 - n * 28 )) $(( 240 - n * 24 )) 255 "$r"
            if (( n == 0 )); then put "$r" "$x" "$STY" "●"
            else put "$r" $(( x + (${SIN[$(( (i*20 + n*9) % 60 ))]} - 500) / 460 )) \
                     "$STY" "│"
            fi
        done
    done

    # the room comes back over the top: frame, mullions, sill, boards, and the
    # mug and plant standing on it, so nothing outside runs across them
    OUT+=$WINDOW_FG

    # steam off the mug, curling as it goes up and thinning out
    for (( n=0; n<5; n++ )); do
        r=$(( sill - 3 - n ))
        (( r < 1 || r > H-1 )) && break
        g=$(( 214 - n * 24 ))
        bgtable_sty "$g" "$g" $(( g - 24 )) "$r"
        x=$(( px1 + 3 + (${SIN[$(( (f*2 + n*13) % 60 ))]} - 500) / 330 ))
        case $(( (f/3 + n) % 3 )) in
            0) put "$r" "$x" "$STY" "˙" ;;
            1) put "$r" "$x" "$STY" "·" ;;
            *) put "$r" "$x" "$STY" "‧" ;;
        esac
    done

    # the banner reads as light thrown on the glass, so it sits over the pane
    top=$(( (py1 + py2) / 2 - 4 ))
    (( top < py1 )) && top=$py1
    if (( H >= 20 && W >= 60 && py2 - py1 >= 7 )); then
        draw_big "$top" BANNER_OK 255 246 226  70 44 30
        top=$(( top + 6 ))
    else
        top=1
        msg="✓  ALL GOOD"
        center ${#msg}
        bgtable_sty 255 246 226 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 1 ))
    fi
    msg="nothing to fix, put the kettle on"
    center ${#msg}
    bgtable_sty 240 210 170 "$top"
    put "$top" "$COL" "$STY" "$msg"
}

# -------------------------------------------------------------- fail scene ---

# The count line, the rule under it and the failing items are the same in every
# fail variant; only the backdrop and banner differ. Reads the caller's BG_KIND,
# so it picks up whichever backdrop the variant installed.
fail_details() { # top_row
    local top=$1 head bar i n=0 line row max
    if (( TEST_FAILS > 0 )); then
        head="$ERRORS error(s) · $TEST_FAILS test failure(s)"
    else
        head="$ERRORS error(s)"
    fi
    center ${#head}
    sty_row 255 190 190 "$top"
    put "$top" "$COL" "$STY" "$head"
    bar=$(( W * 2 / 3 ))
    center "$bar"
    sty_row 150 40 40 $(( top + 1 ))
    put $(( top + 1 )) "$COL" "$STY" "${DASHES:0:bar}"
    max=$(( H - top - 3 ))
    (( max > 12 )) && max=12
    for (( i=0; i<${#ITEMS[@]} && n<max; i++ )); do
        line=${ITEMS[$i]}
        (( ${#line} > W-8 )) && line="${line:0:W-11}..."
        row=$(( top + 2 + n ))
        case "$line" in
            --\>*) sty_row 235 170 170 "$row"; put "$row" 5 "$STY" "  $line" ;;
            *)     sty_row 255 235 235 "$row"; put "$row" 5 $'\033[1m'"$STY" "$line" ;;
        esac
        n=$((n+1))
    done
    (( ${#ITEMS[@]} > n )) && {
        row=$(( top + 2 + n ))
        sty_row 200 130 130 "$row"
        put "$row" 5 "$STY" "… $(( ${#ITEMS[@]} - n )) more (press l for full output)"
    }
    return 0
}

# The pulse only ever takes 60 discrete levels, so the whole backdrop for a
# level is built once and replayed from FAILBG afterwards.
scene_fail_pulse() {
    local f=$1 idx lvl
    idx=$(( (f * 5 / 2) % 60 ))          # red -> black -> red pulse
    lvl=${SIN[$idx]}
    BG_KIND=1; BG_LVL=$lvl
    if [ -z "${FAILBG[$idx]:-}" ]; then
        local s="" r
        for (( r=1; r<=H-1; r++ )); do
            bg_at "$r"
            s+=$'\033['"$r;1H"$'\033[39m\033[48;2;'"$BGR;$BGG;$BGB"m"$SPACES"
        done
        FAILBG[$idx]=$s
    fi
    OUT+=${FAILBG[$idx]}

    local top glow=$(( 190 + lvl/12 ))
    # leave room for the banner (6 rows) plus the item list below it
    if (( H >= 16 && W >= 70 )); then
        top=$(( H/2 - 7 ))
        (( top < 1 )) && top=1
        draw_big "$top" BANNER_FAIL 255 "$glow" "$glow"  70 0 0
        top=$(( top + 6 ))
    else
        top=2
        local msg="✗  BUILD FAILED"
        center ${#msg}
        sty_row 255 230 230 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 2 ))
    fi
    fail_details "$top"
}

# ------------------------------------------------- fail scene: thunderstorm --

# Slate-grey storm sky with slanted rain. Lightning strikes on a fixed cycle:
# two quick flashes that wash the whole backdrop pale, then darkness again.
scene_fail_storm() {
    local f=$1 r t i x y top msg flash=0 strike ch
    # 0..2 of the 46-frame cycle is the first flash, 4..5 the flicker back
    strike=$(( f % 46 ))
    (( strike < 3 || (strike >= 5 && strike < 7) )) && flash=1

    BG_KIND=4
    local key="storm$H$flash"
    if [ "$BG_KEY" != "$key" ]; then
        bgtable_reset
        for (( r=1; r<=H-1; r++ )); do
            t=$(( (r-1)*1000 / (H>1 ? H-1 : 1) ))
            if (( flash )); then
                bgtable_row "$r" $(( 120 + 40*t/1000 )) $(( 116 + 34*t/1000 )) \
                                 $(( 130 + 30*t/1000 ))
            else
                bgtable_row "$r" $(( 34 + 22*t/1000 )) $(( 34 + 20*t/1000 )) \
                                 $(( 44 + 22*t/1000 ))
            fi
        done
        BG_KEY=$key
    fi
    bgtable_paint

    # rain: each drop is a fixed lattice point scrolled down and left over time,
    # so the sheet moves as one instead of shimmering per drop
    local dr dg db
    for (( i=0; i<130; i++ )); do
        y=$(( 1 + (i * 3 + f + i/7) % (H - 1) ))
        x=$(( 1 + (i * 17 + i*i*3 + W - (f * 2 + y) % W) % W ))
        if (( flash )); then dr=210; dg=214; db=226
        else                 dr=110; dg=124; db=160
        fi
        bgtable_sty "$dr" "$dg" "$db" "$y"
        (( i % 4 )) && ch="╱" || ch="│"
        put "$y" "$x" "$STY" "$ch"
    done

    # the bolt itself, only on the leading flash
    if (( strike < 3 )); then
        local bx=$(( W/3 + (f / 46) * 13 % (W/3) )) bolt=("▏" "╲" "▕" "╱")
        for (( i=0; i<H/2 && i<12; i++ )); do
            r=$(( 1 + i ))
            (( r > H-2 )) && break
            x=$(( bx + (i % 4 < 2 ? i : -i) / 2 ))
            bgtable_sty 255 255 235 "$r"
            put "$r" "$x" "$STY" "${bolt[$(( i % 4 ))]}"
        done
    fi

    top=$(( H/2 - 7 ))
    (( top < 1 )) && top=1
    if (( H >= 16 && W >= 70 )); then
        draw_big "$top" BANNER_FAIL 255 236 236  30 30 44
        top=$(( top + 6 ))
    else
        msg="✗  BUILD FAILED"
        center ${#msg}
        top=2
        sty_row 255 236 236 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 2 ))
    fi
    fail_details "$top"
}

# ------------------------------------------------- fail scene: signal glitch --

# A broken-transmission look: dark red base, horizontal tear bands that jump
# every few frames, scanlines drifting up, and the banner torn sideways.
GLITCH_JUNK='▓▒░█▚▞╳┼╱╲▘▝▖▗'

scene_fail_glitch() {
    local f=$1 r i x y top msg tear band
    # the tear pattern only changes every 3rd frame, so the cache still pays off
    band=$(( (f / 3) % 8 ))

    BG_KIND=4
    local key="glitch$H$band"
    if [ "$BG_KEY" != "$key" ]; then
        bgtable_reset
        for (( r=1; r<=H-1; r++ )); do
            # scanline darkening plus a bright torn band at one moving row
            if (( (r + band) % 9 == 0 )); then
                bgtable_row "$r" 92 14 20
            elif (( (r + band) % 2 == 0 )); then
                bgtable_row "$r" 26 6 10
            else
                bgtable_row "$r" 44 8 14
            fi
        done
        BG_KEY=$key
    fi
    bgtable_paint

    # torn rows of junk glyphs, offset per row so the picture looks displaced
    for (( i=0; i<9; i++ )); do
        y=$(( 1 + (i * 7 + band * 3) % (H - 1) ))
        tear=$(( (i * 13 + f) % W ))
        local jw=$(( 8 + (i * 5) % 22 )) s="" j
        for (( j=0; j<jw; j++ )); do
            x=$(( (i*3 + j*5 + f) % 14 ))
            s+=${GLITCH_JUNK:x:1}
        done
        bgtable_sty $(( 200 + i*5 > 255 ? 255 : 200 + i*5 )) 60 70 "$y"
        put "$y" $(( tear + 1 )) "$STY" "$s"
    done

    # chromatic-split bars at the edges
    for (( i=0; i<4; i++ )); do
        y=$(( 2 + (i * 11 + band * 2) % (H - 3) ))
        bgtable_sty 90 200 220 "$y"
        put "$y" 1 "$STY" "${DASHES:0:$(( 3 + i * 2 ))}"
        bgtable_sty 235 90 120 "$y"
        put "$y" $(( W - 4 - i )) "$STY" "${DASHES:0:4}"
    done

    top=$(( H/2 - 7 ))
    (( top < 1 )) && top=1
    if (( H >= 16 && W >= 70 )); then
        # draw the banner twice, offset, for a chromatic-aberration ghost
        local shift=$(( (f / 3) % 3 - 1 ))
        local rows w
        eval 'rows=("${BANNER_FAIL[@]}"); w=$BANNER_FAIL_W'
        center "$w"
        for (( i=0; i<5; i++ )); do
            r=$(( top + i ))
            (( r > H-2 )) && break
            bgtable_sty 60 180 200 "$r"
            put "$r" $(( COL + shift * 2 )) "$STY" "${rows[$i]}"
            bgtable_sty 255 220 220 "$r"
            put "$r" "$COL" "$STY" "${rows[$i]}"
        done
        top=$(( top + 6 ))
    else
        msg="✗  BUILD FAILED"
        center ${#msg}
        top=2
        sty_row 255 220 220 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 2 ))
    fi
    fail_details "$top"
}

# ------------------------------------------------------ fail scene: lava ----

# Cooling crust over molten rock: dark slate up top, rising heat haze, and a
# lava line at the bottom whose surface churns and throws embers.
scene_fail_lava() {
    local f=$1 r t i x y top msg lv hz g off

    lv=$(( H - H/4 ))
    (( lv < 3 )) && lv=3
    (( lv > H-2 )) && lv=$(( H-2 ))
    BG_KIND=4
    if [ "$BG_KEY" != "lava$H" ]; then
        bgtable_reset
        for (( r=1; r<=lv-1; r++ )); do
            t=$(( (r-1)*1000 / (lv>1 ? lv-1 : 1) ))
            bgtable_row "$r" $(( 20 + 66*t/1000 )) $(( 14 + 20*t/1000 )) \
                             $(( 18 + 16*t/1000 ))
        done
        for (( r=lv; r<=H-1; r++ )); do
            t=$(( (r-lv)*1000 / (H-lv>0 ? H-lv : 1) ))
            bgtable_row "$r" $(( 150 + 100*t/1000 )) $(( 30 + 90*t/1000 )) 12
        done
        BG_KEY="lava$H"
    fi
    bgtable_paint

    # churning crust line: one tile, sliced at a drifting offset
    tile_of "▓▒░▒▓█▒░" $(( W + 10 ))
    off=$(( (f / 2) % 8 ))
    bgtable_sty 255 190 90 "$lv"
    put "$lv" 1 "$STY" "${TILE:off:W}"
    (( lv-1 >= 1 )) && {
        tile_of "▁▂▁▃▁▂" $(( W + 8 ))
        bgtable_sty 255 140 50 $(( lv - 1 ))
        put $(( lv - 1 )) 1 "$STY" "${TILE:$(( (f/3) % 6 )):W}"
    }

    # embers rising off the surface, fading as they climb
    for (( i=0; i<26; i++ )); do
        y=$(( lv - 1 - (f / 3 + i * 5) % (lv > 2 ? lv - 2 : 1) ))
        (( y < 1 || y >= lv )) && continue
        x=$(( 1 + (i * 37 + i*i*11 + (f/6) * (1 + i%2)) % W ))
        g=$(( 60 + (y * 140 / (lv > 1 ? lv : 1)) ))
        bgtable_sty 255 "$g" 40 "$y"
        if (( i % 3 )); then put "$y" "$x" "$STY" "▪"
        else                 put "$y" "$x" "$STY" "˙"; fi
    done

    # cracks glowing in the crust above the lava
    for (( i=0; i<5; i++ )); do
        y=$(( 2 + (i * 9 + (f/12)) % (lv > 3 ? lv - 3 : 1) ))
        x=$(( 3 + (i * 47) % (W - 12) ))
        bgtable_sty 190 70 40 "$y"
        put "$y" "$x" "$STY" "╱╲╱╲"
    done

    top=$(( lv / 2 - 3 ))
    (( top < 1 )) && top=1
    if (( H >= 16 && W >= 70 )); then
        draw_big "$top" BANNER_FAIL 255 $(( 170 + ${SIN[$(( (f*2) % 60 ))]} / 14 )) 120  60 10 0
        top=$(( top + 6 ))
    else
        top=2
        msg="✗  BUILD FAILED"
        center ${#msg}
        sty_row 255 210 180 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 2 ))
    fi
    fail_details "$top"
}

# ------------------------------------------------ fail scene: matrix rain ---

# Falling columns of glyphs on black, each column on its own speed and phase,
# with a bright leading character and a dimming tail behind it.
MTX_CH='01ABCDEF#$%&*+=<>[]{}/\|!?~^'

scene_fail_matrix() {
    local f=$1 r i x y top msg col speed head n g ci
    BG_KIND=4
    if [ "$BG_KEY" != "mtx$H" ]; then
        bgtable_reset
        for (( r=1; r<=H-1; r++ )); do bgtable_row "$r" 6 10 8; done
        BG_KEY="mtx$H"
    fi
    bgtable_paint

    # every 3rd column, so wide terminals stay cheap
    for (( x=1; x<=W; x+=3 )); do
        col=$(( x / 3 ))
        speed=$(( 2 + col % 4 ))
        head=$(( (f * speed / 3 + col * 7) % (H + 10) ))
        for n in 0 1 2 3 4 5 6 7; do
            y=$(( head - n ))
            (( y < 1 || y > H-1 )) && continue
            ci=$(( (col * 13 + y * 7 + f / (2 + n)) % 27 ))
            if (( n == 0 )); then
                bgtable_sty 210 255 220 "$y"
            else
                g=$(( 235 - n * 27 ))
                bgtable_sty $(( g / 5 )) "$g" $(( g / 4 )) "$y"
            fi
            put "$y" "$x" "$STY" "${MTX_CH:ci:1}"
        done
    done

    top=$(( H/2 - 7 ))
    (( top < 1 )) && top=1
    if (( H >= 16 && W >= 70 )); then
        draw_big "$top" BANNER_FAIL 255 120 120  0 60 20
        top=$(( top + 6 ))
    else
        top=2
        msg="✗  BUILD FAILED"
        center ${#msg}
        sty_row 255 160 160 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 2 ))
    fi
    fail_details "$top"
}

# ----------------------------------------------- fail scene: alarm klaxon ---

# A dark hangar under two rotating warning beacons: the light cone sweeps left
# and right, hazard stripes march along the top and bottom, and the whole frame
# washes red on the beat.
scene_fail_alarm() {
    local f=$1 r i x y top msg beat lvl off cone base

    beat=$(( f % 24 ))
    lvl=$(( beat < 8 ? 1000 - beat * 125 : 0 ))    # bright flash, quick decay
    BG_KIND=4
    local key="alarm$H$(( lvl / 250 ))"
    if [ "$BG_KEY" != "$key" ]; then
        bgtable_reset
        local q=$(( lvl / 250 ))
        for (( r=1; r<=H-1; r++ )); do
            bgtable_row "$r" $(( 30 + 34 * q )) $(( 8 + 6 * q )) $(( 12 + 8 * q ))
        done
        BG_KEY=$key
    fi
    bgtable_paint

    # hazard stripes, marching in opposite directions top and bottom
    tile_of "╱╱╱   " $(( W + 8 ))
    off=$(( (f / 2) % 6 ))
    bgtable_sty 240 190 40 1
    put 1 1 "$STY" "${TILE:off:W}"
    (( H-2 >= 3 )) && {
        bgtable_sty 240 190 40 $(( H - 2 ))
        put $(( H - 2 )) 1 "$STY" "${TILE:$(( 6 - off )):W}"
    }

    # two beacons sweeping a widening cone down the screen
    base=$(( H / 2 ))
    for i in 0 1; do
        # sweep -1..1 scaled, mirrored for the second beacon
        local sw=$(( ${SIN[$(( (f * 2 + i * 30) % 60 ))]} - 500 ))
        local bx=$(( i == 0 ? W / 4 : W - W / 4 ))
        for (( r=2; r<=H-3; r++ )); do
            cone=$(( (r - 1) * 4 / 3 + 1 ))
            x=$(( bx + sw * (r - 1) / 220 ))
            local half=$(( cone / 2 ))
            (( half < 1 )) && half=1
            local lx=$(( x - half )) lw=$(( half * 2 + 1 ))
            (( lw > W )) && lw=$W
            local fade=$(( 1000 - (r - 2) * 700 / (H > 4 ? H - 4 : 1) ))
            (( fade < 120 )) && fade=120
            tile_of "░" $(( lw + 2 ))
            bgtable_sty $(( 120 + 135 * fade / 1000 )) $(( 40 * fade / 1000 )) \
                        $(( 30 * fade / 1000 )) "$r"
            put "$r" "$lx" "$STY" "${TILE:0:lw}"
        done
        # the lamp itself
        bgtable_sty 255 240 200 2
        put 2 "$bx" "$STY" "▀"
    done

    top=$(( H/2 - 7 ))
    (( top < 1 )) && top=1
    if (( H >= 16 && W >= 70 )); then
        draw_big "$top" BANNER_FAIL 255 $(( 200 + lvl / 20 )) $(( 200 + lvl / 20 ))  50 0 0
        top=$(( top + 6 ))
    else
        top=3
        msg="✗  BUILD FAILED"
        center ${#msg}
        sty_row 255 220 220 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 2 ))
    fi
    fail_details "$top"
}

# ---------------------------------------------- fail scene: crumbling wall ---

# A brick wall coming apart: courses of masonry with a jagged crack running
# down the middle, dust puffing out of it, and rubble bouncing at the base.
# Both the courses and the crack depend only on the window size, so they are
# rasterized into one string and replayed; only the dust and rubble move.
WALL=""; WALL_KEY=""

build_wall() {
    local r x cw course save=$OUT cx=$(( W / 2 ))
    OUT=""
    tile_of "██████▎" $(( W + 10 ))
    local brick=$TILE
    for (( r=1; r<=H-2; r++ )); do
        if (( r % 3 == 0 )); then
            bgtable_sty 40 20 18 "$r"
            put "$r" 1 "$STY" "${SPACES// /▁}"
        else
            course=$(( (r / 3) % 2 * 3 ))
            bgtable_sty 122 58 48 "$r"
            put "$r" 1 "$STY" "${brick:course:W}"
        fi
    done
    for (( r=1; r<=H-2; r++ )); do
        x=$(( cx + (${SIN[$(( (r * 7) % 60 ))]} - 500) * 6 / 500 + (r % 3) - 1 ))
        cw=$(( 3 - r * 2 / (H > 2 ? H : 1) ))
        (( cw < 1 )) && cw=1
        tile_of "▓" $(( cw + 1 ))
        bgtable_sty 18 10 10 "$r"
        put "$r" "$x" "$STY" "${TILE:0:cw}"
        bgtable_sty 168 92 76 "$r"
        put "$r" $(( x - 1 )) "$STY" "▏"
    done
    WALL=$OUT
    OUT=$save
}

scene_fail_wall() {
    local f=$1 r t i x y top msg cx g base

    base=$(( H - 2 )); cx=$(( W / 2 ))
    BG_KIND=4
    if [ "$BG_KEY" != "wall$H" ]; then
        bgtable_reset
        for (( r=1; r<=H-1; r++ )); do
            t=$(( (r-1)*1000 / (H>1 ? H-1 : 1) ))
            bgtable_row "$r" $(( 66 + 26*t/1000 )) $(( 32 + 12*t/1000 )) \
                             $(( 28 + 10*t/1000 ))
        done
        BG_KEY="wall$H"
        WALL_KEY=""                 # the courses sit on this backdrop
    fi
    bgtable_paint

    [ "$WALL_KEY" = "$H$W" ] || { build_wall; WALL_KEY="$H$W"; }
    OUT+=$WALL

    # dust puffing out of the seam, thinning as it drifts
    for (( i=0; i<22; i++ )); do
        y=$(( 2 + (i * 5 + f / 3) % (H - 3 > 1 ? H - 3 : 1) ))
        x=$(( cx - 6 + (i * 13 + f / 2) % 13 ))
        g=$(( 120 + (i % 4) * 22 ))
        bgtable_sty $(( g + 30 )) "$g" $(( g - 20 )) "$y"
        if (( i % 2 )); then put "$y" "$x" "$STY" "░"
        else                 put "$y" "$x" "$STY" "˙"; fi
    done

    # rubble bouncing along the foot of the wall
    if (( base > 3 )); then
        for (( i=0; i<12; i++ )); do
            x=$(( 2 + (i * 31 + i*i*7) % (W - 3) ))
            y=$(( base - (${SIN[$(( (f*3 + i*11) % 60 ))]} > 620 ? 1 : 0) ))
            bgtable_sty 150 82 66 "$y"
            put "$y" "$x" "$STY" "▖"
        done
    fi

    top=$(( H/2 - 7 ))
    (( top < 1 )) && top=1
    if (( H >= 16 && W >= 70 )); then
        draw_big "$top" BANNER_FAIL 255 226 214  40 14 12
        top=$(( top + 6 ))
    else
        top=2
        msg="✗  BUILD FAILED"
        center ${#msg}
        sty_row 255 226 214 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 2 ))
    fi
    fail_details "$top"
}

# ------------------------------------------------------ fail scene: vortex ---

# A collapsing spiral: arms of debris wound around a dark centre, rotating one
# step per frame, with the whole field dimming toward the eye of it.
VTX_CH=("▪" "•" "·" "▫" "◦")

scene_fail_vortex() {
    local f=$1 r t i x y top msg arm k cx cy rad ang g
    cx=$(( W / 2 )); cy=$(( H / 2 ))
    BG_KIND=4
    if [ "$BG_KEY" != "vtx$H" ]; then
        bgtable_reset
        for (( r=1; r<=H-1; r++ )); do
            # darkest at the middle rows, so the eye reads as a hole
            t=$(( r > cy ? (H-1-r) * 1000 / (H-cy>0 ? H-cy : 1)
                         : (r-1) * 1000 / (cy>1 ? cy-1 : 1) ))
            bgtable_row "$r" $(( 14 + 62*t/1000 )) $(( 8 + 14*t/1000 )) \
                             $(( 20 + 30*t/1000 ))
        done
        BG_KEY="vtx$H"
    fi
    bgtable_paint

    # Four arms, each a spiral: the radius grows one step per sample while the
    # angle winds on, so the arms sweep the whole field instead of running off
    # the edge. Radius is scaled to the window, so it fits at any size.
    local steps=30 rmax=$(( cy - 1 ))
    (( rmax < 2 )) && rmax=2
    for arm in 0 1 2 3 4 5; do
        # six arms at 10 sine-steps apart, so they interleave evenly
        for (( k=1; k<=steps; k++ )); do
            rad=$(( k * rmax / steps ))
            ang=$(( (arm * 10 + k * 3 + f) % 60 ))
            x=$(( cx + (${SIN[$(( (ang + 15) % 60 ))]} - 500) * rad * 2 / 500 ))
            y=$(( cy + (${SIN[$ang]} - 500) * rad / 500 ))
            (( y < 1 || y > H-1 || x < 1 || x > W )) && continue
            g=$(( 60 + k * 180 / steps ))
            bgtable_sty $(( g + 20 > 255 ? 255 : g + 20 )) $(( g / 3 )) $(( g / 4 )) "$y"
            put "$y" "$x" "$STY" "${VTX_CH[$(( (k + f/4) % 5 ))]}"
        done
    done

    # the eye: a small dark disc with a flickering rim
    for i in 0 1; do
        r=$(( cy - 1 + i * 2 ))
        (( r < 1 || r > H-1 )) && continue
        bgtable_sty $(( 150 + ${SIN[$(( (f*4 + i*20) % 60 ))]} / 10 )) 40 46 "$r"
        put "$r" $(( cx - 3 )) "$STY" "▁▁▁▁▁▁"
    done

    top=$(( H/2 - 7 ))
    (( top < 1 )) && top=1
    if (( H >= 16 && W >= 70 )); then
        draw_big "$top" BANNER_FAIL 255 200 205  50 6 14
        top=$(( top + 6 ))
    else
        top=2
        msg="✗  BUILD FAILED"
        center ${#msg}
        sty_row 255 210 215 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 2 ))
    fi
    fail_details "$top"
}

# ------------------------------------------------- fail scene: ember storm ---

# Everything already burned: a dark ash sky with wind-blown embers streaking
# sideways, a smouldering ridge, and smoke columns leaning with the gusts.
scene_fail_embers() {
    local f=$1 r t i x y top msg ridge gust g n off

    ridge=$(( H - 4 ))
    (( ridge < 4 )) && ridge=$(( H - 2 ))
    gust=$(( ${SIN[$(( (f / 2) % 60 ))]} - 500 ))     # -500..499, slow swell
    BG_KIND=4
    if [ "$BG_KEY" != "emb$H" ]; then
        bgtable_reset
        for (( r=1; r<=H-1; r++ )); do
            t=$(( (r-1)*1000 / (H>1 ? H-1 : 1) ))
            bgtable_row "$r" $(( 26 + 78*t/1000 )) $(( 20 + 30*t/1000 )) \
                             $(( 24 + 18*t/1000 ))
        done
        BG_KEY="emb$H"
    fi
    bgtable_paint

    # smoke leaning with the gust, drawn before the embers so sparks sit on top
    for (( i=0; i<6; i++ )); do
        x=$(( 4 + (i * 43 + i*i*9) % (W - 6) ))
        for (( n=1; n<=8; n++ )); do
            y=$(( ridge - n ))
            (( y < 1 )) && break
            g=$(( 60 + n * 9 ))
            bgtable_sty "$g" $(( g - 6 )) $(( g - 12 )) "$y"
            put "$y" $(( x + gust * n / 260 + (n % 2) )) "$STY" "▒"
        done
    done

    # embers: fast, near-horizontal streaks that wrap around the window
    for (( i=0; i<60; i++ )); do
        y=$(( 1 + (i * 3 + i/6 + f / 5) % (H - 1) ))
        x=$(( 1 + (i * 19 + i*i*5 + f * 3) % W ))
        g=$(( 90 + (i % 5) * 34 ))
        bgtable_sty 255 "$g" 40 "$y"
        case $(( i % 4 )) in
            0) put "$y" "$x" "$STY" "▬" ;;
            1) put "$y" "$x" "$STY" "▪" ;;
            2) put "$y" "$x" "$STY" "·" ;;
            *) put "$y" "$x" "$STY" "─" ;;
        esac
    done

    # the smouldering ridge, glowing brighter where the wind fans it
    if (( ridge >= 1 )); then
        tile_of "▄▀▄▄▀▄▅▄" $(( W + 10 ))
        off=$(( (f / 5) % 8 ))
        bgtable_sty 90 44 36 "$ridge"
        put "$ridge" 1 "$STY" "${TILE:off:W}"
        for (( r=ridge+1; r<=H-1; r++ )); do
            tile_of "█▓█▒█▓" $(( W + 8 ))
            bgtable_sty $(( 180 + (r - ridge) * 20 )) $(( 60 + ${SIN[$(( (f*2 + r*13) % 60 ))]} * 60 / 1000 )) 30 "$r"
            put "$r" 1 "$STY" "${TILE:$(( (f/4 + r) % 6 )):W}"
        done
    fi

    top=$(( ridge / 2 - 3 ))
    (( top < 1 )) && top=1
    if (( H >= 16 && W >= 70 )); then
        draw_big "$top" BANNER_FAIL 255 $(( 180 + ${SIN[$(( (f*3) % 60 ))]} / 16 )) 150  50 16 10
        top=$(( top + 6 ))
    else
        top=2
        msg="✗  BUILD FAILED"
        center ${#msg}
        sty_row 255 214 190 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 2 ))
    fi
    fail_details "$top"
}

# ---------------------------------------------------- fail scene: shattered ---

# Cracked glass: radial fractures from an impact point plus two concentric
# fracture rings, with shards glinting along the seams. The fracture pattern is
# fixed for a window size, so it is rasterized once; only the glints move.
SHARD=""; SHARD_KEY=""
SH_CH=("╱" "╲" "│" "─")

build_shards() {
    local sp k step ix iy x y rad ring c dx u rows save=$OUT rtop rbot
    ix=$(( W / 2 )); iy=$(( H / 2 - 1 ))
    (( iy < 2 )) && iy=2
    OUT=""
    # radial fractures: 11 spokes, each walked outward a step at a time
    for (( sp=0; sp<11; sp++ )); do
        for (( step=1; step<=40; step++ )); do
            x=$(( ix + (${SIN[$(( (sp * 5 + 15) % 60 ))]} - 500) * step * 2 / 500 ))
            y=$(( iy + (${SIN[$(( (sp * 5) % 60 ))]} - 500) * step / 500 ))
            (( y < 1 || y > H-2 || x < 1 || x > W )) && break
            bgtable_sty $(( 150 + step )) $(( 160 + step )) $(( 190 + step )) "$y"
            put "$y" "$x" "$STY" "${SH_CH[$(( sp % 4 ))]}"
        done
    done
    # two fracture rings around the impact
    for ring in 1 2; do
        rad=$(( ring * (W < H*2 ? W : H*2) / 7 ))
        (( rad < 3 )) && continue
        for (( c=1; c<=W; c++ )); do
            dx=$(( c - ix ))
            u=$(( dx * 1000 / rad ))
            (( u > 1000 || u < -1000 )) && continue
            isqrt $(( 1000000 - u * u ))
            rows=$(( rad * ISQ / 2000 ))
            # clamp before styling: the row doubles as a bgtable subscript
            rtop=$(( iy - rows )); rbot=$(( iy + rows ))
            if (( rtop >= 1 && rtop <= H-1 )); then
                bgtable_sty 176 186 210 "$rtop"
                put "$rtop" "$c" "$STY" "‾"
            fi
            if (( rbot >= 1 && rbot <= H-1 )); then
                bgtable_sty 176 186 210 "$rbot"
                put "$rbot" "$c" "$STY" "_"
            fi
        done
    done
    # the impact crater itself
    bgtable_sty 236 242 255 "$iy"
    put "$iy" $(( ix - 1 )) "$STY" "╳╳╳"
    SHARD=$OUT
    OUT=$save
}

scene_fail_shatter() {
    local f=$1 r t i x y top msg lum
    BG_KIND=4
    if [ "$BG_KEY" != "shat$H" ]; then
        bgtable_reset
        for (( r=1; r<=H-1; r++ )); do
            t=$(( (r-1)*1000 / (H>1 ? H-1 : 1) ))
            bgtable_row "$r" $(( 40 + 26*t/1000 )) $(( 16 + 10*t/1000 )) \
                             $(( 26 + 14*t/1000 ))
        done
        BG_KEY="shat$H"
        SHARD_KEY=""
    fi
    bgtable_paint

    [ "$SHARD_KEY" = "$H$W" ] || { build_shards; SHARD_KEY="$H$W"; }
    OUT+=$SHARD

    # glints travelling along the seams, so the glass catches the light
    for (( i=0; i<20; i++ )); do
        y=$(( 1 + (i * 7 + f / 2) % (H - 2) ))
        x=$(( 1 + (i * 29 + i*i*5 + f * 2) % W ))
        lum=$(( 200 + ${SIN[$(( (f*3 + i*11) % 60 ))]} * 55 / 1000 ))
        bgtable_sty "$lum" "$lum" 255 "$y"
        put "$y" "$x" "$STY" "✧"
    done

    # loose shards falling out of the pane
    for (( i=0; i<10; i++ )); do
        y=$(( 1 + (f / 2 + i * 9) % (H - 2) ))
        x=$(( 2 + (i * 53 + i*i*7) % (W - 2) ))
        bgtable_sty 200 210 235 "$y"
        put "$y" "$x" "$STY" "◣"
    done

    top=$(( H/2 - 7 ))
    (( top < 1 )) && top=1
    if (( H >= 16 && W >= 70 )); then
        draw_big "$top" BANNER_FAIL 255 232 236  30 12 20
        top=$(( top + 6 ))
    else
        top=2
        msg="✗  BUILD FAILED"
        center ${#msg}
        sty_row 255 232 236 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 2 ))
    fi
    fail_details "$top"
}

# --------------------------------------------------------- fail scene: swarm ---

# Bugs, literally: a swarm of them crawling over a dim board, each on its own
# looping path, legs twitching, with a few trails left behind.
BUG=("⚉" "⚇" "❋" "✳")

scene_fail_swarm() {
    local f=$1 r t i x y top msg leg ph n
    BG_KIND=4
    if [ "$BG_KEY" != "swarm$H" ]; then
        bgtable_reset
        for (( r=1; r<=H-1; r++ )); do
            t=$(( (r-1)*1000 / (H>1 ? H-1 : 1) ))
            bgtable_row "$r" $(( 22 + 30*t/1000 )) $(( 20 + 12*t/1000 )) \
                             $(( 14 + 8*t/1000 ))
        done
        BG_KEY="swarm$H"
    fi
    bgtable_paint

    # faint circuit traces on the board, so the bugs have something to crawl on
    tile_of "─┬──┴──┼─" $(( W + 12 ))
    for (( r=2; r<=H-2; r+=3 )); do
        bgtable_sty 52 44 30 "$r"
        put "$r" 1 "$STY" "${TILE:$(( (r * 4) % 9 )):W}"
    done

    # the swarm: each bug loops on a Lissajous path, so they never march in step
    for (( i=0; i<26; i++ )); do
        ph=$(( (f * (2 + i % 3) / 3 + i * 7) % 60 ))
        x=$(( W/2 + (${SIN[$ph]} - 500) * (W/2 - 3) / 520
                  + (i % 7) * 3 - 9 ))
        y=$(( H/2 + (${SIN[$(( (ph * 2 + i * 11) % 60 ))]} - 500) * (H/2 - 2) / 620
                  + (i % 5) - 2 ))
        (( y < 1 || y > H-1 )) && continue
        bgtable_sty $(( 210 + i % 45 )) $(( 60 + i % 30 )) 50 "$y"
        put "$y" "$x" "$STY" "${BUG[$(( (f/3 + i) % 4 ))]}"
        # legs, twitching on alternate frames
        leg=$(( (f / 2 + i) % 2 ))
        bgtable_sty 150 50 40 "$y"
        if (( leg )); then put "$y" $(( x - 1 )) "$STY" "╱"
                           put "$y" $(( x + 1 )) "$STY" "╲"
        else               put "$y" $(( x - 1 )) "$STY" "╲"
                           put "$y" $(( x + 1 )) "$STY" "╱"
        fi
    done

    # trails: a few faint marks where bugs have already been
    for (( i=0; i<14; i++ )); do
        n=$(( (f * 2 / 3 + i * 9) % 60 ))
        x=$(( W/2 + (${SIN[$n]} - 500) * (W/2 - 3) / 520 + (i % 7) * 3 - 9 ))
        y=$(( H/2 + (${SIN[$(( (n * 2 + i * 11) % 60 ))]} - 500) * (H/2 - 2) / 620 ))
        (( y < 1 || y > H-1 )) && continue
        bgtable_sty 96 52 40 "$y"
        put "$y" "$x" "$STY" "˙"
    done

    top=$(( H/2 - 7 ))
    (( top < 1 )) && top=1
    if (( H >= 16 && W >= 70 )); then
        draw_big "$top" BANNER_FAIL 255 214 200  40 16 10
        top=$(( top + 6 ))
    else
        top=2
        msg="✗  BUILD FAILED"
        center ${#msg}
        sty_row 255 214 200 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 2 ))
    fi
    fail_details "$top"
}

# ------------------------------------------------------ fail scene: meltdown ---

# A reactor panel past the redline: gauge bars climbing into the red and
# clipping at the top, a rising temperature readout, and warning lamps blinking
# out of phase behind the banner.
scene_fail_meltdown() {
    local f=$1 r t i x y top msg g lvl bar col n gh

    BG_KIND=4
    if [ "$BG_KEY" != "melt$H" ]; then
        bgtable_reset
        for (( r=1; r<=H-1; r++ )); do
            t=$(( (r-1)*1000 / (H>1 ? H-1 : 1) ))
            bgtable_row "$r" $(( 32 + 46*t/1000 )) $(( 18 + 10*t/1000 )) \
                             $(( 16 + 8*t/1000 ))
        done
        BG_KEY="melt$H"
    fi
    bgtable_paint

    # Gauge bars along the bottom, each climbing at its own rate and pinning at
    # max. Built row by row rather than cell by cell: the colour is a property
    # of the height (green below the redline, amber approaching, red over it),
    # so one write covers the whole row instead of one per bar.
    local gbase=$(( H - 2 )) gtop=$(( H/2 + 2 ))
    (( gtop < 2 )) && gtop=2
    if (( gbase > gtop )); then
        gh=$(( gbase - gtop ))
        local ng=$(( W / 4 )) redline=$(( gh * 2 / 3 )) line lv
        # each gauge's level for this frame, resolved once
        local levels=""
        for (( i=0; i<ng; i++ )); do
            lvl=$(( ${SIN[$(( (f * (2 + i % 3) + i * 13) % 60 ))]} * gh / 1100 + gh / 3 ))
            (( lvl > gh )) && lvl=$gh
            (( lvl < 1 )) && lvl=1
            levels+="$lvl "
        done
        for (( n=0; n<gh; n++ )); do
            y=$(( gbase - n ))
            (( y < gtop || y > H-1 )) && continue
            line=""; col=1
            set -- $levels
            for (( i=0; i<ng; i++ )); do
                lv=$1; shift
                # pad out to this gauge's column, then a block if it reaches here
                while (( col < 3 + i * 4 )); do line+=" "; col=$(( col + 1 )); done
                (( n < lv )) && line+="▊" || line+=" "
                col=$(( col + 1 ))
            done
            if (( n > redline )); then   bgtable_sty 240 60 50 "$y"
            elif (( n * 2 > gh )); then  bgtable_sty 240 170 50 "$y"
            else                         bgtable_sty 120 200 90 "$y"
            fi
            put "$y" 1 "$STY" "$line"
        done
        # the redline, drawn once across the whole panel
        y=$(( gbase - redline ))
        (( y >= gtop && y <= H-1 )) && {
            tile_of "╴╴╴ " $(( W + 4 ))
            bgtable_sty 255 90 90 "$y"
            put "$y" 1 "$STY" "${TILE:0:W}"
        }
    fi

    # warning lamps blinking out of phase along the top
    for (( i=0; i<6; i++ )); do
        x=$(( 4 + i * (W - 8) / 6 ))
        g=$(( ${SIN[$(( (f * 3 + i * 17) % 60 ))]} ))
        if (( g > 600 )); then bgtable_sty 255 220 90 2
        else                   bgtable_sty 110 70 30 2
        fi
        put 2 "$x" "$STY" "◉"
    done

    # the readout, climbing with the pulse. It goes on the very top row, above
    # the lamps: everything from the banner down belongs to fail_details and the
    # gauges, and anything placed there ends up sharing a row with the errors.
    msg="CORE $(( 900 + ${SIN[$(( (f*2) % 60 ))]} / 8 ))°  ▲ RISING"
    center ${#msg}
    y=1
    bgtable_sty 255 $(( 150 + ${SIN[$(( f % 60 ))]} / 12 )) 90 "$y"
    put "$y" "$COL" $'\033[1m'"$STY" "$msg"

    top=$(( H/2 - 8 ))
    (( top < 1 )) && top=1
    if (( H >= 18 && W >= 70 )); then
        draw_big "$top" BANNER_FAIL 255 $(( 190 + ${SIN[$(( (f*4) % 60 ))]} / 14 )) 170  50 10 6
        top=$(( top + 6 ))
    else
        top=3
        msg="✗  BUILD FAILED"
        center ${#msg}
        sty_row 255 210 190 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 2 ))
    fi
    fail_details "$top"
}

# ----------------------------------------------------- fail scene: quake ------

# The whole frame shaken off its axis: strata of rock split by a fault line that
# jolts left and right, dust shaking loose from the ceiling, and a seismograph
# trace scribbling along the top. The shake is a per-frame column offset applied
# to the strata, so the ground genuinely displaces instead of just flickering.
scene_fail_quake() {
    local f=$1 r t i x y top msg shake fx off g

    # a sharp jolt every ~20 frames, decaying over four frames
    local beat=$(( f % 20 ))
    shake=$(( beat < 4 ? (4 - beat) * (beat % 2 ? -1 : 1) : 0 ))
    BG_KIND=4
    if [ "$BG_KEY" != "quake$H" ]; then
        bgtable_reset
        for (( r=1; r<=H-1; r++ )); do
            t=$(( (r-1)*1000 / (H>1 ? H-1 : 1) ))
            bgtable_row "$r" $(( 44 + 44*t/1000 )) $(( 26 + 18*t/1000 )) \
                             $(( 22 + 12*t/1000 ))
        done
        BG_KEY="quake$H"
    fi
    bgtable_paint

    # strata: bands of rock, each sliced at an offset that jumps with the shake
    tile_of "▓▓▒▓░▒▓▓▒░" $(( W + 14 ))
    for (( r=H/2; r<=H-1; r++ )); do
        off=$(( ((r * 3) % 10 + shake + 10) % 10 ))
        bgtable_sty $(( 108 - (r - H/2) * 4 )) $(( 62 - (r - H/2) * 3 )) 48 "$r"
        put "$r" $(( 1 + shake )) "$STY" "${TILE:off:W}"
    done

    # the fault: a jagged split down the strata, thrown sideways as it goes
    fx=$(( W / 2 ))
    for (( r=H/2; r<=H-1; r++ )); do
        x=$(( fx + (${SIN[$(( (r * 11) % 60 ))]} - 500) * 5 / 500 + shake * 2 ))
        bgtable_sty 14 8 8 "$r"
        put "$r" "$x" "$STY" "▓▓"
        bgtable_sty 200 96 60 "$r"
        put "$r" $(( x - 1 )) "$STY" "▏"
    done

    # dust shaking loose from above, falling faster right after a jolt
    for (( i=0; i<30; i++ )); do
        y=$(( 2 + (f / 2 + i * 5) % (H/2 > 1 ? H/2 : 1) ))
        x=$(( 1 + (i * 31 + i*i*7) % W + shake ))
        g=$(( 130 + (i % 4) * 25 ))
        bgtable_sty $(( g + 20 )) "$g" $(( g - 25 )) "$y"
        if (( i % 3 )); then put "$y" "$x" "$STY" "˙"
        else                 put "$y" "$x" "$STY" "░"; fi
    done

    # seismograph trace across the very top row
    local trace="" c amp
    for (( c=1; c<=W; c++ )); do
        amp=$(( ${SIN[$(( (c * 7 + f * 3) % 60 ))]} + ${SIN[$(( (c * 23 + f) % 60 ))]} ))
        if (( amp > 1300 )); then trace+="╿"
        elif (( amp > 900 )); then trace+="┃"
        elif (( amp > 600 )); then trace+="╽"
        else trace+="─"
        fi
    done
    bgtable_sty 255 170 90 1
    put 1 1 "$STY" "$trace"

    top=$(( H/2 - 7 ))
    (( top < 1 )) && top=2
    if (( H >= 18 && W >= 70 )); then
        draw_big "$top" BANNER_FAIL 255 220 200  40 18 12
        top=$(( top + 6 ))
    else
        top=2
        msg="✗  BUILD FAILED"
        center ${#msg}
        sty_row 255 220 200 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 2 ))
    fi
    fail_details "$top"
}

# ------------------------------------------------------ fail scene: acid -----

# Something corrosive eating through the panel: sickly green wash, drips running
# down and pooling at the bottom, and holes bubbling open in the surface.
scene_fail_acid() {
    local f=$1 r t i x y top msg n g pool off lum

    pool=$(( H - 3 ))
    (( pool < 4 )) && pool=$(( H - 1 ))
    BG_KIND=4
    if [ "$BG_KEY" != "acid$H" ]; then
        bgtable_reset
        for (( r=1; r<=H-1; r++ )); do
            t=$(( (r-1)*1000 / (H>1 ? H-1 : 1) ))
            bgtable_row "$r" $(( 18 + 26*t/1000 )) $(( 34 + 56*t/1000 )) \
                             $(( 16 + 18*t/1000 ))
        done
        BG_KEY="acid$H"
    fi
    bgtable_paint

    # the panel surface: a faint grid being eaten away
    tile_of "┼───┼───" $(( W + 10 ))
    for (( r=2; r<=pool-1; r+=2 )); do
        bgtable_sty 46 74 40 "$r"
        put "$r" 1 "$STY" "${TILE:$(( (r * 4) % 8 )):W}"
    done

    # holes bubbling open, each breathing on its own phase
    for (( i=0; i<8; i++ )); do
        y=$(( 2 + (i * 5 + H/7) % (pool - 2 > 1 ? pool - 2 : 1) ))
        x=$(( 4 + (i * 47 + i*i*9) % (W - 8) ))
        n=$(( ${SIN[$(( (f*2 + i*15) % 60 ))]} / 300 ))       # 0..3 wide
        tile_of "●" $(( n + 2 ))
        bgtable_sty 190 255 120 "$y"
        put "$y" $(( x - n/2 )) "$STY" "${TILE:0:$(( n + 1 ))}"
        (( y+1 <= H-1 )) && {
            bgtable_sty 90 150 60 $(( y + 1 ))
            put $(( y + 1 )) "$x" "$STY" "▔"
        }
    done

    # drips: columns of acid running down at their own speeds, heads brightest
    for (( i=0; i<18; i++ )); do
        x=$(( 2 + (i * 29 + i*i*5) % (W - 2) ))
        y=$(( 1 + (f * (2 + i % 3) / 4 + i * 11) % (pool > 1 ? pool : 1) ))
        for n in 0 1 2 3; do
            r=$(( y - n ))
            (( r < 1 || r > H-1 )) && continue
            if (( n == 0 )); then bgtable_sty 210 255 140 "$r"
            else
                g=$(( 200 - n * 40 ))
                bgtable_sty $(( g / 2 )) "$g" $(( g / 3 )) "$r"
            fi
            (( n == 0 )) && put "$r" "$x" "$STY" "◍" || put "$r" "$x" "$STY" "│"
        done
    done

    # the pool it all collects in, its surface fizzing
    if (( pool >= 1 )); then
        tile_of "▀▔▀▁▀▔" $(( W + 8 ))
        off=$(( (f / 2) % 6 ))
        bgtable_sty 170 240 110 "$pool"
        put "$pool" 1 "$STY" "${TILE:off:W}"
        for (( r=pool+1; r<=H-1; r++ )); do
            lum=$(( 110 + ${SIN[$(( (f*2 + r*17) % 60 ))]} * 60 / 1000 ))
            bgtable_sty $(( lum / 2 )) $(( lum + 60 )) $(( lum / 3 )) "$r"
            put "$r" 1 "$STY" "${SPACES// /█}"
        done
        # bubbles popping on the surface
        for (( i=0; i<12; i++ )); do
            x=$(( 1 + (i * 43 + i*i*7 + f / 3) % W ))
            (( ${SIN[$(( (f*3 + i*19) % 60 ))]} > 500 )) || continue
            bgtable_sty 230 255 190 "$pool"
            put "$pool" "$x" "$STY" "∘"
        done
    fi

    top=$(( pool / 2 - 3 ))
    (( top < 1 )) && top=1
    if (( H >= 16 && W >= 70 )); then
        draw_big "$top" BANNER_FAIL 240 255 210  20 40 16
        top=$(( top + 6 ))
    else
        top=2
        msg="✗  BUILD FAILED"
        center ${#msg}
        sty_row 240 255 210 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 2 ))
    fi
    fail_details "$top"
}

# ------------------------------------------------- fail scene: deep freeze ----

# The build frozen solid: a pale blue field creeping over with frost, icicles
# hanging from the top edge, and slow snow settling into drifts. The frost
# crystals grow from fixed seeds, so they are rasterized per growth stage and
# replayed rather than recomputed per frame.
FROST=(); FROST_KEY=""
FROST_STAGES=10

build_frost() { # stage
    local st=$1 i n x y ax ay save=$OUT blob
    OUT=""
    for (( i=0; i<12; i++ )); do
        ax=$(( 3 + (i * 41 + i*i*11) % (W - 6) ))
        ay=$(( 2 + (i * 7 + i/3) % (H - 3 > 1 ? H - 3 : 1) ))
        # six arms per crystal, each grown `st` steps out from the seed
        for (( n=1; n<=st; n++ )); do
            for y in 0 1 2 3 4 5; do
                x=$(( ax + (${SIN[$(( (y * 10 + 15) % 60 ))]} - 500) * n * 2 / 500 ))
                local ry=$(( ay + (${SIN[$(( (y * 10) % 60 ))]} - 500) * n / 500 ))
                (( ry < 1 || ry > H-1 || x < 1 || x > W )) && continue
                bgtable_sty $(( 200 + n*4 > 255 ? 255 : 200 + n*4 )) \
                            $(( 226 + n*3 > 255 ? 255 : 226 + n*3 )) 255 "$ry"
                put "$ry" "$x" "$STY" "❄"
            done
        done
    done
    blob=$OUT
    OUT=$save
    FROST[$st]=$blob
}

scene_fail_freeze() {
    local f=$1 r t i x y top msg n g st ic lum

    BG_KIND=4
    if [ "$BG_KEY" != "frz$H" ]; then
        bgtable_reset
        for (( r=1; r<=H-1; r++ )); do
            t=$(( (r-1)*1000 / (H>1 ? H-1 : 1) ))
            bgtable_row "$r" $(( 26 + 44*t/1000 )) $(( 48 + 62*t/1000 )) \
                             $(( 78 + 60*t/1000 ))
        done
        BG_KEY="frz$H"
        FROST_KEY=""                # the crystals sit on this backdrop
    fi
    bgtable_paint

    # frost creeping in and easing back, so the pane keeps glazing over
    st=$(( (f / 6) % (FROST_STAGES * 2) ))
    (( st >= FROST_STAGES )) && st=$(( FROST_STAGES * 2 - 1 - st ))
    (( st < 1 )) && st=1
    [ "$FROST_KEY" = "$H$W" ] || { FROST=(); FROST_KEY="$H$W"; }
    [ -n "${FROST[$st]:-}" ] || build_frost "$st"
    OUT+=${FROST[$st]}

    # icicles hanging off the top edge, each a different length, tips glinting
    for (( i=0; i<16; i++ )); do
        x=$(( 2 + (i * 23 + i*i*5) % (W - 2) ))
        ic=$(( 2 + (i * 3 + i % 5) % 6 ))
        for (( n=1; n<=ic; n++ )); do
            (( n > H-2 )) && break
            bgtable_sty $(( 200 - n*6 )) $(( 232 - n*4 )) 255 "$n"
            (( n == ic )) && put "$n" "$x" "$STY" "▼" || put "$n" "$x" "$STY" "▐"
        done
        (( ic <= H-2 )) && {
            lum=$(( ${SIN[$(( (f*3 + i*17) % 60 ))]} ))
            (( lum > 800 )) && {
                bgtable_sty 255 255 255 "$ic"
                put "$ic" "$x" "$STY" "✧"
            }
        }
    done

    # snow falling slowly, drifting on a faint breeze
    for (( i=0; i<40; i++ )); do
        y=$(( 1 + (f * (1 + i % 2) / 5 + i * 7 + i/4) % (H - 1) ))
        x=$(( 1 + (i * 37 + i*i*13) % W + (${SIN[$(( (f + i*9) % 60 ))]} - 500) / 260 ))
        g=$(( 225 + (i % 4) * 8 ))
        bgtable_sty "$g" "$g" 255 "$y"
        if (( i % 3 )); then put "$y" "$x" "$STY" "·"
        else                 put "$y" "$x" "$STY" "❅"; fi
    done

    # the drift piling up along the bottom
    local drift=$(( H - 2 ))
    if (( drift > 3 )); then
        tile_of "▄▅▄▆▄▅▃▄" $(( W + 10 ))
        bgtable_sty 236 244 255 "$drift"
        put "$drift" 1 "$STY" "${TILE:$(( (f / 12) % 8 )):W}"
        bgtable_sty 246 250 255 $(( drift + 1 ))
        put $(( drift + 1 )) 1 "$STY" "${SPACES// /█}"
    fi

    top=$(( H/2 - 7 ))
    (( top < 1 )) && top=1
    if (( H >= 16 && W >= 70 )); then
        draw_big "$top" BANNER_FAIL 255 250 250  20 46 80
        top=$(( top + 6 ))
    else
        top=2
        msg="✗  BUILD FAILED"
        center ${#msg}
        sty_row 255 250 250 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 2 ))
    fi
    fail_details "$top"
}

# ------------------------------------------------------- fail scene: flood ----

# Water coming in: the level rises and falls on a slow swell, everything under
# it goes dark blue, a burst pipe jets across the wall, and debris bobs on the
# surface. The backdrop is static — only the waterline and what floats on it
# move — so the rising tide costs a handful of writes per frame.
scene_fail_flood() {
    local f=$1 r t i x y top msg wl off lum n g

    BG_KIND=4
    if [ "$BG_KEY" != "flood$H" ]; then
        bgtable_reset
        for (( r=1; r<=H-1; r++ )); do
            t=$(( (r-1)*1000 / (H>1 ? H-1 : 1) ))
            bgtable_row "$r" $(( 44 + 18*t/1000 )) $(( 46 + 20*t/1000 )) \
                             $(( 56 + 26*t/1000 ))
        done
        BG_KEY="flood$H"
    fi
    bgtable_paint

    # wet concrete: tide marks left by earlier floods, and a pipe on the wall
    tile_of "▁▁▁ ▁▁▁▁" $(( W + 10 ))
    for (( r=3; r<=H-3; r+=4 )); do
        bgtable_sty 62 64 72 "$r"
        put "$r" 1 "$STY" "${TILE:$(( (r * 3) % 8 )):W}"
    done
    local pr=$(( H / 4 )) px=3
    (( pr < 2 )) && pr=2
    bgtable_sty 96 92 84 "$pr"
    put "$pr" 1 "$STY" "══╡"

    # the water: the level swells on a slow cycle, so it keeps creeping up
    wl=$(( H - 3 - ${SIN[$(( (f / 3) % 60 ))]} * (H / 6) / 1000 ))
    (( wl < 4 )) && wl=4
    (( wl > H-1 )) && wl=$(( H-1 ))
    for (( r=wl+1; r<=H-1; r++ )); do
        t=$(( (r-wl)*1000 / (H-wl>0 ? H-wl : 1) ))
        bgtable_sty $(( 18 + 10*t/1000 )) $(( 54 - 20*t/1000 )) \
                    $(( 104 - 34*t/1000 )) "$r"
        put "$r" 1 "$STY" "${SPACES// /█}"
    done
    tile_of "≈~ ˜≈ ~≈˜" $(( W + 12 ))
    off=$(( (f / 2) % 9 ))
    bgtable_sty 150 210 245 "$wl"
    put "$wl" 1 "$STY" "${TILE:off:W}"

    # the pipe jetting into it, and the spray where the jet lands
    for (( n=0; n<8; n++ )); do
        y=$(( pr + n / 2 ))
        (( y < 1 || y >= wl )) && break
        bgtable_sty $(( 170 - n*8 )) $(( 220 - n*6 )) 255 "$y"
        put "$y" $(( px + 1 + n + (f / 2 + n) % 2 )) "$STY" "╲"
    done
    for (( i=0; i<6; i++ )); do
        (( ${SIN[$(( (f*3 + i*17) % 60 ))]} > 480 )) || continue
        y=$(( wl - (i % 2) ))
        (( y < 1 || y > H-1 )) && continue
        bgtable_sty 214 240 255 "$y"
        put "$y" $(( px + 6 + (i * 3 + f / 4) % 9 )) "$STY" "∘"
    done

    # bubbles coming up through the water
    for (( i=0; i<20; i++ )); do
        y=$(( H - 1 - (f / 2 + i * 5) % (H - wl > 1 ? H - wl : 1) ))
        (( y <= wl || y > H-1 )) && continue
        x=$(( 1 + (i * 41 + i*i*7) % W
                + (${SIN[$(( (f*2 + i*13) % 60 ))]} - 500) / 320 ))
        lum=$(( 150 + ${SIN[$(( (f + i*9) % 60 ))]} * 70 / 1000 ))
        bgtable_sty "$lum" 220 255 "$y"
        if (( i % 3 )); then put "$y" "$x" "$STY" "∘"
        else                 put "$y" "$x" "$STY" "○"; fi
    done

    # debris riding the surface: a crate and a couple of planks, each bobbing
    for i in 0 1 2; do
        x=$(( (f * (2 + i) / 9 + i * 31) % (W + 14) - 7 ))
        y=$(( wl - (${SIN[$(( (f*2 + i*20) % 60 ))]} > 560 ? 1 : 0) ))
        (( y < 1 || y > H-1 )) && continue
        if (( i == 0 )); then
            bgtable_sty 168 122 74 "$y"
            put "$y" "$x" "$STY" "▤▤▤"
        else
            bgtable_sty $(( 140 - i*20 )) $(( 104 - i*14 )) 70 "$y"
            put "$y" "$x" "$STY" "▬▬▬▬"
        fi
    done

    # drips off the ceiling, still coming down
    for (( i=0; i<14; i++ )); do
        x=$(( 2 + (i * 29 + i*i*5) % (W - 2) ))
        y=$(( 1 + (f * (2 + i % 3) / 4 + i * 9) % (wl > 1 ? wl : 1) ))
        for n in 0 1; do
            r=$(( y - n ))
            (( r < 1 || r >= wl )) && continue
            g=$(( 210 - n * 60 ))
            bgtable_sty $(( g - 60 )) "$g" 255 "$r"
            (( n == 0 )) && put "$r" "$x" "$STY" "◦" || put "$r" "$x" "$STY" "│"
        done
    done

    top=$(( wl / 2 - 4 ))
    (( top < 1 )) && top=1
    if (( H >= 16 && W >= 70 )); then
        draw_big "$top" BANNER_FAIL 235 246 255  10 30 60
        top=$(( top + 6 ))
    else
        top=2
        msg="✗  BUILD FAILED"
        center ${#msg}
        sty_row 235 246 255 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 2 ))
    fi
    fail_details "$top"
}

# ------------------------------------------------------- fail scene: wires ----

# A cable bundle cut clean through: the loom sags across a dark rack, the two
# severed ends arc at each other every second or so, and sparks drop away from
# the break. The loom is fixed for a window size, so it is rasterized once and
# replayed; only the arc and the sparks move.
LOOM=""; LOOM_KEY=""
ARC_CH=("╱" "╲" "▂" "▔")

build_loom() {
    local b r c y save=$OUT cx gap fr fg fb line
    cx=$(( W / 2 )); gap=$(( W / 9 ))
    (( gap < 3 )) && gap=3
    OUT=""
    # rack rails down both edges, so the loom has something to run between
    for (( r=1; r<=H-2; r++ )); do
        bgtable_sty 70 74 84 "$r"
        put "$r" 1 "$STY" "▐"
        put "$r" "$W" "$STY" "▌"
    done
    # four cables, each sagging on its own arc, all cut at the same seam
    for b in 0 1 2 3; do
        case $b in
            0) fr=210; fg=70;  fb=60  ;;
            1) fr=220; fg=180; fb=60  ;;
            2) fr=70;  fg=140; fb=210 ;;
            *) fr=180; fg=180; fb=190 ;;
        esac
        for (( c=2; c<W; c++ )); do
            (( c > cx - gap && c < cx + gap )) && continue
            y=$(( H/2 - 3 + b*2 + (${SIN[$(( (c * 90 / W + 30) % 60 ))]} - 500) * 3 / 500 ))
            (( y < 1 || y > H-2 )) && continue
            bgtable_sty "$fr" "$fg" "$fb" "$y"
            put "$y" "$c" "$STY" "━"
        done
    done
    # scorched panel under the break
    for (( r=H/2+4; r<=H-2; r++ )); do
        (( r < 1 )) && continue
        tile_of "▒" $(( gap * 2 + 2 ))
        bgtable_sty $(( 40 + (r - H/2) * 4 )) 28 26 "$r"
        put "$r" $(( cx - gap )) "$STY" "${TILE:0:$(( gap * 2 ))}"
    done
    LOOM=$OUT
    OUT=$save
}

scene_fail_wires() {
    local f=$1 r t i x y top msg cx gap n g arc lvl

    BG_KIND=4
    if [ "$BG_KEY" != "wire$H" ]; then
        bgtable_reset
        for (( r=1; r<=H-1; r++ )); do
            t=$(( (r-1)*1000 / (H>1 ? H-1 : 1) ))
            bgtable_row "$r" $(( 24 + 16*t/1000 )) $(( 24 + 14*t/1000 )) \
                             $(( 30 + 16*t/1000 ))
        done
        BG_KEY="wire$H"
        LOOM_KEY=""                 # the loom sits on this backdrop
    fi
    bgtable_paint

    [ "$LOOM_KEY" = "$H$W" ] || { build_loom; LOOM_KEY="$H$W"; }
    OUT+=$LOOM

    cx=$(( W / 2 )); gap=$(( W / 9 ))
    (( gap < 3 )) && gap=3

    # the arc: fires for four frames out of every fourteen, jumping the seam in a
    # zigzag between the two cut ends
    arc=$(( f % 14 ))
    if (( arc < 4 )); then
        y=$(( H/2 - 1 ))
        for (( n=0; n<gap*2; n++ )); do
            x=$(( cx - gap + n ))
            (( x < 1 || x > W )) && continue
            r=$(( y + (n + arc) % 3 - 1 ))
            (( r < 1 || r > H-2 )) && continue
            bgtable_sty 235 245 255 "$r"
            put "$r" "$x" "$STY" "${ARC_CH[$(( (n + f) % 4 ))]}"
        done
        # the flash washing the ends either side of the seam
        for i in 0 1; do
            r=$(( H/2 - 3 + i*4 ))
            (( r < 1 || r > H-2 )) && continue
            bgtable_sty 200 230 255 "$r"
            put "$r" $(( cx - gap - 2 )) "$STY" "≡"
            put "$r" $(( cx + gap + 1 )) "$STY" "≡"
        done
    fi

    # the cut ends glowing hot even between arcs, brightest right after one
    lvl=$(( arc < 6 ? 255 - arc * 20 : 140 ))
    for (( n=0; n<4; n++ )); do
        r=$(( H/2 - 3 + n*2 ))
        (( r < 1 || r > H-2 )) && continue
        bgtable_sty "$lvl" $(( lvl * 2 / 3 )) 80 "$r"
        put "$r" $(( cx - gap )) "$STY" "╾"
        put "$r" $(( cx + gap - 1 )) "$STY" "╼"
    done

    # sparks dropping out of the break and burning out on the way down
    for (( i=0; i<24; i++ )); do
        n=$(( (f * 2 + i * 7) % 26 ))
        y=$(( H/2 - 1 + n / 2 ))
        (( y < 1 || y > H-1 )) && continue
        x=$(( cx - gap + (i * 5 + f / 2) % (gap * 2)
                + (${SIN[$(( (f*2 + i*11) % 60 ))]} - 500) / 300 ))
        g=$(( 240 - n * 8 ))
        bgtable_sty 255 "$g" $(( g / 3 )) "$y"
        if (( i % 3 )); then put "$y" "$x" "$STY" "·"
        else                 put "$y" "$x" "$STY" "▪"; fi
    done

    # smoke lifting off the seam
    for (( i=0; i<10; i++ )); do
        y=$(( H/2 - 4 - (f / 4 + i * 3) % (H/2 > 2 ? H/2 - 2 : 1) ))
        (( y < 1 || y > H-1 )) && continue
        x=$(( cx - 4 + (i * 7 + f / 3) % 9 ))
        g=$(( 80 + (i % 4) * 18 ))
        bgtable_sty "$g" "$g" $(( g + 8 )) "$y"
        put "$y" "$x" "$STY" "▒"
    done

    top=$(( H/2 - 9 ))
    (( top < 1 )) && top=1
    if (( H >= 18 && W >= 70 )); then
        draw_big "$top" BANNER_FAIL 255 236 220  40 30 20
        top=$(( top + 6 ))
    else
        top=2
        msg="✗  BUILD FAILED"
        center ${#msg}
        sty_row 255 236 220 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 2 ))
    fi
    fail_details "$top"
}

# ------------------------------------------------------- fail scene: sandstorm -

# A haboob rolling over the site: the whole frame washes ochre on the gusts,
# sand streaks past almost horizontally, dunes creep along the bottom and a
# signpost stands half buried in it.
scene_fail_sand() {
    local f=$1 r t i x y top msg q off g gust lum n

    gust=$(( ${SIN[$(( (f / 2) % 60 ))]} )); q=$(( gust / 340 ))   # 0..2
    BG_KIND=4
    local key="sand$H$q"
    if [ "$BG_KEY" != "$key" ]; then
        bgtable_reset
        for (( r=1; r<=H-1; r++ )); do
            t=$(( (r-1)*1000 / (H>1 ? H-1 : 1) ))
            bgtable_row "$r" $(( 108 + 26*q + 46*t/1000 )) \
                             $(( 76  + 20*q + 34*t/1000 )) \
                             $(( 42  + 12*q + 18*t/1000 ))
        done
        BG_KEY=$key
    fi
    bgtable_paint

    # the front itself: a churning wall of dust leaning over the top rows
    tile_of "▓▒▓░▒▓▒░▓" $(( W + 12 ))
    for (( r=1; r<=3 && r<=H-2; r++ )); do
        off=$(( (f * 2 + r * 5) % 9 ))
        bgtable_sty $(( 150 + r*10 + 8*q )) $(( 110 + r*8 )) $(( 66 + r*4 )) "$r"
        put "$r" 1 "$STY" "${TILE:off:W}"
    done

    # sand: fast near-horizontal streaks wrapping around the window
    for (( i=0; i<70; i++ )); do
        y=$(( 1 + (i * 3 + i/5 + f / 6) % (H - 1) ))
        x=$(( 1 + (i * 23 + i*i*7 + f * 4) % W ))
        g=$(( 180 + (i % 5) * 14 ))
        bgtable_sty $(( g + 30 > 255 ? 255 : g + 30 )) "$g" $(( g - 70 )) "$y"
        case $(( i % 4 )) in
            0) put "$y" "$x" "$STY" "─" ;;
            1) put "$y" "$x" "$STY" "▬" ;;
            2) put "$y" "$x" "$STY" "·" ;;
            *) put "$y" "$x" "$STY" "˙" ;;
        esac
    done

    # the signpost, buried to its knees, its board swinging in the wind
    local sx=$(( W / 4 )) sy=$(( H - 5 ))
    (( sy < 3 )) && sy=3
    for (( r=sy; r<=H-3; r++ )); do
        bgtable_sty 96 68 46 "$r"
        put "$r" "$sx" "$STY" "█"
    done
    if (( sy-1 >= 1 )); then
        bgtable_sty 176 148 112 $(( sy - 1 ))
        if (( (f/4) % 2 )); then put $(( sy - 1 )) $(( sx - 3 )) "$STY" "▁▔▔▔▔▁"
        else                     put $(( sy - 1 )) $(( sx - 2 )) "$STY" "▔▔▔▔▁▁"; fi
    fi

    # dunes creeping along the bottom, each row sliding at its own pace
    local dune=$(( H - 3 ))
    if (( dune > 3 )); then
        tile_of "▄▅▄▆▅▄▃▄" $(( W + 10 ))
        bgtable_sty 206 168 116 "$dune"
        put "$dune" 1 "$STY" "${TILE:$(( (f / 4) % 8 )):W}"
        for (( r=dune+1; r<=H-1; r++ )); do
            lum=$(( 194 - (r - dune) * 14 ))
            bgtable_sty "$lum" $(( lum - 40 )) $(( lum - 92 )) "$r"
            put "$r" 1 "$STY" "${SPACES// /█}"
        done
        # ripples combed across the dune faces
        tile_of "‾ ˜ ‾  ˜" $(( W + 10 ))
        for (( r=dune+1; r<=H-1; r++ )); do
            bgtable_sty $(( 176 - (r - dune) * 10 )) 138 88 "$r"
            put "$r" 1 "$STY" "${TILE:$(( (f / 3 + r * 3) % 8 )):W}"
        done
    fi

    # a tumbleweed bouncing along in front of it all
    local tx=$(( W + 10 - (f * 3 / 4) % (W + 20) ))
    local ty=$(( dune - (${SIN[$(( (f*4) % 60 ))]} > 600 ? 2 : 0) ))
    if (( ty >= 1 && ty <= H-1 )); then
        bgtable_sty 128 96 58 "$ty"
        put "$ty" "$tx" "$STY" "${VTX_CH[$(( (f/3) % 5 ))]}"
        put "$ty" $(( tx + 1 )) "$STY" "❋"
    fi

    top=$(( H/2 - 8 ))
    (( top < 1 )) && top=1
    if (( H >= 18 && W >= 70 )); then
        draw_big "$top" BANNER_FAIL 255 240 214  70 40 20
        top=$(( top + 6 ))
    else
        top=2
        msg="✗  BUILD FAILED"
        center ${#msg}
        sty_row 255 240 214 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 2 ))
    fi
    fail_details "$top"
}

# ------------------------------------------------------- fail scene: rust -----

# The machine seized: a gear train jammed solid, teeth sheared off one wheel,
# swarf on the floor and grease weeping down the casing. The gears only ever sit
# in a handful of rotations before the jam, so each wheel is rasterized per
# rotation step and replayed; after the jam nothing turns at all.
GEAR=(); GEAR_KEY=""
GEAR_STEPS=6
GEAR_TOOTH=("╬" "╫" "╪" "┼")

build_gear() { # step
    local st=$1 g cx cy rad n a x y save=$OUT blob fr fg fb
    OUT=""
    for g in 0 1 2; do
        case $g in
            0) cx=$(( W/2 - W/6 )); cy=$(( H/2 - 1 )); rad=4; fr=150; fg=138; fb=126 ;;
            1) cx=$(( W/2 + W/9 )); cy=$(( H/2 + 1 )); rad=3; fr=128; fg=112; fb=102 ;;
            *) cx=$(( W/2 + W/4 )); cy=$(( H/2 - 3 )); rad=2; fr=142; fg=120; fb=104 ;;
        esac
        (( cx < rad + 2 || cx > W - rad - 2 )) && continue
        # hub, then teeth stepped round the rim; wheel 1 runs the other way
        (( cy >= 1 && cy <= H-2 )) && {
            bgtable_sty $(( fr + 30 )) $(( fg + 26 )) $(( fb + 22 )) "$cy"
            put "$cy" "$cx" "$STY" "◉"
        }
        for (( n=0; n<12; n++ )); do
            a=$(( (n * 5 + (g == 1 ? -st : st) * 2 + 60) % 60 ))
            x=$(( cx + (${SIN[$(( (a + 15) % 60 ))]} - 500) * rad * 2 / 500 ))
            y=$(( cy + (${SIN[$a]} - 500) * rad / 500 ))
            (( y < 1 || y > H-2 || x < 1 || x > W )) && continue
            bgtable_sty "$fr" "$fg" "$fb" "$y"
            put "$y" "$x" "$STY" "${GEAR_TOOTH[$(( n % 4 ))]}"
        done
    done
    blob=$OUT
    OUT=$save
    GEAR[$st]=$blob
}

scene_fail_rust() {
    local f=$1 r t i x y top msg st n g lum off jam

    BG_KIND=4
    if [ "$BG_KEY" != "rust$H" ]; then
        bgtable_reset
        for (( r=1; r<=H-1; r++ )); do
            t=$(( (r-1)*1000 / (H>1 ? H-1 : 1) ))
            bgtable_row "$r" $(( 58 + 26*t/1000 )) $(( 40 + 16*t/1000 )) \
                             $(( 34 + 12*t/1000 ))
        done
        BG_KEY="rust$H"
    fi
    bgtable_paint

    # the casing behind the train: riveted plate, rust bleeding down it
    tile_of "▓▒▓▓▒▓░▒" $(( W + 12 ))
    for (( r=2; r<=H-2; r+=3 )); do
        bgtable_sty $(( 82 + (r % 3) * 8 )) $(( 54 + (r % 3) * 5 )) 44 "$r"
        put "$r" 1 "$STY" "${TILE:$(( (r * 3) % 8 )):W}"
    done
    for (( i=0; i<10; i++ )); do
        x=$(( 3 + (i * 37 + i*i*7) % (W - 4) ))
        for (( n=0; n<5; n++ )); do
            r=$(( 2 + (i % 3) * 3 + n ))
            (( r < 1 || r > H-2 )) && continue
            bgtable_sty $(( 146 - n*10 )) $(( 78 - n*8 )) 40 "$r"
            put "$r" "$x" "$STY" "▒"
        done
    done

    # the gear train: it grinds a few steps, sticks, then judders and sticks
    # again — the stall is the point, so the motion has to keep dying
    jam=$(( (f / 4) % 14 ))
    if (( jam < GEAR_STEPS )); then st=$jam; else st=$(( GEAR_STEPS - 1 )); fi
    (( jam >= 10 && jam < 12 )) && st=$(( GEAR_STEPS - 2 ))
    [ "$GEAR_KEY" = "$H$W" ] || { GEAR=(); GEAR_KEY="$H$W"; }
    [ -n "${GEAR[$st]:-}" ] || build_gear "$st"
    OUT+=${GEAR[$st]}

    # the sheared teeth, lying where they landed under the big wheel
    for i in 0 1 2 3; do
        y=$(( H/2 + 4 + (i % 2) ))
        (( y < 1 || y > H-1 )) && continue
        x=$(( W/2 - W/6 - 3 + i * 4 ))
        bgtable_sty 168 152 138 "$y"
        put "$y" "$x" "$STY" "${GEAR_TOOTH[$(( i % 4 ))]}"
    done

    # the bind itself: metal glowing where the teeth are locked together
    lum=$(( 180 + ${SIN[$(( (f * 4) % 60 ))]} * 75 / 1000 ))
    x=$(( W/2 - W/24 ))
    for (( n=0; n<3; n++ )); do
        r=$(( H/2 - 1 + n ))
        (( r < 1 || r > H-2 )) && continue
        bgtable_sty "$lum" $(( lum / 2 )) 60 "$r"
        put "$r" $(( x + n )) "$STY" "▨"
    done
    # smoke off the bind, and swarf shaken loose by the judder
    for (( i=0; i<12; i++ )); do
        y=$(( H/2 - 2 - (f / 4 + i * 3) % (H/2 > 2 ? H/2 - 2 : 1) ))
        (( y < 1 || y > H-1 )) && continue
        g=$(( 92 + (i % 4) * 16 ))
        bgtable_sty "$g" $(( g - 10 )) $(( g - 18 )) "$y"
        put "$y" $(( x - 3 + (i * 5 + f / 3) % 8 )) "$STY" "▒"
    done
    for (( i=0; i<18; i++ )); do
        y=$(( H/2 + 1 + (f / 3 + i * 5) % (H/2 - 1 > 1 ? H/2 - 1 : 1) ))
        (( y < 1 || y > H-1 )) && continue
        bgtable_sty $(( 190 - (i % 4) * 20 )) 150 120 "$y"
        put "$y" $(( 2 + (i * 31 + i*i*5) % (W - 3) )) "$STY" "·"
    done

    # a belt hanging slack off the last pulley, no tension left in it
    for (( i=0; i<9; i++ )); do
        y=$(( H/2 - 3 + i / 3 + (${SIN[$(( (f + i*7) % 60 ))]} > 620 ? 1 : 0) ))
        (( y < 1 || y > H-1 )) && continue
        bgtable_sty 40 36 38 "$y"
        put "$y" $(( W/2 + W/4 - 4 + i )) "$STY" "▬"
    done

    top=$(( H/2 - 8 ))
    (( top < 1 )) && top=1
    if (( H >= 18 && W >= 70 )); then
        draw_big "$top" BANNER_FAIL 250 226 210  50 26 20
        top=$(( top + 6 ))
    else
        top=2
        msg="✗  BUILD FAILED"
        center ${#msg}
        sty_row 250 226 210 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 2 ))
    fi
    fail_details "$top"
}

# ------------------------------------------------------ fail scene: tarpit ----

# Sunk in tar: a black bog swallowing the build, bubbles surfacing and bursting
# with a slap, and a hand still above the surface. The mire drifts as one glyph
# tile per row, so the whole surface costs a write a row.
TAR_BUB=("○" "◌" "◍" "●")

scene_fail_tarpit() {
    local f=$1 r t i x y top msg off lum n g surf ph

    surf=$(( H * 52 / 100 ))
    (( surf < 4 )) && surf=4
    (( surf > H-4 )) && surf=$(( H-4 ))
    BG_KIND=4
    if [ "$BG_KEY" != "tar$H" ]; then
        bgtable_reset
        for (( r=1; r<=surf; r++ )); do
            t=$(( (r-1)*1000 / (surf>1 ? surf : 1) ))
            bgtable_row "$r" $(( 44 + 32*t/1000 )) $(( 36 + 24*t/1000 )) \
                             $(( 30 + 16*t/1000 ))
        done
        for (( r=surf+1; r<=H-1; r++ )); do
            t=$(( (r-surf)*1000 / (H-surf>0 ? H-surf : 1) ))
            bgtable_row "$r" $(( 22 - 12*t/1000 )) $(( 18 - 10*t/1000 )) \
                             $(( 18 - 10*t/1000 ))
        done
        BG_KEY="tar$H"
    fi
    bgtable_paint

    # sour haze hanging over the pit
    tile_of "░▒░  ░ ▒" $(( W + 12 ))
    for (( r=1; r<=3 && r<=surf-1; r++ )); do
        off=$(( (f / 3 + r * 4) % 8 ))
        bgtable_sty $(( 86 + r*6 )) $(( 78 + r*5 )) $(( 58 + r*4 )) "$r"
        put "$r" 1 "$STY" "${TILE:off:W}"
    done

    # the surface: slow oily swirls, each row creeping at its own pace
    tile_of "▀▔▀▀▔▀▔▀" $(( W + 10 ))
    bgtable_sty 62 56 50 "$surf"
    put "$surf" 1 "$STY" "${TILE:$(( (f / 6) % 8 )):W}"
    tile_of "▬▭▬▬▭▬▭" $(( W + 10 ))
    for (( r=surf+1; r<=H-1; r++ )); do
        off=$(( (f / (4 + r % 3) + r * 3) % 7 ))
        lum=$(( 44 - (r - surf) * 4 )); (( lum < 12 )) && lum=12
        bgtable_sty "$lum" $(( lum - 4 > 0 ? lum - 4 : 0 )) \
                    $(( lum - 6 > 0 ? lum - 6 : 0 )) "$r"
        put "$r" 1 "$STY" "${TILE:off:W}"
    done
    # a rainbow sheen sliding over the tar, the one bright thing in here
    for (( i=0; i<9; i++ )); do
        y=$(( surf + 1 + (i * 3) % (H - surf - 1 > 0 ? H - surf - 1 : 1) ))
        (( y > H-1 )) && continue
        x=$(( 2 + (i * 47 + i*i*7 + f / 2) % (W - 3) ))
        case $(( i % 3 )) in
            0) bgtable_sty 92 70 110 "$y" ;;
            1) bgtable_sty 70 96 88  "$y" ;;
            *) bgtable_sty 104 84 62 "$y" ;;
        esac
        put "$y" "$x" "$STY" "▒▒"
    done

    # bubbles: they swell for a while, then burst into a ring of specks
    for (( i=0; i<9; i++ )); do
        ph=$(( (f * 2 + i * 17) % 40 ))
        x=$(( 3 + (i * 41 + i*i*11) % (W - 6) ))
        y=$(( surf + (i % 3) ))
        (( y < 1 || y > H-1 )) && continue
        if (( ph < 28 )); then
            bgtable_sty $(( 70 + ph )) $(( 62 + ph )) 54 "$y"
            put "$y" "$x" "$STY" "${TAR_BUB[$(( ph / 7 ))]}"
        elif (( ph < 33 )); then
            bgtable_sty 132 120 100 "$y"
            put "$y" $(( x - 2 )) "$STY" "·  ·"
            (( y-1 >= 1 )) && {
                bgtable_sty 116 106 88 $(( y - 1 ))
                put $(( y - 1 )) $(( x - 1 )) "$STY" "˙˙"
            }
        fi
    done

    # the hand, still up out of it, fingers sinking a little each cycle
    local hx=$(( W / 4 )) hd=$(( (f / 12) % 3 ))
    for (( n=0; n<3; n++ )); do
        r=$(( surf - 3 + n + hd ))
        (( r < 1 || r > H-1 )) && continue
        bgtable_sty $(( 150 - n*20 )) $(( 128 - n*18 )) $(( 112 - n*16 )) "$r"
        case $n in
            0) put "$r" "$hx" "$STY" "▕▏▕" ;;
            1) put "$r" "$hx" "$STY" "███" ;;
            *) put "$r" "$hx" "$STY" "▀█▀" ;;
        esac
    done

    # a crate and a signboard going under alongside it
    local cx=$(( W - W/3 ))
    for (( n=0; n<2; n++ )); do
        r=$(( surf - 1 + n + (f / 16) % 2 ))
        (( r < 1 || r > H-1 )) && continue
        bgtable_sty $(( 108 - n*20 )) $(( 78 - n*14 )) 52 "$r"
        put "$r" "$cx" "$STY" "▤▤▤▤"
    done

    top=$(( surf / 2 - 4 ))
    (( top < 1 )) && top=1
    if (( H >= 18 && W >= 70 )); then
        draw_big "$top" BANNER_FAIL 240 224 200  30 24 20
        top=$(( top + 6 ))
    else
        top=2
        msg="✗  BUILD FAILED"
        center ${#msg}
        sty_row 240 224 200 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 2 ))
    fi
    fail_details "$top"
}

# ------------------------------------------------------ fail scene: derail ----

# A locomotive off the rails: the track buckles into a kink, the engine lies on
# its side in the ballast with a wheel still spinning, and steam screams out of
# the boiler. The wreck and the twisted track are fixed for a window size and
# rasterized once; the steam, the sparks and the wheel are all that move.
WRECK=""; WRECK_KEY=""
SPIN_CH=("│" "╱" "─" "╲")

build_wreck() { # rr
    local rr=$1 c r y save=$OUT kink line n wx
    OUT=""
    kink=$(( W / 2 ))
    # ballast under everything
    for (( r=rr; r<=H-1; r++ )); do
        tile_of "▚▞▚▞▚▞" $(( W + 8 ))
        bgtable_sty $(( 96 - (r - rr) * 6 )) $(( 88 - (r - rr) * 6 )) 78 "$r"
        put "$r" 1 "$STY" "${TILE:$(( (r * 2) % 6 )):W}"
    done
    # the track: straight up to the kink, then peeled up and away from it
    tile_of "▬ ▬ ▬ " $(( W + 8 ))
    bgtable_sty 84 66 52 "$rr"
    put "$rr" 1 "$STY" "${TILE:0:W}"
    for (( c=1; c<=W; c++ )); do
        if (( c < kink - 6 )); then
            y=$rr
        elif (( c < kink + 4 )); then
            y=$(( rr - (c - kink + 6) / 2 ))
        else
            y=$(( rr - 1 + (c - kink - 4) / 6 ))
            (( y > rr )) && y=$rr
        fi
        (( y < 1 || y > H-1 )) && continue
        bgtable_sty 176 172 168 "$y"
        put "$y" "$c" "$STY" "═"
    done
    # sleepers thrown out of the bed at the kink
    for (( n=0; n<5; n++ )); do
        r=$(( rr - 1 + n % 2 ))
        (( r < 1 || r > H-1 )) && continue
        bgtable_sty 96 72 54 "$r"
        put "$r" $(( kink + 6 + n * 5 )) "$STY" "▬▬"
    done
    # the engine, on its side just past the kink
    wx=$(( kink - 16 )); (( wx < 2 )) && wx=2
    for (( n=0; n<4; n++ )); do
        r=$(( rr - 4 + n ))
        (( r < 1 || r > H-1 )) && continue
        case $n in
            0) bgtable_sty 74 70 78 "$r"; line="  ▂▂▂▂▂▂▂▂▂▂  " ;;
            1) bgtable_sty 58 56 64 "$r"; line=" ▟██████████▙▖" ;;
            2) bgtable_sty 46 44 52 "$r"; line="▐████████████▌" ;;
            *) bgtable_sty 38 36 44 "$r"; line=" ▀▀▀      ▀▀▀ " ;;
        esac
        put "$r" "$wx" "$STY" "$line"
    done
    # a gouge torn through the ballast behind it
    (( rr-1 >= 1 )) && {
        tile_of "▂▃▂▃▂" $(( W / 4 + 4 ))
        bgtable_sty 118 96 74 $(( rr - 1 ))
        put $(( rr - 1 )) $(( wx + 14 )) "$STY" "${TILE:0:$(( W / 5 ))}"
    }
    WRECK=$OUT
    OUT=$save
}

scene_fail_derail() {
    local f=$1 r t i x y top msg rr n g lum wx off kink

    rr=$(( H - 3 ))
    (( rr < 6 )) && rr=$(( H - 1 ))
    BG_KIND=4
    if [ "$BG_KEY" != "drl$H" ]; then
        bgtable_reset
        for (( r=1; r<=H-1; r++ )); do
            t=$(( (r-1)*1000 / (H>1 ? H-1 : 1) ))
            bgtable_row "$r" $(( 52 + 30*t/1000 )) $(( 44 + 22*t/1000 )) \
                             $(( 48 + 18*t/1000 ))
        done
        BG_KEY="drl$H"
        WRECK_KEY=""                # the wreck sits on this backdrop
    fi
    bgtable_paint

    [ "$WRECK_KEY" = "$H$W" ] || { build_wreck "$rr"; WRECK_KEY="$H$W"; }
    OUT+=$WRECK

    kink=$(( W / 2 ))
    wx=$(( kink - 16 )); (( wx < 2 )) && wx=2

    # steam screaming out of the boiler, filling the top of the frame
    for (( i=0; i<30; i++ )); do
        y=$(( rr - 5 - (f / 3 + i * 3) % (rr - 2 > 1 ? rr - 2 : 1) ))
        (( y < 1 || y > H-1 )) && continue
        x=$(( wx + 2 + (i * 7 + f / 2) % 22
                + (${SIN[$(( (f + i*11) % 60 ))]} - 500) / 220 ))
        g=$(( 220 - (rr - 5 - y) * 6 )); (( g < 90 )) && g=90
        bgtable_sty "$g" "$g" $(( g + 6 )) "$y"
        case $(( i % 3 )) in
            0) put "$y" "$x" "$STY" "▓" ;;
            1) put "$y" "$x" "$STY" "▒" ;;
            *) put "$y" "$x" "$STY" "░" ;;
        esac
    done
    # the jet itself, hard and bright where it leaves the split casing
    if (( rr-5 >= 1 )); then
        for (( n=0; n<5; n++ )); do
            r=$(( rr - 5 - n / 2 ))
            (( r < 1 || r > H-1 )) && continue
            bgtable_sty 250 252 255 "$r"
            put "$r" $(( wx + 4 + n + (f / 2) % 2 )) "$STY" "╱"
        done
    fi

    # the free wheel, still turning over in the air
    if (( rr-5 >= 1 )); then
        y=$(( rr - 5 ))
        bgtable_sty 168 160 150 "$y"
        put "$y" $(( wx + 12 )) "$STY" "${SPIN_CH[$(( (f/2) % 4 ))]}"
        bgtable_sty 128 122 116 "$y"
        put "$y" $(( wx + 13 )) "$STY" "◯"
    fi

    # sparks skittering off where steel is still dragging on steel
    for (( i=0; i<20; i++ )); do
        y=$(( rr - 1 + (i % 2) ))
        (( y < 1 || y > H-1 )) && continue
        x=$(( wx + 14 + (i * 5 + f * 3) % (W / 4 > 4 ? W / 4 : 4) ))
        g=$(( 240 - (i % 5) * 24 ))
        bgtable_sty 255 "$g" $(( g / 3 )) "$y"
        if (( i % 3 )); then put "$y" "$x" "$STY" "·"
        else                 put "$y" "$x" "$STY" "▪"; fi
    done

    # the warning lamp on the post beyond the kink, going all the while
    local px=$(( W - W/6 ))
    if (( rr-4 >= 1 )); then
        for (( r=rr-3; r<=rr-1; r++ )); do
            (( r < 1 )) && continue
            bgtable_sty 78 74 70 "$r"
            put "$r" "$px" "$STY" "│"
        done
        lum=$(( ${SIN[$(( (f * 4) % 60 ))]} ))
        if (( lum > 500 )); then
            bgtable_sty 255 70 60 $(( rr - 4 ))
            put $(( rr - 4 )) "$px" "$STY" "◉"
        else
            bgtable_sty 110 40 40 $(( rr - 4 ))
            put $(( rr - 4 )) "$px" "$STY" "◎"
        fi
    fi

    # grit still settling out of the air over the ballast
    for (( i=0; i<16; i++ )); do
        y=$(( rr - 2 + (f / 4 + i * 3) % 3 ))
        (( y < 1 || y > H-1 )) && continue
        bgtable_sty $(( 140 - (i % 4) * 14 )) $(( 126 - (i % 4) * 12 )) 108 "$y"
        put "$y" $(( 2 + (i * 37 + i*i*7) % (W - 3) )) "$STY" "˙"
    done

    top=$(( rr / 2 - 6 ))
    (( top < 1 )) && top=1
    if (( H >= 18 && W >= 70 )); then
        draw_big "$top" BANNER_FAIL 255 236 230  50 30 30
        top=$(( top + 6 ))
    else
        top=2
        msg="✗  BUILD FAILED"
        center ${#msg}
        sty_row 255 236 230 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 2 ))
    fi
    fail_details "$top"
}

# ---------------------------------------------------- fail scene: avalanche ---

# The slope lets go: a fracture line across the face, the snow above it sliding
# down as a front of debris, and a powder cloud boiling up over the top of it.
# The mountain is fixed for a window size and rasterized once; the slide moves.
AVAL=""; AVAL_KEY=""

build_aval() {
    local r c line save=$OUT half apex px
    OUT=""
    px=$(( W / 2 ))
    apex=2
    # the face: a broad wedge filling the frame from a peak near the top
    for (( r=apex; r<=H-1; r++ )); do
        half=$(( (r - apex) * (W / 2) / (H - apex > 0 ? H - apex : 1) + 2 ))
        tile_of "█" $(( half * 2 + 2 ))
        if (( (r + half) % 5 == 0 )); then
            bgtable_sty 150 156 172 "$r"
        else
            bgtable_sty $(( 176 + (r % 3) * 8 )) $(( 182 + (r % 3) * 8 )) \
                        $(( 198 + (r % 3) * 6 )) "$r"
        fi
        put "$r" $(( px - half )) "$STY" "${TILE:0:$(( half * 2 + 1 ))}"
    done
    # rock bands showing through where the snow has been stripped off
    for (( r=H/3; r<=H-2; r+=3 )); do
        (( r < 1 )) && continue
        line=""
        for (( c=0; c<W/3; c++ )); do
            (( c % 4 == 3 )) && line+=" " || line+="▄"
        done
        bgtable_sty 92 88 96 "$r"
        put "$r" $(( px - W/6 + (r % 5) * 2 )) "$STY" "$line"
    done
    AVAL=$OUT
    OUT=$save
}

scene_fail_avalanche() {
    local f=$1 r t i x y top msg frac front n g lum off

    BG_KIND=4
    if [ "$BG_KEY" != "aval$H" ]; then
        bgtable_reset
        for (( r=1; r<=H-1; r++ )); do
            t=$(( (r-1)*1000 / (H>1 ? H-1 : 1) ))
            bgtable_row "$r" $(( 88 + 44*t/1000 )) $(( 96 + 44*t/1000 )) \
                             $(( 116 + 42*t/1000 ))
        done
        BG_KEY="aval$H"
        AVAL_KEY=""                 # the face sits on this backdrop
    fi
    bgtable_paint

    [ "$AVAL_KEY" = "$H$W" ] || { build_aval; AVAL_KEY="$H$W"; }
    OUT+=$AVAL

    # the fracture line, a hard dark crown right across the slope
    frac=$(( H / 3 ))
    (( frac < 2 )) && frac=2
    if (( frac <= H-1 )); then
        tile_of "▁▁▂▁▁▃▁▂" $(( W + 10 ))
        bgtable_sty 58 62 76 "$frac"
        put "$frac" 1 "$STY" "${TILE:0:W}"
        (( frac+1 <= H-1 )) && {
            bgtable_sty 120 126 142 $(( frac + 1 ))
            put $(( frac + 1 )) 1 "$STY" "${DASHES// /▔}"
        }
    fi

    # the front of the slide, running down the face on a loop
    front=$(( frac + 2 + (f / 2) % (H - frac - 2 > 1 ? H - frac - 2 : 1) ))
    for (( n=0; n<5; n++ )); do
        r=$(( front + n ))
        (( r < 1 || r > H-1 )) && continue
        off=$(( (f * 2 + r * 3) % 8 ))
        case $n in
            0) tile_of "▁▂▁▃▁▂▃▁" $(( W + 10 )); bgtable_sty 252 254 255 "$r" ;;
            1) tile_of "███▓██▓█" $(( W + 10 )); bgtable_sty 236 240 248 "$r" ;;
            2) tile_of "▓▓█▓▒▓█▓" $(( W + 10 )); bgtable_sty 210 216 228 "$r" ;;
            3) tile_of "▒▓▒░▒▓░▒" $(( W + 10 )); bgtable_sty 178 184 198 "$r" ;;
            *) tile_of "░▒░ ░▒ ░" $(( W + 10 )); bgtable_sty 150 156 170 "$r" ;;
        esac
        put "$r" 1 "$STY" "${TILE:off:W}"
    done

    # powder boiling up above the front, thinning as it rises
    for (( i=0; i<44; i++ )); do
        y=$(( front - 1 - (i * 5 + f / 3) % 7 ))
        (( y < 1 || y > H-1 )) && continue
        x=$(( 1 + (i * 29 + i*i*11) % W
                + (${SIN[$(( (f*2 + i*13) % 60 ))]} - 500) / 200 ))
        g=$(( 250 - (front - y) * 16 )); (( g < 150 )) && g=150
        bgtable_sty "$g" "$g" $(( g + 5 > 255 ? 255 : g + 5 )) "$y"
        case $(( i % 3 )) in
            0) put "$y" "$x" "$STY" "▓" ;;
            1) put "$y" "$x" "$STY" "▒" ;;
            *) put "$y" "$x" "$STY" "░" ;;
        esac
    done

    # blocks of slab tumbling along ahead of it
    for (( i=0; i<12; i++ )); do
        y=$(( front + 5 + (i % 3) ))
        (( y < 1 || y > H-1 )) && continue
        x=$(( 2 + (i * 43 + i*i*7 + f * 2) % (W - 3) ))
        bgtable_sty $(( 230 - (i % 4) * 20 )) $(( 234 - (i % 4) * 20 )) 246 "$y"
        if (( i % 2 )); then put "$y" "$x" "$STY" "▟▙"
        else                 put "$y" "$x" "$STY" "▜▛"; fi
    done

    # the pines that were standing here, going over as it passes
    for (( i=0; i<5; i++ )); do
        x=$(( 4 + (i * 47 + i*i*11) % (W - 6) ))
        y=$(( frac + 3 + (i * 5) % (H - frac - 3 > 1 ? H - frac - 3 : 1) ))
        (( y < 1 || y > H-1 )) && continue
        bgtable_sty 30 52 40 "$y"
        if (( y < front )); then put "$y" "$x" "$STY" "▲"
        else                     put "$y" "$x" "$STY" "◣"; fi
    done

    top=$(( frac / 2 - 3 ))
    (( top < 1 )) && top=1
    if (( H >= 18 && W >= 70 )); then
        draw_big "$top" BANNER_FAIL 120 20 28  240 244 252
        top=$(( top + 6 ))
    else
        top=2
        msg="✗  BUILD FAILED"
        center ${#msg}
        sty_row 120 20 28 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 2 ))
    fi
    fail_details "$top"
}

# --------------------------------------------------- fail scene: black hole ---

# Everything falling in: an accretion disc spiralling into a dead circle at the
# centre, code and stars stretched out along the infall, and a shell of lensed
# light around the shadow. The event horizon is fixed for a size and cached.
HOLE=""; HOLE_KEY=""

build_hole() {
    local cx cy ry rx r dy u half save=$OUT line c
    OUT=""
    cx=$(( W / 2 )); cy=$(( H / 2 ))
    ry=$(( H / 6 )); (( ry < 2 )) && ry=2
    rx=$(( ry * 2 ))
    for (( r=cy-ry; r<=cy+ry; r++ )); do
        (( r < 1 || r > H-1 )) && continue
        dy=$(( r - cy ))
        u=$(( dy * 1000 / ry ))
        isqrt $(( 1000000 - u * u ))
        half=$(( rx * ISQ / 1000 ))
        (( half < 1 )) && continue
        line=""
        for (( c=0; c<half*2+1; c++ )); do line+="█"; done
        # the shadow itself: as close to nothing as a terminal gets
        bgtable_sty 2 0 4 "$r"
        put "$r" $(( cx - half )) "$STY" "$line"
        # the lensed rim, one bright cell either side of the limb
        bgtable_sty 255 210 140 "$r"
        put "$r" $(( cx - half - 1 )) "$STY" "▏"
        put "$r" $(( cx + half + 1 )) "$STY" "▕"
    done
    HOLE=$OUT
    OUT=$save
}

INFALL='fn impl let mut use pub mod ref dyn as in'

scene_fail_hole() {
    local f=$1 r t i x y top msg cx cy ry rx n g lum ph rad ang w s

    BG_KIND=4
    if [ "$BG_KEY" != "hole$H" ]; then
        bgtable_reset
        for (( r=1; r<=H-1; r++ )); do
            t=$(( (r-1)*1000 / (H>1 ? H-1 : 1) ))
            bgtable_row "$r" $(( 14 + 12*t/1000 )) $(( 6 + 6*t/1000 )) \
                             $(( 18 + 14*t/1000 ))
        done
        BG_KEY="hole$H"
        HOLE_KEY=""                 # the horizon sits on this backdrop
    fi
    bgtable_paint

    cx=$(( W / 2 )); cy=$(( H / 2 ))
    ry=$(( H / 6 )); (( ry < 2 )) && ry=2
    rx=$(( ry * 2 ))

    # stars, smeared into arcs by the lensing near the hole
    for (( i=0; i<48; i++ )); do
        y=$(( 1 + (i * 5 + i/4) % (H - 2) ))
        x=$(( 1 + (i * 37 + i*i*7) % W ))
        lum=$(( 110 + ${SIN[$(( (f + i*19) % 60 ))]} * 90 / 1000 ))
        bgtable_sty "$lum" "$lum" $(( lum + 20 > 255 ? 255 : lum + 20 )) "$y"
        put "$y" "$x" "$STY" "·"
    done

    # the accretion disc: rings of matter, each one further round than the last,
    # brightest where it is about to go over the edge
    for (( n=1; n<=5; n++ )); do
        rad=$(( n * (rx / 2 + 2) ))
        for (( i=0; i<20; i++ )); do
            ang=$(( (i * 3 + f * (7 - n) / 2 + n * 11) % 60 ))
            x=$(( cx + (${SIN[$(( (ang + 15) % 60 ))]} - 500) * rad / 500 ))
            y=$(( cy + (${SIN[$ang]} - 500) * rad / 1400 ))
            (( x < 1 || x > W || y < 1 || y > H-1 )) && continue
            g=$(( 255 - n * 26 ))
            bgtable_sty 255 $(( g - 40 > 0 ? g - 40 : 0 )) $(( g / 5 )) "$y"
            case $(( n % 3 )) in
                0) put "$y" "$x" "$STY" "▪" ;;
                1) put "$y" "$x" "$STY" "▬" ;;
                *) put "$y" "$x" "$STY" "·" ;;
            esac
        done
    done

    # the polar jets, punching straight out top and bottom
    for (( n=1; n<=H/3; n++ )); do
        g=$(( 240 - n * 14 )); (( g < 70 )) && g=70
        r=$(( cy - ry - n ))
        (( r >= 1 )) && {
            bgtable_sty $(( g / 2 )) "$g" 255 "$r"
            put "$r" $(( cx + (${SIN[$(( (f*2 + n*7) % 60 ))]} - 500) / 400 )) \
                "$STY" "│"
        }
        r=$(( cy + ry + n ))
        (( r <= H-1 )) && {
            bgtable_sty $(( g / 2 )) "$g" 255 "$r"
            put "$r" $(( cx + (${SIN[$(( (f*2 + n*7 + 30) % 60 ))]} - 500) / 400 )) \
                "$STY" "│"
        }
    done

    [ "$HOLE_KEY" = "$H$W" ] || { build_hole; HOLE_KEY="$H$W"; }
    OUT+=$HOLE

    # source falling in from the edges, stretching as it goes
    set -- $INFALL
    for (( i=0; i<11; i++ )); do
        ph=$(( (f * 2 + i * 13) % 60 ))
        s=$1; shift; set -- "$@" "$s"
        # a straight run in from one of the four sides toward the horizon
        case $(( i % 4 )) in
            0) x=$(( 1 + (60 - ph) * (cx - rx - 2) / 60 )); y=$(( 2 + (i * 7) % (H - 3) )) ;;
            1) x=$(( W - (60 - ph) * (cx - rx - 2) / 60 )); y=$(( 2 + (i * 5) % (H - 3) )) ;;
            2) y=$(( 1 + (60 - ph) * (cy - ry - 1) / 60 )); x=$(( 2 + (i * 29) % (W - 4) )) ;;
            *) y=$(( H - 1 - (60 - ph) * (cy - ry - 1) / 60 )); x=$(( 2 + (i * 31) % (W - 4) )) ;;
        esac
        (( x < 1 || x > W || y < 1 || y > H-1 )) && continue
        g=$(( 100 + ph * 155 / 60 ))
        bgtable_sty "$g" $(( g * 3 / 4 )) $(( g / 2 )) "$y"
        w=$(( ph / 20 + 1 ))
        put "$y" "$x" "$STY" "${s:0:w}"
    done

    top=$(( cy - ry - 8 ))
    if (( H >= 20 && W >= 70 && top >= 1 )); then
        draw_big "$top" BANNER_FAIL 255 226 200  60 20 10
        top=$(( top + 6 ))
    else
        top=2
        msg="✗  BUILD FAILED"
        center ${#msg}
        sty_row 255 226 200 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 2 ))
    fi
    fail_details "$top"
}

# ------------------------------------------------------ fail scene: locusts ---

# A plague coming through: a dust-brown sky, a wall of locusts crossing it in a
# ragged front, and the crop under them stripped down to bare stalks as the
# swarm passes over. The field is redrawn per row from one tile, so it is cheap.
LOCUST=("✷" "✸" "❋" "✳")

scene_fail_locusts() {
    local f=$1 r t i x y top msg hz n g lum off front

    hz=$(( H * 70 / 100 ))
    (( hz < 5 )) && hz=5
    (( hz > H-3 )) && hz=$(( H-3 ))
    BG_KIND=4
    if [ "$BG_KEY" != "locu$H" ]; then
        bgtable_reset
        for (( r=1; r<=hz; r++ )); do
            t=$(( (r-1)*1000 / (hz>1 ? hz : 1) ))
            bgtable_row "$r" $(( 108 + 46*t/1000 )) $(( 84 + 40*t/1000 )) \
                             $(( 44 + 22*t/1000 ))
        done
        for (( r=hz+1; r<=H-1; r++ )); do
            t=$(( (r-hz)*1000 / (H-hz>0 ? H-hz : 1) ))
            bgtable_row "$r" $(( 122 - 34*t/1000 )) $(( 100 - 30*t/1000 )) \
                             $(( 56 - 18*t/1000 ))
        done
        BG_KEY="locu$H"
    fi
    bgtable_paint

    # a smothered sun, barely getting through the dust
    local sr=$(( 2 + hz / 8 )) sc=$(( W / 4 ))
    for i in 0 1 2; do
        r=$(( sr + i ))
        (( r < 1 || r > hz )) && continue
        bgtable_sty 200 $(( 150 + ${SIN[$(( f % 60 ))]} * 26 / 1000 )) 80 "$r"
        put "$r" $(( sc - 4 )) "$STY" "${SUN_SEA[$i]}"
    done

    # the front of the swarm, sweeping across the field left to right
    front=$(( (f * 3 / 2) % (W + 40) - 20 ))

    # the crop: standing ahead of the front, chewed to stubble behind it
    tile_of "ψ ψ  ψ ψ ψ" $(( W + 12 ))
    local stub; tile_of "ˌ  ˌ ˌ  ˌ " $(( W + 12 )); stub=$TILE
    tile_of "ψ ψ  ψ ψ ψ" $(( W + 12 ))
    for (( r=hz+1; r<=H-1; r++ )); do
        off=$(( (f / 6 + r * 3) % 10 ))
        # ahead of the front the crop is still there, behind it only stalks
        bgtable_sty $(( 168 - (r - hz) * 6 )) $(( 158 - (r - hz) * 8 )) 74 "$r"
        put "$r" 1 "$STY" "${TILE:off:W}"
        if (( front > 1 )); then
            bgtable_sty $(( 118 - (r - hz) * 4 )) $(( 92 - (r - hz) * 4 )) 52 "$r"
            put "$r" 1 "$STY" "${stub:off:$(( front > W ? W : front ))}"
        fi
    done

    # a fence line the swarm is coming over
    for (( i=0; i<W; i+=6 )); do
        r=$(( hz ))
        (( r < 1 || r > H-1 )) && continue
        bgtable_sty 86 66 44 "$r"
        put "$r" $(( i + 1 )) "$STY" "╫"
    done
    (( hz >= 1 && hz <= H-1 )) && {
        bgtable_sty 74 58 40 "$hz"
        put "$hz" 1 "$STY" "${DASHES// /═}"
    }

    # the swarm itself: densest at the front, trailing off behind it
    for (( i=0; i<110; i++ )); do
        x=$(( front - (i * 7 + i*i*3) % (W / 2 + 20)
                + (${SIN[$(( (f*3 + i*11) % 60 ))]} - 500) / 200 ))
        y=$(( 1 + (i * 5 + i/3 + f / 2) % (H - 2)
                + (${SIN[$(( (f*4 + i*17) % 60 ))]} - 500) / 400 ))
        (( x < 1 || x > W || y < 1 || y > H-1 )) && continue
        g=$(( 200 - (i % 5) * 22 ))
        bgtable_sty "$g" $(( g - 50 )) 50 "$y"
        put "$y" "$x" "$STY" "${LOCUST[$(( (f/2 + i) % 4 ))]}"
    done
    # the leading edge, a dark band where they are thickest — ragged, not a wall
    for (( n=0; n<3; n++ )); do
        for (( i=0; i<26; i++ )); do
            y=$(( 1 + (i * 3 + n * 7 + f / 3) % (H - 2) ))
            x=$(( front - n * 2 + (${SIN[$(( (y * 9 + n * 13 + f) % 60 ))]} - 500) / 160 ))
            (( x < 1 || x > W || y > H-1 )) && continue
            bgtable_sty $(( 70 + n*20 )) $(( 52 + n*16 )) 30 "$y"
            put "$y" "$x" "$STY" "▓"
        done
    done

    # husks and wing scraps blowing along the ground behind it
    for (( i=0; i<16; i++ )); do
        y=$(( H - 2 + (i % 2) ))
        (( y < 1 || y > H-1 )) && continue
        x=$(( 1 + (i * 41 + i*i*7 + f * 2) % W ))
        bgtable_sty $(( 150 - (i % 4) * 16 )) $(( 122 - (i % 4) * 14 )) 60 "$y"
        put "$y" "$x" "$STY" "˙"
    done

    top=$(( hz / 3 - 2 ))
    (( top < 1 )) && top=1
    if (( H >= 18 && W >= 70 )); then
        draw_big "$top" BANNER_FAIL 60 24 12  220 190 120
        top=$(( top + 6 ))
    else
        top=2
        msg="✗  BUILD FAILED"
        center ${#msg}
        sty_row 60 24 12 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 2 ))
    fi
    fail_details "$top"
}

# ------------------------------------------------------- fail scene: sinking --

# The build going down with the ship: a hull listing bow-up in a black sea, the
# waterline creeping higher on a slow cycle, debris and an empty life ring
# floating off it, and a last flare going up over the whole thing.
SINK_HULL=("▟█████████▙" "███████████" "▜█████████▛")

scene_fail_sinking() {
    local f=$1 r t i x y top msg wl n g lum off hx hy tilt cyc
    # the waterline climbs over a 120-frame cycle, then resets: it never quite
    # reaches the banner, so the details stay readable
    cyc=$(( (f / 2) % 120 ))
    wl=$(( H - 2 - cyc * (H / 3) / 120 ))
    (( wl < H/2 )) && wl=$(( H / 2 ))
    (( wl > H-2 )) && wl=$(( H - 2 ))
    BG_KIND=4
    local key="sink$H$wl"
    if [ "$BG_KEY" != "$key" ]; then
        bgtable_reset
        for (( r=1; r<=wl; r++ )); do
            t=$(( (r-1)*1000 / (wl>1 ? wl : 1) ))
            bgtable_row "$r" $(( 30 + 46*t/1000 )) $(( 20 + 24*t/1000 )) \
                             $(( 32 + 28*t/1000 ))
        done
        for (( r=wl+1; r<=H-1; r++ )); do
            t=$(( (r-wl)*1000 / (H-wl>0 ? H-wl : 1) ))
            bgtable_row "$r" $(( 14 + 6*t/1000 )) $(( 24 - 8*t/1000 )) \
                             $(( 40 - 14*t/1000 ))
        done
        BG_KEY=$key
    fi
    bgtable_paint

    # low cloud over the water, lit from underneath by the flare
    tile_of "▄▂▃▄▅▃▄▂" $(( W + 12 ))
    for (( r=1; r<=2 && r<=H-2; r++ )); do
        off=$(( (f / 6 + r * 3) % 8 ))
        bgtable_sty $(( 76 + r*8 )) $(( 52 + r*6 )) $(( 60 + r*6 )) "$r"
        put "$r" 1 "$STY" "${TILE:off:W}"
    done

    # a flare hanging over the wreck, swinging under its little parachute
    local flx=$(( W - W/4 + (${SIN[$(( (f*2) % 60 ))]} - 500) / 200 ))
    local fly=$(( 2 + (f / 8) % 3 ))
    if (( fly >= 1 && fly <= H-2 )); then
        g=$(( 200 + ${SIN[$(( (f*4) % 60 ))]} * 55 / 1000 ))
        bgtable_sty 255 "$g" 140 "$fly"
        put "$fly" "$flx" "$STY" "✷"
        (( fly-1 >= 1 )) && {
            bgtable_sty 220 200 190 $(( fly - 1 ))
            put $(( fly - 1 )) $(( flx - 1 )) "$STY" "╭─╮"
        }
        for (( n=1; n<=4; n++ )); do
            r=$(( fly + n ))
            (( r < 1 || r > wl )) && break
            bgtable_sty $(( 200 - n*30 )) $(( 130 - n*20 )) 90 "$r"
            put "$r" "$flx" "$STY" "░"
        done
    fi

    # the sea, laid in before the wreck so she sits in the water rather than
    # under it — each band of swell slides at its own pace
    tile_of "≈ ~ ˜≈  ~" $(( W + 12 ))
    for (( r=wl; r<=H-1; r++ )); do
        off=$(( (f * (1 + r % 3) / 3 + r * 5) % 9 ))
        lum=$(( 96 - (r - wl) * 8 )); (( lum < 30 )) && lum=30
        bgtable_sty "$lum" $(( lum + 20 )) $(( lum + 44 )) "$r"
        put "$r" 1 "$STY" "${TILE:off:W}"
    done

    # the hull, listing bow-up: the stern rows are already awash, so only what
    # is above the waterline gets drawn
    hx=$(( W/2 - W/8 )); hy=$(( wl - 2 ))
    tilt=$(( (f / 5) % 2 ))
    # the mast first, so the deck line overlaps its foot
    for (( n=1; n<=5; n++ )); do
        r=$(( hy - n ))
        (( r < 1 )) && break
        bgtable_sty 84 78 88 "$r"
        put "$r" $(( hx + 4 + n / 2 + tilt )) "$STY" "╲"
    done
    for n in 0 1 2; do
        r=$(( hy + n ))
        (( r < 1 || r > H-1 )) && continue
        bgtable_sty $(( 62 - n*8 )) $(( 58 - n*8 )) $(( 68 - n*8 )) "$r"
        put "$r" $(( hx + n * 2 - tilt )) "$STY" "${SINK_HULL[$n]}"
    done

    # what has come loose: crates and an empty ring, riding the swell
    for (( i=0; i<10; i++ )); do
        y=$(( wl + (i % 2) ))
        (( y < 1 || y > H-1 )) && continue
        x=$(( 1 + (i * 37 + i*i*11 + f / 3) % W ))
        if (( i % 3 == 0 )); then
            bgtable_sty 220 210 200 "$y"
            put "$y" "$x" "$STY" "◍"
        else
            bgtable_sty $(( 122 - (i % 4) * 14 )) $(( 92 - (i % 4) * 10 )) 68 "$y"
            put "$y" "$x" "$STY" "▬"
        fi
    done

    # air coming up where she is going under
    for (( i=0; i<16; i++ )); do
        y=$(( wl + (f / 3 + i * 3) % 3 ))
        (( y < 1 || y > H-1 )) && continue
        x=$(( hx + (i * 5 + f / 2) % 14 ))
        bgtable_sty 210 226 236 "$y"
        put "$y" "$x" "$STY" "∘"
    done

    top=$(( H/2 - 7 ))
    (( top < 1 )) && top=1
    if (( H >= 16 && W >= 70 )); then
        draw_big "$top" BANNER_FAIL 255 226 226  40 20 30
        top=$(( top + 6 ))
    else
        top=2
        msg="✗  BUILD FAILED"
        center ${#msg}
        sty_row 255 226 226 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 2 ))
    fi
    fail_details "$top"
}

# --------------------------------------------------------- fail scene: swamp --

# A build sunk in a swamp: green murk, dead trunks leaning in it, methane
# bubbling up through the surface and mist crawling over the top. Fireflies here
# are sickly, not friendly.
SWAMP_TRUNK=("▚" "▞" "▐" "▌")

scene_fail_swamp() {
    local f=$1 r t i x y top msg wl n g lum off tx
    wl=$(( H * 58 / 100 ))
    (( wl < 4 )) && wl=4
    (( wl > H-3 )) && wl=$(( H-3 ))
    BG_KIND=4
    if [ "$BG_KEY" != "swmp$H" ]; then
        bgtable_reset
        for (( r=1; r<=wl; r++ )); do
            t=$(( (r-1)*1000 / (wl>1 ? wl : 1) ))
            bgtable_row "$r" $(( 26 + 26*t/1000 )) $(( 34 + 34*t/1000 )) \
                             $(( 24 + 18*t/1000 ))
        done
        for (( r=wl+1; r<=H-1; r++ )); do
            t=$(( (r-wl)*1000 / (H-wl>0 ? H-wl : 1) ))
            bgtable_row "$r" $(( 34 - 12*t/1000 )) $(( 54 - 16*t/1000 )) \
                             $(( 30 - 10*t/1000 ))
        done
        BG_KEY="swmp$H"
    fi
    bgtable_paint

    # canopy overhead, hanging low and letting almost nothing through
    tile_of "▓▒▓░▒▓▒░" $(( W + 12 ))
    for (( r=1; r<=2 && r<=H-2; r++ )); do
        off=$(( (f / 8 + r * 4) % 8 ))
        bgtable_sty $(( 22 + r*6 )) $(( 44 + r*10 )) $(( 26 + r*4 )) "$r"
        put "$r" 1 "$STY" "${TILE:off:W}"
    done

    # dead trunks standing in the water, with vines hanging off them
    for i in 0 1 2 3 4; do
        tx=$(( 3 + (i * 43 + i*i*13) % (W - 4 > 1 ? W - 4 : 1) ))
        for (( r=3; r<=wl; r++ )); do
            bgtable_sty $(( 56 + i*4 )) $(( 48 + i*3 )) $(( 38 + i*2 )) "$r"
            put "$r" $(( tx + (r % 3 == 0 ? 1 : 0) )) "$STY" \
                "${SWAMP_TRUNK[$(( (r + i) % 4 ))]}"
        done
        for (( n=1; n<=4; n++ )); do
            r=$(( 3 + n ))
            (( r > wl )) && break
            bgtable_sty 62 92 54 "$r"
            put "$r" $(( tx + 2 + (${SIN[$(( (f + i*17 + n*9) % 60 ))]} - 500) / 500 )) \
                "$STY" "╷"
        done
        # what is left of it standing in its own reflection
        for (( r=wl+1; r<=wl+2 && r<=H-1; r++ )); do
            bgtable_sty $(( 40 + i*3 )) $(( 56 + i*3 )) 34 "$r"
            put "$r" "$tx" "$STY" "▒"
        done
    done

    # the surface: scum drifting in slow mats, with clear water between them
    tile_of "▒░     ░▒   ░    " $(( W + 20 ))
    for (( r=wl; r<=H-1; r++ )); do
        off=$(( (f / 5 + r * 7) % 17 ))
        lum=$(( 62 - (r - wl) * 5 )); (( lum < 24 )) && lum=24
        bgtable_sty "$lum" $(( lum + 30 )) $(( lum + 8 )) "$r"
        put "$r" 1 "$STY" "${TILE:off:W}"
    done
    # methane coming up through it and breaking
    for (( i=0; i<22; i++ )); do
        y=$(( wl + (f / 4 + i * 5) % (H - wl > 0 ? H - wl : 1) ))
        (( y < 1 || y > H-1 )) && continue
        x=$(( 1 + (i * 41 + i*i*7) % W ))
        g=$(( ${SIN[$(( (f*3 + i*13) % 60 ))]} ))
        bgtable_sty $(( 130 + g / 12 )) $(( 170 + g / 14 )) 110 "$y"
        if (( g > 600 )); then put "$y" "$x" "$STY" "○"
        else                   put "$y" "$x" "$STY" "∘"; fi
    done

    # mist crawling over the water in long thin bands
    tile_of "░░      ░     ░░    " $(( W + 24 ))
    for (( r=wl-1; r<=wl+2; r++ )); do
        (( r < 1 || r > H-1 )) && continue
        off=$(( (f * 2 / 3 + r * 7) % 20 ))
        bgtable_sty 120 140 124 "$r"
        put "$r" 1 "$STY" "${TILE:off:W}"
    done

    # sickly fireflies, blinking out of phase with each other
    for (( i=0; i<18; i++ )); do
        y=$(( 2 + (i * 3 + f / 6) % (wl > 2 ? wl - 1 : 1) ))
        x=$(( 1 + (i * 37 + i*i*11 + f / 4) % W ))
        (( ${SIN[$(( (f*3 + i*19) % 60 ))]} > 640 )) || continue
        bgtable_sty 180 210 90 "$y"
        put "$y" "$x" "$STY" "·"
    done

    top=$(( H/2 - 7 ))
    (( top < 1 )) && top=1
    if (( H >= 16 && W >= 70 )); then
        draw_big "$top" BANNER_FAIL 235 245 210  16 30 16
        top=$(( top + 6 ))
    else
        top=2
        msg="✗  BUILD FAILED"
        center ${#msg}
        sty_row 235 245 210 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 2 ))
    fi
    fail_details "$top"
}

# ---------------------------------------------------------- fail scene: rot ---

# Something left too long: a wall of grey-green mould creeping in from the edges
# in blooms that grow and merge, spores drifting off it, and damp running down
# behind. The blooms only ever take a handful of sizes, so each ring is one
# sliced tile rather than a distance test per cell.
ROT_CH=("▓" "▒" "░" "▪")
DAMP=""; DAMP_KEY=""

# The damp runs are fixed columns for a given window, so the whole set is
# rasterized once and replayed rather than re-put per frame.
build_damp() {
    local i r x save=$OUT
    OUT=""
    for (( i=0; i<8; i++ )); do
        x=$(( 2 + (i * 47 + i*i*13) % (W - 2 > 1 ? W - 2 : 1) ))
        for (( r=1; r<=H-1; r++ )); do
            bgtable_sty $(( 66 + (r % 3) * 5 )) $(( 62 + (r % 3) * 5 )) 50 "$r"
            put "$r" $(( x + (r / 5) % 2 )) "$STY" "▏"
        done
    done
    DAMP=$OUT
    OUT=$save
}

scene_fail_rot() {
    local f=$1 r t i x y top msg n g lum bx by rad k span
    BG_KIND=4
    if [ "$BG_KEY" != "rot$H" ]; then
        bgtable_reset
        for (( r=1; r<=H-1; r++ )); do
            t=$(( (r-1)*1000 / (H>1 ? H-1 : 1) ))
            bgtable_row "$r" $(( 44 + 22*t/1000 )) $(( 44 + 24*t/1000 )) \
                             $(( 36 + 16*t/1000 ))
        done
        BG_KEY="rot$H"
        DAMP_KEY=""                 # the streaks sit on this backdrop
    fi
    bgtable_paint

    # the damp itself: streaks running down the plaster behind everything
    [ "$DAMP_KEY" = "$H$W" ] || { build_damp; DAMP_KEY="$H$W"; }
    OUT+=$DAMP

    # nine blooms creeping out of the edges, each on its own slow growth cycle
    for (( i=0; i<9; i++ )); do
        # anchored on an edge, so the rot reads as coming in from outside
        case $(( i % 4 )) in
            0) bx=$(( 2 + (i * 17) % (W / 3 > 1 ? W / 3 : 1) ));      by=2 ;;
            1) bx=$(( W - 2 - (i * 13) % (W / 3 > 1 ? W / 3 : 1) ));  by=$(( H - 2 )) ;;
            2) bx=2;      by=$(( 2 + (i * 5) % (H - 3 > 1 ? H - 3 : 1) )) ;;
            *) bx=$(( W - 3 )); by=$(( 2 + (i * 7) % (H - 3 > 1 ? H - 3 : 1) )) ;;
        esac
        # the bloom is a filled diamond: each row is one span whose width falls
        # off with the distance from the centre row, so a row costs one write.
        # The glyphs are mixed along the span — one glyph per row would band.
        rad=$(( 1 + (f / 8 + i * 3) % 7 ))
        for (( r=by-rad; r<=by+rad; r++ )); do
            (( r < 1 || r > H-1 )) && continue
            n=$(( r - by )); (( n < 0 )) && n=$(( -n ))
            k=$(( rad - n ))                 # half-width of the span on this row
            lum=$(( 70 + k * 12 )); (( lum > 140 )) && lum=140
            bgtable_sty "$lum" $(( lum + 24 )) $(( lum - 20 )) "$r"
            span=""
            for (( t=-k; t<=k; t++ )); do
                # denser at the middle of the bloom, ragged at its edge
                span+="${ROT_CH[$(( (n + (t < 0 ? -t : t) + i) % 4 ))]}"
            done
            put "$r" $(( bx - k )) "$STY" "$span"
        done
        # the fruiting bodies at the heart of each bloom
        (( by >= 1 && by <= H-1 )) && {
            bgtable_sty 150 170 100 "$by"
            put "$by" "$bx" "$STY" "◉"
        }
    done

    # spores lifting off it and drifting up on the damp air
    for (( i=0; i<44; i++ )); do
        y=$(( H - 1 - (f / 3 + i * 5 + i/4) % (H - 1) ))
        (( y < 1 || y > H-1 )) && continue
        x=$(( 1 + (i * 31 + i*i*7) % W
                + (${SIN[$(( (f*2 + i*11) % 60 ))]} - 500) / 240 ))
        (( x < 1 || x > W )) && continue
        g=$(( 150 + ${SIN[$(( (f + i*17) % 60 ))]} * 70 / 1000 ))
        bgtable_sty "$g" $(( g + 20 > 255 ? 255 : g + 20 )) 120 "$y"
        if (( i % 3 )); then put "$y" "$x" "$STY" "·"
        else                 put "$y" "$x" "$STY" "˙"; fi
    done

    # drips coming off the bottom edge of the wall
    for (( i=0; i<9; i++ )); do
        y=$(( H - 3 + (f / 4 + i * 3) % 3 ))
        (( y < 1 || y > H-1 )) && continue
        x=$(( 2 + (i * 47 + i*i*5) % (W - 2 > 1 ? W - 2 : 1) ))
        bgtable_sty 140 160 130 "$y"
        put "$y" "$x" "$STY" "╷"
    done

    top=$(( H/2 - 7 ))
    (( top < 1 )) && top=1
    if (( H >= 16 && W >= 70 )); then
        draw_big "$top" BANNER_FAIL 240 236 210  24 30 20
        top=$(( top + 6 ))
    else
        top=2
        msg="✗  BUILD FAILED"
        center ${#msg}
        sty_row 240 236 210 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 2 ))
    fi
    fail_details "$top"
}

# ------------------------------------------------------------ scene picker ---

# Which variant is on screen is chosen when the state flips, not per frame —
# otherwise the scene would shuffle at 14fps. `pick_scene` never repeats the
# variant it last handed out for that state.
OK_VARIANTS=(scene_ok_meadow scene_ok_night scene_ok_fireworks
             scene_ok_aurora scene_ok_sunrise scene_ok_balloons
             scene_ok_rainbow scene_ok_reef scene_ok_confetti
             scene_ok_blossom scene_ok_orbit scene_ok_ripple
             scene_ok_lanterns scene_ok_fireflies scene_ok_zen
             scene_ok_wheat scene_ok_forest scene_ok_summit
             scene_ok_waterfall scene_ok_hearth scene_ok_train
             scene_ok_lighthouse scene_ok_kites scene_ok_carousel
             scene_ok_village scene_ok_desert scene_ok_window)
FAIL_VARIANTS=(scene_fail_pulse scene_fail_storm scene_fail_glitch
               scene_fail_lava scene_fail_matrix scene_fail_alarm
               scene_fail_wall scene_fail_vortex scene_fail_embers
               scene_fail_shatter scene_fail_swarm scene_fail_meltdown
               scene_fail_quake scene_fail_acid scene_fail_freeze
               scene_fail_flood scene_fail_wires scene_fail_sand
               scene_fail_rust scene_fail_tarpit scene_fail_derail
               scene_fail_avalanche scene_fail_hole scene_fail_locusts
               scene_fail_sinking scene_fail_swamp scene_fail_rot)
OK_PICK=0
FAIL_PICK=0

pick_scene() { # ok|fail
    local n step
    if [ "$1" = ok ]; then
        n=${#OK_VARIANTS[@]}
        step=$(( 1 + RANDOM % (n - 1) ))       # never 0, so never a repeat
        OK_PICK=$(( (OK_PICK + step) % n ))
    else
        n=${#FAIL_VARIANTS[@]}
        step=$(( 1 + RANDOM % (n - 1) ))
        FAIL_PICK=$(( (FAIL_PICK + step) % n ))
    fi
    BG_KEY=""       # the incoming variant rebuilds its own backdrop table
}

scene_ok()   { "${OK_VARIANTS[$OK_PICK]}" "$1"; }
scene_fail() { "${FAIL_VARIANTS[$FAIL_PICK]}" "$1"; }

# --list-scenes: the tables are the source of truth, so nothing to keep in sync
list_scenes() {
    local v
    echo "success scenes (--scene NAME):"
    for v in "${OK_VARIANTS[@]}"; do echo "  ${v#scene_ok_}"; done
    echo
    echo "failure scenes (--scene NAME, or fail:NAME to disambiguate):"
    for v in "${FAIL_VARIANTS[@]}"; do echo "  ${v#scene_fail_}"; done
}

# --scene NAME -> SCENE_STATE (ok|fail) plus the matching *_PICK index.
# A bare name is looked up in both tables; an "ok:"/"fail:" prefix, or the full
# function name, pins which table to search.
resolve_scene() { # name
    local want=$1 side="" i n
    case "$want" in
        ok:*)          side=ok;   want=${want#ok:} ;;
        fail:*)        side=fail; want=${want#fail:} ;;
        scene_ok_*)    side=ok;   want=${want#scene_ok_} ;;
        scene_fail_*)  side=fail; want=${want#scene_fail_} ;;
    esac
    if [ "$side" != fail ]; then
        n=${#OK_VARIANTS[@]}
        for (( i=0; i<n; i++ )); do
            if [ "${OK_VARIANTS[$i]#scene_ok_}" = "$want" ]; then
                SCENE_STATE=ok; OK_PICK=$i; return 0
            fi
        done
    fi
    if [ "$side" != ok ]; then
        n=${#FAIL_VARIANTS[@]}
        for (( i=0; i<n; i++ )); do
            if [ "${FAIL_VARIANTS[$i]#scene_fail_}" = "$want" ]; then
                SCENE_STATE=fail; FAIL_PICK=$i; return 0
            fi
        done
    fi
    return 1
}

# n/N in --scene mode: step through that state's table, wrapping round
step_scene() { # +1|-1
    local n
    if [ "$SCENE_STATE" = ok ]; then
        n=${#OK_VARIANTS[@]}
        OK_PICK=$(( (OK_PICK + $1 + n) % n ))
    else
        n=${#FAIL_VARIANTS[@]}
        FAIL_PICK=$(( (FAIL_PICK + $1 + n) % n ))
    fi
    BG_KEY=""       # the incoming variant rebuilds its own backdrop table
}

# the name currently on screen, for the status bar in --scene mode
scene_name() {
    if [ "$SCENE_STATE" = ok ]; then SCENE_NAME=${OK_VARIANTS[$OK_PICK]#scene_ok_}
    else SCENE_NAME=${FAIL_VARIANTS[$FAIL_PICK]#scene_fail_}
    fi
}

# ----------------------------------------------------------- building scene --

scene_building() {
    local f=$1 idx lvl
    idx=$(( (f * 2) % 60 ))
    lvl=${SIN[$idx]}
    BG_KIND=2; BG_LVL=$lvl
    if [ -z "${BLDBG[$idx]:-}" ]; then
        local s="" r
        for (( r=1; r<=H-1; r++ )); do
            bg_at "$r"
            s+=$'\033['"$r;1H"$'\033[39m\033[48;2;'"$BGR;$BGG;$BGB"m"$SPACES"
        done
        BLDBG[$idx]=$s
    fi
    OUT+=${BLDBG[$idx]}

    local top=$(( H/2 - 3 )) msg
    (( top < 1 )) && top=1
    if (( H >= 14 && W >= 52 )); then
        draw_big "$top" BANNER_BLD 255 $(( 200 + lvl/12 )) 150  60 30 0
        top=$(( top + 6 ))
    else
        msg="BUILDING…"
        center ${#msg}
        sty_row 255 220 160 "$top"
        put "$top" "$COL" $'\033[1m'"$STY" "$msg"
        top=$(( top + 2 ))
    fi
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' idx2=$(( (f/2) % 10 ))
    msg="${spin:idx2:1} cargo ${JOB}   ${ELAPSED}s"
    center ${#msg}
    sty_row 255 226 180 "$top"
    put "$top" "$COL" "$STY" "$msg"
}

# --------------------------------------------------------------- log pane ----

LOG_LINES=()
LOG_DIRTY=1

# one sed for the whole tail: bacon's own ANSI would otherwise fight ours.
# Throttled by the caller, so this pair of forks is not on every frame.
refresh_log() {
    local line
    LOG_LINES=()
    while IFS= read -r line; do
        LOG_LINES[${#LOG_LINES[@]}]=$line
    done < <(tail -n "$H" "$LOG" 2>/dev/null |
             LC_ALL=C sed $'s/\033\\[[0-9;?]*[a-zA-Z]//g; s/\r//g')
    LOG_DIRTY=0
}

LOG_STY=$'\033[38;2;205;210;220m\033[48;2;12;12;16m'
LOG_HDR=$'\033[38;2;150;150;170m\033[48;2;12;12;16m'

draw_log() { # first_row
    local top=$1 r line n=$(( H - $1 - 1 )) rule i start
    BG_KIND=0
    for (( r=top; r<=H-1; r++ )); do fill_row "$r" 12 12 16; done
    rule=$(( W > 20 ? W - 20 : 2 ))
    put "$top" 2 "$LOG_HDR" "── bacon output ${DASHES:0:rule}"
    (( n < 1 )) && return
    start=$(( ${#LOG_LINES[@]} - n ))
    (( start < 0 )) && start=0
    r=$(( top + 1 ))
    for (( i=start; i<${#LOG_LINES[@]}; i++ )); do
        (( r > H-1 )) && break
        line=${LOG_LINES[$i]}
        (( ${#line} > W-3 )) && line=${line:0:W-3}
        put "$r" 2 "$LOG_STY" "$line"
        r=$(( r + 1 ))
    done
}

draw_scene() {
    case "$STATE" in
        ok)       scene_ok "$FRAME" ;;
        fail)     scene_fail "$FRAME" ;;
        building) scene_building "$FRAME" ;;
    esac
}

# Draw the scene at a reduced height without recomputing the palette every
# frame: the gradients only get rebuilt when that height actually changes.
render_scene_at() { # height
    local save=$H
    H=$1
    (( SCENE_H != $1 )) && palette
    draw_scene
    H=$save
}

# -------------------------------------------------------------- status bar ---

status_bar() {
    local state=$1 sfg sbg icon
    case "$state" in
        ok)       icon="✓ passing";  sbg="20;110;50";  sfg="240;255;240" ;;
        fail)     icon="✗ failing";  sbg="150;24;30";  sfg="255;235;235" ;;
        building) icon="● building"; sbg="150;96;16";  sfg="255;240;220" ;;
    esac
    local warn=""
    (( WARNINGS > 0 )) && warn=" · ${WARNINGS} warning(s)"
    local left right
    if [ -n "${SCENE_STATE:-}" ]; then
        # preview mode: the scene name is the useful thing, not the build
        scene_name
        left=" ${PROJECT} │ preview │ ${icon} │ ${SCENE_NAME} "
        right=" q quit · n/N scene · p pause "
    else
        left=" ${PROJECT} │ ${JOB} │ ${icon}${warn} │ ${AGE}s ago "
        right=" q quit · 1-4 job · r rerun · l log · p pause "
    fi
    local pad=$(( W - ${#left} - ${#right} ))
    (( pad < 0 )) && { right=""; pad=$(( W - ${#left} )); }
    (( pad < 0 )) && pad=0
    OUT+=$'\033['"$H;1H"$'\033[38;2;'"$sfg"$'m\033[48;2;'"$sbg"$'m'"${left}${SPACES:0:pad}${right}"
}

# ------------------------------------------------------------------ main -----

# plain stdout, no terminal needed: safe to pipe or grep
(( LIST_SCENES )) && { list_scenes; exit 0; }

SCENE_STATE=""
if [ -n "$SCENE_ONLY" ]; then
    resolve_scene "$SCENE_ONLY" || {
        echo "unknown scene: $SCENE_ONLY" >&2
        echo "try --list-scenes" >&2
        exit 2
    }
fi

TTY=/dev/tty
if ! { : <"$TTY"; } 2>/dev/null; then
    echo "bacon-tui needs an interactive terminal" >&2
    exit 1
fi

trap cleanup EXIT INT TERM
trap on_winch WINCH

SAVED_STTY=$(stty -g <"$TTY")
stty -echo -icanon min 0 time 0 <"$TTY"   # non-blocking single-key reads

PROJECT=${PWD##*/}
ERRORS=0; WARNINGS=0; TEST_FAILS=0; CMD_ERROR=0; ITEMS=()
REPORT_MTIME=0; STAMP=$(now); AGE=0; ELAPSED=0; BUILD_START=$STAMP
VIEW=scene       # scene | split | log
PAUSED=0
FRAME=0
KEYS=""; BUILDING=1; STATE=building
PREV_STATE=building; OK_HOLD=0
# frames per OK_DELAY_MS, from the real cadence (sleep + per-frame overhead)
OK_DELAY_FRAMES=$(awk -v ms="$OK_DELAY_MS" -v s="$FRAME_SLEEP" -v o="$FRAME_OVERHEAD_MS" \
    'BEGIN{ n=int(ms / (s*1000 + o) + 0.5); if (n < 1) n = 1; print n }')
SCENE_H=0
PREV_OUT=""
REDRAW=1
# roll the first variant of each kind, so a run does not always open the same way
# (--scene already pinned its pick, so leave that one alone)
[ "$SCENE_STATE" = ok ]   || OK_PICK=$(( RANDOM % ${#OK_VARIANTS[@]} ))
[ "$SCENE_STATE" = fail ] || FAIL_PICK=$(( RANDOM % ${#FAIL_VARIANTS[@]} ))

printf '\033[?1049h\033[?25l\033[2J'
term_size
start_reader
if [ -n "$SCENE_STATE" ]; then
    # preview mode: no build to watch, so fake the state the scene wants. Fail
    # scenes draw a list of failing items, so give them something to show.
    STATE=$SCENE_STATE; PREV_STATE=$SCENE_STATE
    if [ "$SCENE_STATE" = fail ]; then
        ERRORS=3; WARNINGS=2; TEST_FAILS=1
        ITEMS=("cannot find value \`kettle\` in this scope"
               "  src/main.rs:42:9"
               "mismatched types: expected \`Scene\`, found \`Option<Scene>\`"
               "  src/render.rs:118:22"
               "unused variable: \`carousel\`"
               "  src/scene.rs:7:5")
    fi
else
    start_bacon
fi

while :; do
    (( RESIZED )) && { RESIZED=0; term_size; REDRAW=1; PREV_OUT=""; }

    # ---- poll state (cheap: only when the report actually changed) ----
    # In --scene mode there is no bacon and no report, so STATE is fixed and the
    # whole poll / hold / variant-roll block is skipped.
    if [ -z "$SCENE_STATE" ] && (( FRAME % POLL_EVERY == 0 )); then
        mt=$(stat -f %m "$REPORT" 2>/dev/null || echo 0)
        if [ "$mt" != "$REPORT_MTIME" ]; then
            REPORT_MTIME=$mt
            read_stats
            read_items
        fi
        STAMP=$(( EPOCH0 + SECONDS ))
        if [ "${REPORT_MTIME:-0}" -gt 0 ] 2>/dev/null; then
            AGE=$(( STAMP - REPORT_MTIME ))
            (( AGE < 0 )) && AGE=0
        else
            AGE=0
        fi
        BUILDING=0
        if [ ! -f "$REPORT" ]; then
            BUILDING=1
        elif find src Cargo.toml build.rs tests examples benches -newer "$REPORT" \
                  -print -quit 2>/dev/null | grep -q .; then
            BUILDING=1
        fi
        if (( BUILDING )); then
            (( ${BUILD_WAS:-0} == 0 )) && BUILD_START=$STAMP
            BUILD_WAS=1
            ELAPSED=$(( STAMP - BUILD_START ))
        else
            BUILD_WAS=0
        fi
        kill -0 "$BACON_PID" 2>/dev/null || { CMD_ERROR=1; ERRORS=1; }
    fi

    if [ -n "$SCENE_STATE" ]; then STATE=$SCENE_STATE
    elif (( BUILDING )); then STATE=building
    elif (( ERRORS > 0 || TEST_FAILS > 0 || CMD_ERROR )); then STATE=fail
    else STATE=ok
    fi

    # A pass is the one transition with a sound cue attached, so hold the
    # building scene for OK_DELAY_FRAMES before the grass-and-sky reveal —
    # the flip lands with the tail of the chime instead of ahead of it.
    # Failures and reruns cancel the pending reveal.
    if [ "$STATE" = ok ] && [ "$PREV_STATE" != ok ]; then
        OK_HOLD=$OK_DELAY_FRAMES
    elif [ "$STATE" != ok ]; then
        OK_HOLD=0
    fi
    # entering ok/fail rolls a fresh variant for that state
    if [ "$STATE" != "$PREV_STATE" ]; then
        case "$STATE" in
            ok)   pick_scene ok ;;
            fail) pick_scene fail ;;
        esac
    fi
    PREV_STATE=$STATE
    if (( OK_HOLD > 0 )); then
        OK_HOLD=$(( OK_HOLD - 1 ))
        STATE=building
        (( OK_HOLD == 0 )) && REDRAW=1     # clean slate for the reveal
    fi

    # ---- render ----
    case "$VIEW" in
        scene) : ;;
        *) (( LOG_DIRTY || FRAME % LOG_EVERY == 0 )) && refresh_log ;;
    esac

    OUT=""
    (( REDRAW )) && { OUT=$'\033[2J'; REDRAW=0; }
    case "$VIEW" in
        log) draw_log 1 ;;
        split)
            SPLIT_TOP=$(( H / 2 ))
            render_scene_at "$SPLIT_TOP"
            draw_log $(( SPLIT_TOP + 1 ))
            ;;
        *)  render_scene_at "$H" ;;
    esac
    status_bar "$STATE"

    # One synchronized write per frame: the terminal never shows a half-painted
    # scene. Identical frames (paused, idle) are not written at all.
    if [ "$OUT" != "$PREV_OUT" ]; then
        printf '\033[?2026h%s\033[?2026l' "$OUT"
        PREV_OUT=$OUT
    fi

    # ---- input ---- (bash 3.2 has no fractional `read -t`, so: sleep + drain)
    sleep "$FRAME_SLEEP"
    drain_keys
    for (( ki=0; ki<${#KEYS}; ki++ )); do
        key=${KEYS:ki:1}
        case "$key" in
            q|Q) cleanup ;;
            p|P) PAUSED=$(( 1 - PAUSED )) ;;
            # rerun, job switch and the log view all need a bacon behind them,
            # so in --scene mode n/N step through the scenes instead
            n) [ -n "$SCENE_STATE" ] && { step_scene 1; REDRAW=1; } ;;
            N) [ -n "$SCENE_STATE" ] && { step_scene -1; REDRAW=1; } ;;
            r|R) [ -n "$SCENE_STATE" ] || { start_bacon; REDRAW=1; } ;;
            l|L) [ -n "$SCENE_STATE" ] && continue
                 case "$VIEW" in
                     scene) VIEW=split ;;
                     split) VIEW=log ;;
                     *)     VIEW=scene ;;
                 esac
                 LOG_DIRTY=1; REDRAW=1 ;;
            1|2|3|4) [ -n "$SCENE_STATE" ] ||
                     { JOB=${JOBS[$(( key - 1 ))]}; start_bacon; REDRAW=1; } ;;
        esac
    done

    (( PAUSED )) || FRAME=$(( FRAME + 1 ))
done
