#version 410 core


uniform float fGlobalTime; // in seconds
uniform vec2 v2Resolution; // viewport resolution (in pixels)
uniform float fFrameTime; // duration of the last frame, in seconds

uniform sampler1D texFFT; // towards 0.0 is bass / lower freq, towards 1.0 is higher / treble freq
uniform sampler1D texFFTSmoothed; // this one has longer falloff and less harsh transients
uniform sampler1D texFFTIntegrated; // this is continually increasing
uniform sampler2D texPreviousFrame; // screenshot of the previous frame

layout(location = 0) out vec4 out_color; // out_color must be written in order to see anything


// const int MAXSAMPLES=4;

// ----------------
// Random generator
// ----------------

// A single iteration of Bob Jenkins' One-At-A-Time hashing algorithm.
uint hash( uint x ) {
    x += ( x << 10u );
    x ^= ( x >>  6u );
    x += ( x <<  3u );
    x ^= ( x >> 11u );
    x += ( x << 15u );
    return x;
}

// Compound versions of the hashing algorithm I whipped together.
uint hash( uvec2 v ) { return hash( v.x ^ hash(v.y)                         ); }
uint hash( uvec3 v ) { return hash( v.x ^ hash(v.y) ^ hash(v.z)             ); }
uint hash( uvec4 v ) { return hash( v.x ^ hash(v.y) ^ hash(v.z) ^ hash(v.w) ); }

// Construct a float with half-open range [0:1] using low 23 bits.
// All zeroes yields 0.0, all ones yields the next smallest representable value below 1.0.
float floatConstruct( uint m ) {
    const uint ieeeMantissa = 0x007FFFFFu; // binary32 mantissa bitmask
    const uint ieeeOne      = 0x3F800000u; // 1.0 in IEEE binary32

    m &= ieeeMantissa;                     // Keep only mantissa bits (fractional part)
    m |= ieeeOne;                          // Add fractional part to 1.0

    float  f = uintBitsToFloat( m );       // Range [1:2]
    return f - 1.0;                        // Range [0:1]
}

// Pseudo-random value in half-open range [0:1].
float rand( float x ) { return floatConstruct(hash(floatBitsToUint(x+fGlobalTime))); }
float rand( vec2  v ) { return floatConstruct(hash(floatBitsToUint(v+fGlobalTime))); }
float rand( vec3  v ) { return floatConstruct(hash(floatBitsToUint(v+fGlobalTime))); }
float rand( vec4  v ) { return floatConstruct(hash(floatBitsToUint(v+fGlobalTime))); }


// -----------------------
// Basic 2D transformation
// -----------------------

const mat4 identityMatrix=mat4(vec4(1,0,0,0), vec4(0,1,0,0), vec4(0,0,1,0), vec4(0,0,0,1));

mat4 get2DTranslateMatrix(float x, float y)
{
	mat4 result=identityMatrix;
	result[3][0]=x;
	result[3][1]=y;
	return result;
}

mat4 get2DScaleMatrix(float x, float y)
{
	mat4 result=identityMatrix;
	result[0][0]=x;
	result[1][1]=y;
	return result;
}

mat4 get2DRotateMatrix(float a)
{
	mat4 result=identityMatrix;
	float sinA=sin(a);
	float cosA=cos(a);
	
	result[0][0]=cosA;
	result[0][1]=sinA;
	result[1][0]=-sinA;
	result[1][1]=cosA;
	return result;
}


vec4 wavePlate(vec2 position, float maxRadius, float waveLen, vec2 focusShift, float angle)
{
  // Center of plate and rotate center
  vec2 center=vec2(0.5);

  // Rotate
  mat4 matPlateRotate=get2DTranslateMatrix(center.x, center.y)*
                      get2DRotateMatrix(fGlobalTime)*
                      inverse(get2DScaleMatrix(1, 0.5))*
                      inverse(get2DTranslateMatrix(center.x, center.y));

  vec4 afterRotatePos=vec4(position.x, position.y, 0, 1);
  afterRotatePos=matPlateRotate*afterRotatePos;

	position=vec2(afterRotatePos.x, afterRotatePos.y);

  // Small mix random by coordinats
  position.x=position.x+sin(rand(position.x*position.y))/500.0;
  position.y=position.y+cos(rand(position.x/position.y))/500.0;
  
  float len1=length(position - center);

  if(len1>maxRadius)
  {
   	return vec4(0.0, 0.0, 0.0, 0.0); // Transparent color
  }

  float c1=sin(len1/waveLen);
  
  float len2=length(position + focusShift - center);
  float c2=sin(len2/waveLen);
  
  float c=(c1+c2)/4.0-0.1; // Sybstract for saturation control, best diapason  0.1...0.2

  // Small mix random by color
  // c=c-0.1+rand(position.x*position.y)/10;
  
  return vec4(c, c, c, 1.0);
}


float sdTorus( vec3 p, vec2 t ) {
    vec2 q = vec2(length(p.xy)-t.x,p.z);
    return length(q)-t.y;
}

float sdSphere(vec3 p, float r) {
	return length(p) - r;
}

float scene( vec3 p ) {
    float rt = sdTorus(p, vec2(1.0, 0.5) );
    
    vec3 ps = p - vec3( sin(fGlobalTime) * 0.6 , 0., 0.5);
    float rs = sdSphere(ps, 0.9);
    return min(rt, rs);
}


void main(void)
{
  // Translate XY coordinats to UV coordinats
	vec2 uvPosition = vec2(gl_FragCoord.x / v2Resolution.x, gl_FragCoord.y / v2Resolution.y);
	uvPosition /= vec2(v2Resolution.y / v2Resolution.x, 1);
  float sideFieldWidth=(v2Resolution.x-v2Resolution.y)/2; // Width in pixel
  float uvSideFieldWidth=(v2Resolution.y+sideFieldWidth)/v2Resolution.y-1;
	uvPosition=uvPosition-vec2(uvSideFieldWidth, 0);

  
  // float polarX=sin(uvPosition.x/uvPosition.y+fGlobalTime)/2.0;
  // float polarY=cos(uvPosition.x/uvPosition.y+fGlobalTime)/2.0;
  // uvPosition=vec2(polarX, polarY);
  
  
  vec2 focusShift=vec2( sin(fGlobalTime)/650+1.0/650.0*4, 0.001);
   
  int maxNum=3;
  float pi=3.1415926535897932384626433832795;
  vec4 acc = vec4(vec3(0.0), 1.0);
  for (int num = 0; num < maxNum; num++)
  {
    // todo: Try adding randVec to uvPosition
    // vec2 randVec=vec2(sin(rand(fGlobalTime+num))/1000.0, sin(rand(fGlobalTime+num*num))/1000.0);
    acc += wavePlate(uvPosition, 0.4, 0.00061, focusShift, fGlobalTime);
  }

  gl_FragColor = vec4(acc.rgb * (1.0 / float(maxNum)), 1.0);

  
  // gl_FragColor = wavePlate(uvPosition, 0.4, 0.0007, focusShift);
}
