#!/bin/bash

echo "Start music"
vlc --intf dummy --play-and-exit ./sound/klaudia_blue_shawl.mp3 &

echo "Start Bonzomatic"
./bonzomatic

echo "Stop music"
kill %1

