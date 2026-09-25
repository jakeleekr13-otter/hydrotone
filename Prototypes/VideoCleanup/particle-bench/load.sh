#!/bin/zsh
# Prints the busiest other processes, so each timing can be read with the machine load next to it.
echo "load: $(ps -Ao pcpu,comm | sort -nr | sed -n 2,4p | awk '{printf "%s%% %s; ", $1, $2}')"
