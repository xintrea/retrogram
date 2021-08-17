#!/bin/bash

# export MESA_GL_VERSION_OVERRIDE=4.1
# export MESA_GLSL_VERSION_OVERRIDE=410


echo "Start music"
vlc --intf dummy --play-and-exit ./sound/klaudia_blue_shawl.mp3 &

echo "Start Bonzomatic"
./bonzomatic

echo "Stop music"
kill %1

