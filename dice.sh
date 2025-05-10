# parse_expression() { local expr="$1"; local val=0; local op; local term; while IFS= read -r -d " " token; do term=$(parse_term "$token"); case "$op" in "+"|"") val=$((val + term)) ;; "-"*) val=$((val - term)) ;; esac; op=""; done <<< "$expr"; echo "$val"; }
# parse_term() { local token="$1"; local val=1; local op; local factor; while IFS= read -r -d " " token; do factor=$(parse_factor "$token"); case "$op" in "*"|"") val=$((val * factor)) ;; "/"*) val=$((val / factor)) ;; esac; op=""; done <<< "$token"; echo "$val"; }
# parse_factor() { local token="$1"; if [[ "$token" =~ ^[0-9]+$ ]]; then echo "$token"; elif [[ "$token" == "d" ]]; then echo "$((RANDOM % 6 + 1))"; else echo 1; fi; }
parse_expression() {
    local val=$(parse_term)
    while [[ $token == +||$token == - ]]; do
        local op=$token
        consume_token
        local right=$(parse_term)
        val=$(($val $op $right))
    done
    echo $val
}
parse_term() {
    local val=$(parse_exponent)
    while [[ $token == \*||$token == / ]]; do
        local op=$token
        consume_token
        local right=$(parse_exponent)
        val=$(($val $op $right))
    done
    echo $val
}
parse_exponent() {
    local val=$(parse_primary)
    while [[ $token == \^ ]]; do
        consume_token
        local right=$(parse_primary)
        val=$(($val ** $right))
    done
    echo $val
}
parse_primary() {
    if [[ $token == ( ]]; then
        consume_token
        local val=$(parse_expression)
        if [[ $token != ) ]]; then
            echo "Error: Expected )"
            exit 1
        fi
        consume_token
        echo $val
    elif [[ $token =~ [0-9]+ ]]; then
        consume_token
        echo $token
    else
        echo "Error: Unexpected token $token"
        exit 1
    fi
}
