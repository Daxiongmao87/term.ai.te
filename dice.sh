if [[ $input =~ ^([0-9]+)d([0-9]+)(\+([0-9]+))? ]]; then
    num=${BASH_REMATCH[1]}
    sides=${BASH_REMATCH[2]}
    modifier=${BASH_REMATCH[4]:-0}
else
    echo "Invalid syntax: \$input" >&2
    exit 1
fi