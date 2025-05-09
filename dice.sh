#!/bin/bash
parse_expression() {
  local input="$1"
  local -a terms
  local IFS="+"
  local expr
  read -a terms <<< "$(echo "$input" | sed -E "s/([0-9]+d[0-9]+)/\\1/g")"
  for term in "${terms[@]}"; do
    expr+=$(roll_dice "$term")
  done
  echo "$expr"
}
roll_dice() {
  local die="$1"
  local -a parts
  local IFS="d"
  read -a parts <<< "$die"
  local count=${parts[0]}
  local sides=${parts[1]}
  local total=0
  for ((i=0; i<count; i++)); do
    local roll=$((RANDOM % sides + 1))
    total=$((total + roll))
    if ((roll == sides)); then
      total=$((total + $(roll_dice "$sides d $sides")))
    fi
  done
  echo "$total"
}
eval $(parse_expression "$@")
