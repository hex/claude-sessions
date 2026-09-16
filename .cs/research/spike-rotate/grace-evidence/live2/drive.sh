#!/bin/bash
# throwaway: a real cs session with the force knob at 1%; one typed turn, then watch the mod rotate, count down, clear and wake
L="$1"; NAME=grace-live2
P=$(tmux new-window -t main -d -P -F '#{pane_id}' -n "$NAME" "env -u ANTHROPIC_API_KEY CS_ROTATE_FORCE_CTX=10 CS_ROTATE_BUTTON_CTX=1 CS_CLARIFY_DISABLE=1 cs $NAME"); echo "pane=$P" | tee "$L/pane.txt"
cap() { tmux capture-pane -p -t "$P" > "$L/$1.txt"; }
n=0; until tmux capture-pane -p -t "$P" | grep -q '^❯\|trust this folder\|Y/n'; do n=$((n+1)); [ $n -gt 240 ] && { echo "launch timeout"; cap 00-timeout; exit 1; }; perl -e 'select(undef,undef,undef,0.5)'; done
cap 00-launched
if tmux capture-pane -p -t "$P" | grep -q 'trust this folder'; then tmux send-keys -t $P Down Enter; perl -e 'select(undef,undef,undef,3)'; fi
perl -e 'select(undef,undef,undef,4)'; tmux send-keys -t $P 'reply with the single word ok' Enter; n=0; until tmux capture-pane -p -t $P | grep -q 'done [0-9]'; do n=$((n+1)); [ $n -gt 240 ] && break; perl -e 'select(undef,undef,undef,0.5)'; done; perl -e 'select(undef,undef,undef,3)'; cap 01-turn1; tmux send-keys -t $P 'read tests/test_hooks.sh and tests/test_install.sh in full with the Read tool, then reply with the single word ok' Enter
# poll every 3 s for 10 minutes; each snapshot keeps the band and composer lines, full capture on change of the band line
prev=""; t0=$(date +%s)
while [ $(( $(date +%s) - t0 )) -lt 600 ]; do
  now=$(( $(date +%s) - t0 )); full="$(tmux capture-pane -p -t "$P")"
  band="$(printf '%s\n' "$full" | grep -E '1: |/clear in|context' | sed 's/ *$//' | tail -3 | tr '\n' '|')"
  if [ "$band" != "$prev" ]; then printf '%4ds %s\n' "$now" "$band" >> "$L/timeline.txt"; printf '%s\n' "$full" > "$L/t$(printf %03d $now).txt"; prev="$band"; fi
  perl -e 'select(undef,undef,undef,3)'
done
echo "watch over; pane=$P"
