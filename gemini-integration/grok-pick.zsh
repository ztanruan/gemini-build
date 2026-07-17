# Launch-time Gemini model picker for Grok Build (arrow-key selector).
# Installed to ~/.grok/grok-pick.zsh; install.sh adds the source line to ~/.zshrc.
#
# Bare `grok` shows an interactive menu: Up/Down (or k/j) to move, Enter to
# choose, Esc or q to cancel. Any invocation WITH arguments (grok -p "...",
# grok -m <model>, grok models, ...) passes straight through unchanged.

grok() {
  # Pass through anything with args, and don't try to draw a menu when
  # stdin/stdout aren't a real terminal (pipes, CI, editors).
  if [[ $# -gt 0 || ! -t 0 || ! -t 1 ]]; then
    command grok "$@"
    return
  fi

  local -a ids labels
  # Current GA Gemini models on Vertex (July 2026). Keep in sync with config.toml.
  ids=(gemini-3.1-pro gemini-3.5-flash gemini-3.1-flash-lite gemini-2.5-pro)
  labels=(
    "Gemini 3.1 Pro          (flagship, best quality)"
    "Gemini 3.5 Flash        (fast, newest)"
    "Gemini 3.1 Flash-Lite   (cheapest, low latency)"
    "Gemini 2.5 Pro          (legacy, retires Oct 2026)"
  )
  local n=${#ids} sel=1 i key k2 k3

  # Always restore the cursor, even on Ctrl-C.
  trap 'printf "\e[?25h"' INT EXIT

  printf '\e[?25l'   # hide cursor
  print -r -- "Select a Gemini model  (↑/↓ move, Enter choose, Esc cancel):"
  for (( i=1; i<=n; i++ )); do print -r -- ""; done   # reserve n lines

  while true; do
    printf '\e[%dA' "$n"                 # jump back to first option
    for (( i=1; i<=n; i++ )); do
      printf '\e[2K'                     # clear the line
      if (( i == sel )); then
        printf '  \e[7m ▸ %s \e[0m\n' "${labels[i]}"   # highlighted row
      else
        printf '     %s\n' "${labels[i]}"
      fi
    done

    IFS= read -rsk1 key
    case "$key" in
      $'\n'|$'\r') break ;;                              # Enter -> confirm
      q|Q) sel=0; break ;;                               # cancel
      k|K) (( sel > 1 )) && (( sel-- )) || sel=$n ;;     # vim up (wrap)
      j|J) (( sel < n )) && (( sel++ )) || sel=1 ;;      # vim down (wrap)
      $'\e')
        IFS= read -rsk1 -t 0.3 k2 || { sel=0; break; }   # lone Esc -> cancel
        [[ "$k2" == "[" || "$k2" == "O" ]] || continue
        IFS= read -rsk1 -t 0.3 k3 || continue
        case "$k3" in
          A) (( sel > 1 )) && (( sel-- )) || sel=$n ;;   # up arrow
          B) (( sel < n )) && (( sel++ )) || sel=1 ;;    # down arrow
        esac
        ;;
    esac
  done

  printf '\e[?25h'   # show cursor
  trap - INT EXIT

  if (( sel == 0 )); then
    print -r -- "Cancelled."
    return 1
  fi

  local picked="${ids[sel]}"
  print -r -- "Starting Grok on ${picked} ..."
  command grok -m "$picked"
}
