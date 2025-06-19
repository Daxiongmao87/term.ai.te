#!/bin/bash

str="Hello World"
colors=(31 32 33 34 35 36) # ANSI color codes for rainbow colors

for ((i=0; i<${#str}; i++)); do
    color=${colors[i%6]} # Cycle through the colors
    echo -ne "\e[$colorm${str:$i:1}\e[0m"
done
echo
