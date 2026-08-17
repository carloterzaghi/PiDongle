#!/bin/bash
# Pisca o LED interno (ACT) 5 vezes
LED=/sys/class/leds/ACT/brightness
for i in $(seq 1 5); do
    echo 0 > "$LED"
    sleep 0.3
    echo 1 > "$LED"
    sleep 0.3
done
echo "LED blinked 5 times."
