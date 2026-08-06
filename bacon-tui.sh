#!/bin/bash
# bacon-tui.sh — animated terminal dashboard for bacon
#
#   ./bacon-tui.sh [job]        # job defaults to `check`
#
# It runs `bacon --headless` for you, telling bacon to auto-export a machine
# readable report after every mission (`[exports.json_report]`), and tails
# bacon's own output into a log file. The report drives the animation:
#
#   errors / test failures  ->  red pulse, fading red -> black -> red
#   clean                   ->  lush green sunny day (sun, clouds, birds, cat)
#   compiling               ->  amber shimmer
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
#   1 fail pulse (formula)  2 building pulse (formula)  3 sky/hill  0 flat
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

scene_ok() {
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

# -------------------------------------------------------------- fail scene ---

# The pulse only ever takes 60 discrete levels, so the whole backdrop for a
# level is built once and replayed from FAILBG afterwards.
scene_fail() {
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
    local head
    if (( TEST_FAILS > 0 )); then
        head="$ERRORS error(s) · $TEST_FAILS test failure(s)"
    else
        head="$ERRORS error(s)"
    fi
    center ${#head}
    sty_row 255 190 190 "$top"
    put "$top" "$COL" "$STY" "$head"
    local bar=$(( W * 2 / 3 ))
    center "$bar"
    sty_row 150 40 40 $(( top + 1 ))
    put $(( top + 1 )) "$COL" "$STY" "${DASHES:0:bar}"
    # failing items, indented under the banner
    local i n=0 line row max=$(( H - top - 3 ))
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
