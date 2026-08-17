#!/bin/bash
TEMP=$(cat /sys/class/thermal/thermal_zone0/temp)
echo "CPU Temperature: $(echo "scale=1; $TEMP/1000" | bc)°C"
