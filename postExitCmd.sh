#!/bin/bash

echo "PostExitCmd running!"

cp "$1" "./shaderVariant/shader-$(date +%s).glsl"

