#!/bin/bash
TEMP=$(cat /sys/class/thermal/thermal_zone0/temp)
echo "Temperatura da CPU: $(echo "scale=1; $TEMP/1000" | bc)°C"
