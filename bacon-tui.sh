#!/bin/bash
# bacon-tui.sh — animated terminal dashboard for bacon
#
#   ./bacon-tui.sh [job]        # job defaults to `check`
#
# It runs `bacon --headless` for you, telling bacon to auto-export a machine
# readable report after every mission (`[exports.json_report]`), and tails
# bacon's own output into a log file. The report drives the animation:
#
#   errors / test failures  ->  one of six fail scenes, picked at random
#                               (red pulse · thunderstorm · signal glitch ·
#                                lava · matrix rain · alarm klaxon)
#   clean                   ->  one of six success scenes, picked at random
#                               (sunny meadow · starry night · fireworks ·
#                                aurora · sunrise at sea · balloons)
#   compiling               ->  amber shimmer
#
# A fresh variant is drawn each time the state flips, and never the same one
# twice in a row.
#
# Keys: q quit · 1-4 switch job · r rerun · l cycle log view · p pause anim
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
JOB=${1:-check}
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

command -v bacon >/dev/null 2>&1 || { echo "bacon not found in PATH" >&2; exit 1; }

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

# ------------------------------------------------------------ scene picker ---

# Which variant is on screen is chosen when the state flips, not per frame —
# otherwise the scene would shuffle at 14fps. `pick_scene` never repeats the
# variant it last handed out for that state.
OK_VARIANTS=(scene_ok_meadow scene_ok_night scene_ok_fireworks
             scene_ok_aurora scene_ok_sunrise scene_ok_balloons)
FAIL_VARIANTS=(scene_fail_pulse scene_fail_storm scene_fail_glitch
               scene_fail_lava scene_fail_matrix scene_fail_alarm)
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
    local left=" ${PROJECT} │ ${JOB} │ ${icon}${warn} │ ${AGE}s ago "
    local right=" q quit · 1-4 job · r rerun · l log · p pause "
    local pad=$(( W - ${#left} - ${#right} ))
    (( pad < 0 )) && { right=""; pad=$(( W - ${#left} )); }
    (( pad < 0 )) && pad=0
    OUT+=$'\033['"$H;1H"$'\033[38;2;'"$sfg"$'m\033[48;2;'"$sbg"$'m'"${left}${SPACES:0:pad}${right}"
}

# ------------------------------------------------------------------ main -----

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
OK_PICK=$(( RANDOM % ${#OK_VARIANTS[@]} ))
FAIL_PICK=$(( RANDOM % ${#FAIL_VARIANTS[@]} ))

printf '\033[?1049h\033[?25l\033[2J'
term_size
start_reader
start_bacon

while :; do
    (( RESIZED )) && { RESIZED=0; term_size; REDRAW=1; PREV_OUT=""; }

    # ---- poll state (cheap: only when the report actually changed) ----
    if (( FRAME % POLL_EVERY == 0 )); then
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

    if (( BUILDING )); then STATE=building
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
            r|R) start_bacon; REDRAW=1 ;;
            l|L) case "$VIEW" in
                     scene) VIEW=split ;;
                     split) VIEW=log ;;
                     *)     VIEW=scene ;;
                 esac
                 LOG_DIRTY=1; REDRAW=1 ;;
            1|2|3|4) JOB=${JOBS[$(( key - 1 ))]}; start_bacon; REDRAW=1 ;;
        esac
    done

    (( PAUSED )) || FRAME=$(( FRAME + 1 ))
done
