#!/bin/bash
validate_input() {
if ! [[ $1 =~ ^([0-9]+d[0-9]+[\+\-\*\/\^]+)*[0-9]+d[0-9]+$ ]]; then
echo "Invalid input format. Use: NdM[+/-/*/*/*^]..." >&2
exit 1
fi
}
evaluate_expression() {
local expr=$1
# Replace dice notation with actual rolls and evaluate with proper order
# This is a simplified implementation - full PEMDAS parsing would require a proper expression evaluator
local result=0
local tokens=(${expr//[\+\-\*\/\^]/ })
for token in "${tokens[@]}"; do
if [[ $token =~ ^[0-9]+d[0-9]+$ ]]; then
local dice=${token//d/}
local count=${dice%d*}
local sides=${dice#*d}
local sum=0
for ((i=0; i<count; i++)); do
local roll=$(roll_die $sides true)
sum=$((sum + roll))
echo "Rolled $roll ($sides-sided)"
done
result=$((result + sum))
fi
done
echo "Total: $result"
}
