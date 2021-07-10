#version 410 core


uniform float fGlobalTime; // in seconds
uniform vec2 v2Resolution; // viewport resolution (in pixels)
uniform float fFrameTime; // duration of the last frame, in seconds

uniform sampler1D texFFT; // towards 0.0 is bass / lower freq, towards 1.0 is higher / treble freq
uniform sampler1D texFFTSmoothed; // this one has longer falloff and less harsh transients
uniform sampler1D texFFTIntegrated; // this is continually increasing
uniform sampler2D texPreviousFrame; // screenshot of the previous frame

layout(location = 0) out vec4 out_color; // out_color must be written in order to see anything


highp float rand(float seed)
{
    float shift=texture( texFFT, seed ).r;

    vec2 co=vec2(fGlobalTime+shift, fGlobalTime-shift);
    
    highp float a = 12.9898;
    highp float b = 78.233;
    highp float c = 43758.5453;
    highp float dt= dot(co.xy ,vec2(a,b));
    highp float sn= mod(dt,3.14);
    return fract(sin(sn) * c);
}


void main(void)
{
  // Translate XY coordinats to UV coordinats
	vec2 uv = vec2(gl_FragCoord.x / v2Resolution.x, gl_FragCoord.y / v2Resolution.y);
	uv /= vec2(v2Resolution.y / v2Resolution.x, 1);
  float sideFieldWidth=(v2Resolution.x-v2Resolution.y)/2; // Width in pixel
  float uvSideFieldWidth=(v2Resolution.y+sideFieldWidth)/v2Resolution.y-1;
	uv=uv-vec2(uvSideFieldWidth, 0);

  // Virtual horizontal line
  int lineTotal=100;

  vec4 color=vec4(0.0, 0.0, 0.0, 1.0);

  // Translate uv.y to screenY from 0 to lineTotal
  int screenY=int( uv.y*float(lineTotal) );

  if(screenY%2==0)
  {
    if(rand( (uv.x*uv.y) )> 0.5)
    {
  		color=vec4(0.8, 0.8, 1.0, 1.0);
  	}
  }

	out_color = color;
}