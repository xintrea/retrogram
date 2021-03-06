#version 420 core

out vec4 FragColor;
                 
uniform float fGlobalTime;// in seconds
uniform vec2 v2Resolution;// viewport resolution (in pixels)
uniform float fFrameTime;// duration of the last frame, in seconds

uniform sampler1D texFFT;// towards 0.0 is bass / lower freq, towards 1.0 is higher / treble freq
uniform sampler1D texFFTSmoothed;// this one has longer falloff and less harsh transients
uniform sampler1D texFFTIntegrated;// this is continually increasing
uniform sampler2D texPreviousFrame;// screenshot of the previous frame

uniform sampler2D textureGrammophonePlate;
uniform sampler2D textureSkinBlack;
uniform sampler2D textureKingpin;
uniform sampler2D textureHead;
uniform sampler2D textureLabel;
uniform sampler2D textureShadowKingpin;
uniform sampler2D textureShadowHead;
uniform sampler2D textureBackground;
uniform sampler2D textureForeground;
uniform sampler2D textureNote1;
uniform sampler2D textureNote2;
uniform sampler2D textureNote3;
uniform sampler2D textureNote4;

const float PI=3.1415926535897932384626433832795;
const float E=2.7182818284;

const int   RAY_MARCH_MAX_STEPS=100;
const float RAY_MARCH_MAX_DIST=100.0;
const float RAY_MARCH_SURF_DIST=0.001;

struct CylinderType
{
    float r;
    float bottomHeight;
    float topHeight;
    float chamfer;
};

CylinderType cylinderRayMarch=CylinderType( 0.0, 0.0, 0.0, 0.0 );
const CylinderType objectGrammophonePlate=CylinderType( 1.0, 0.0, 0.05, 0.01 );
const CylinderType objectWavePlate=CylinderType( 0.93, 0.05, 0.0548, 0.003 ); // ( 0.97, 0.05, 0.0548, 0.003 )
const CylinderType objectKingpin=CylinderType( 0.02, 0.0548, 0.09, 0.008 ); // ( 0.02, 0.0548, 0.09, 0.008 )


const int TEXTURE_GRAMMOPHONE_PLATE=1;
const int TEXTURE_GRAMMOPHONE_ROUND=2;
const int TEXTURE_WAVE_PLATE=3;
const int TEXTURE_WAVE_ROUND=4;
const int TEXTURE_KINGPIN=5;

const vec4 TEXTURE_GAMMA_CORRECTION=vec4(1/2.0);

struct NoteType
{
    int figure; // Note picture type
    vec3 color;

    float freq;
    float secondFreq;

    float phase;
    float secondPhase;

    float amp;
    float secondAmp;

    float timeSpeedFactor;
    float sizeUpFactor;
    float axeYShift;
};

#define NOTE_COUNT 32
NoteType notes[NOTE_COUNT];


// ----------------
// Random generator
// ----------------

// A single iteration of Bob Jenkins' One-At-A-Time hashing algorithm.
uint hash(uint x){
    x+=(x<<10u);
    x^=(x>>6u);
    x+=(x<<3u);
    x^=(x>>11u);
    x+=(x<<15u);
    return x;
}

// Compound versions of the hashing algorithm I whipped together.
uint hash(uvec2 v){return hash(v.x^hash(v.y));}
uint hash(uvec3 v){return hash(v.x^hash(v.y)^hash(v.z));}
uint hash(uvec4 v){return hash(v.x^hash(v.y)^hash(v.z)^hash(v.w));}

// Construct a float with half-open range [0:1] using low 23 bits.
// All zeroes yields 0.0, all ones yields the next smallest representable value below 1.0.
float floatConstruct(uint m){
    const uint ieeeMantissa=0x007FFFFFu;// binary32 mantissa bitmask
    const uint ieeeOne=0x3F800000u;// 1.0 in IEEE binary32
    
    m&=ieeeMantissa;// Keep only mantissa bits (fractional part)
    m|=ieeeOne;// Add fractional part to 1.0
    
    float f=uintBitsToFloat(m);// Range [1:2]
    return f-1.;// Range [0:1]
}

// Pseudo-random value in half-open range [0:1].
float rand(float x){return floatConstruct(hash(floatBitsToUint(x+fGlobalTime)));}
float rand(vec2 v){return floatConstruct(hash(floatBitsToUint(v+fGlobalTime)));}
float rand(vec3 v){return floatConstruct(hash(floatBitsToUint(v+fGlobalTime)));}
float rand(vec4 v){return floatConstruct(hash(floatBitsToUint(v+fGlobalTime)));}

float determineRand(float x){return floatConstruct(hash(floatBitsToUint(x)));}


// -----------------------
// Basic 2D transformation
// -----------------------

const mat4 identityMatrix=mat4(vec4(1,0,0,0),vec4(0,1,0,0),vec4(0,0,1,0),vec4(0,0,0,1));

mat4 get2DTranslateMatrix(float x,float y)
{
    mat4 result=identityMatrix;
    result[3][0]=x;
    result[3][1]=y;
    return result;
}

mat4 get2DScaleMatrix(float x,float y)
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


float getAngle(float x, float y)
{
    float alpha=atan( abs(y/x) );

    if(x>=0 && y>=0)
    {
        return alpha;
    }

    if(x<0 && y>=0)
    {
        return PI-alpha;
    }

    if(x<0 && y<0)
    {
        return PI+alpha;
    }

    return 2.0*PI-alpha;
}


// -------------
// SDF 3D figure
// -------------


// Cone with correct distances to tip and base circle. Y is up, 0 is in the middle of the base.
float fCone(vec3 p, float radius, float height) {
    vec2 q = vec2(length(p.xz), p.y);
    vec2 tip = q - vec2(0, height);
    vec2 mantleDir = normalize(vec2(height, radius));
    float mantle = dot(tip, mantleDir);
    float d = max(mantle, -q.y);
    float projected = dot(tip, vec2(mantleDir.y, -mantleDir.x));

    // distance to tip
    if ((q.y > height) && (projected < 0)) {
        d = max(d, length(tip));
    }

    // distance to base ring
    if ((q.x > radius) && (projected > length(vec2(height, radius)))) {
        d = max(d, length(q - vec2(radius, 0)));
    }
    return d;
}


float sdCylinder(vec3 p, 
                 float r, 
                 float bottomHeight, 
                 float topHeight,
                 float chamfer) 
{
    // todo: chamfer not using, try add support chamfer

    // Distance to point in xz plane
    float distanceXZ = length(p.xz) - r;

    // Distance to point in Y axis
    float distanceY = p.y - topHeight; // Optimisation. By defaul calculate distance for area from topHeight to +inf

    if(p.y < bottomHeight) // For area from bottomHeight to -inf
    {
        distanceY = bottomHeight-p.y;
    }

    float cylinderDistance = max(distanceXZ, distanceY);
    // float cylinderDistance=0;


    // Cone for exclude chamfer volume
    float coneHeight = topHeight+(r-chamfer);
    float coneR = coneHeight; // 45 degree cone
    float coneDistance=fCone( p, coneR, coneHeight);


    return max(cylinderDistance, coneDistance);
}


// -------------------
// Ray march functions
// -------------------

float GetDist(vec3 p) 
{
    float distance = sdCylinder(p, 
                                cylinderRayMarch.r, 
                                cylinderRayMarch.bottomHeight, 
                                cylinderRayMarch.topHeight,
                                cylinderRayMarch.chamfer);
    
    return distance;
}


float RayMarch(vec3 ro, vec3 rd) {
    float dO=0.;
    
    for(int i=0; i<RAY_MARCH_MAX_STEPS; i++) 
    {
    	vec3 p = ro + rd*dO;
        float dS = GetDist(p);
        dO += dS;
        if(dO>RAY_MARCH_MAX_DIST || abs(dS)<RAY_MARCH_SURF_DIST)
        {
            break;
        }
    }
    
    return dO;
}

vec3 GetNormal(vec3 p) {
    float d = GetDist(p);
    vec2 e = vec2(.001, 0);
    
    vec3 n = d - vec3(
        GetDist(p-e.xyy),
        GetDist(p-e.yxy),
        GetDist(p-e.yyx));
    
    return normalize(n);
}


float GetLight(vec3 p)
{ 
    // Directional light
    // vec3 lightPos = vec3(5.*sin(fGlobalTime),5.,5.0*cos(fGlobalTime)); // Light Position
    vec3 lightPos = vec3(0., 5., 5.); // Light Position vec3(5.,5.,5.)
    vec3 l = normalize(lightPos-p); // Light Vector
    vec3 n = GetNormal(p); // Normal Vector
   
    float dif = dot(n, l); // Diffuse light
    dif = clamp(dif, 0., 1.); // Clamp so it doesnt go below 0

    return dif;
}


vec3 GetRayDir(vec2 uv, vec3 p, vec3 l, float z) {
    vec3 f = normalize(l-p),
        r = normalize(cross(vec3(0,1,0), f)),
        u = cross(f,r),
        c = f*z,
        i = c + uv.x*r + uv.y*u,
        d = normalize(i);
    return d;
}


// Calculate camera direction normalize vector
// ro - ray origin, point in 3D space of camera position
// target - point in 3D space of camera view to
// uv - current pixel coordinates
vec3 cameraDirection (vec3 ro, vec3 target, vec2 uv) {
    vec3 f = normalize(target-ro);
    vec3 l = normalize(cross(vec3(0.,1.,0.),f));
    vec3 u = normalize(cross(f,l));
    return normalize(f + l*uv.x + u*uv.y);
}


// ------------------
// Wave plate drawing
// ------------------

vec4 wavePlate(vec2 uvPixelPosition, float maxRadius, float waveLen, vec2 focusShift, float angle)
{
    // Center of plate and rotate center
    vec2 center=vec2(0.0, 0.0); // vec2(.5, 0.38);

    float scaleX=1.0;
    float scaleY=1.0;
    
    // Rotate
    mat4 matPlateRotate=get2DTranslateMatrix(center.x, center.y)*
    get2DRotateMatrix( (sin(fGlobalTime*0.5)-1.0)*0.000001 )*
    inverse(get2DScaleMatrix(scaleX, scaleY))*
    inverse(get2DTranslateMatrix(center.x, center.y));
    
    vec4 afterRotatePos=vec4(uvPixelPosition.x, uvPixelPosition.y, 0.0, 1.0);
    afterRotatePos=matPlateRotate*afterRotatePos;
    
    // Update uvPixelPosition by rotate position
    uvPixelPosition=vec2(afterRotatePos.x, afterRotatePos.y);
    
    // Small mix random by coordinats
    uvPixelPosition.x=uvPixelPosition.x+sin(rand(uvPixelPosition.x*uvPixelPosition.y))/500.0;
    uvPixelPosition.y=uvPixelPosition.y+cos(rand(uvPixelPosition.x/uvPixelPosition.y))/500.0;
    
    float len1=length(uvPixelPosition-center);
    
    if(len1>maxRadius-0.002) // Constant 0.0002 for not show random wave pixel at bottom plate
    {
        return vec4(0.0, 0.0, 0.0, 0.0); // Transparent color
    }
    
    float c1=sin(len1/waveLen);
    
    float len2=length(uvPixelPosition+focusShift-center);
    float c2=sin(len2/waveLen);
    
    float c=(c1+c2)/4.0+0.05; // Sybstract for saturation control, best diapason  0.1...0.2
    
    // Small mix random by color
    // c=c-0.1+rand(uvPixelPosition.x*uvPixelPosition.y)/10;
    
    return vec4( vec3( clamp(c, 0.0, 1.0) ), 1.0);
}

vec4 textureWavePlate(vec2 uvPixelPosition)
{
    // Wave form
    vec2 focusShift=vec2(sin(fGlobalTime)/650.0+1.0/650.0*4.0, 0.001);
    
    int maxNum=1;
    vec4 acc=vec4(vec3(0.0), 1.0); // Accumulator
    for(int num=0; num<maxNum; num++)
    {
        // todo: Try adding randVec to uvPixelPosition
        // vec2 randVec=vec2(sin(rand(fGlobalTime+num))/1000.0, sin(rand(fGlobalTime+num*num))/1000.0);
        acc+=wavePlate(uvPixelPosition, objectWavePlate.r, 0.00085, focusShift, fGlobalTime);
    }
    acc=vec4(acc.rgb*(1.0/float(maxNum)), 1.0);


    // Label
    mat4 transformMat = get2DTranslateMatrix(0.5, 0.5) * get2DScaleMatrix(0.79, 0.79); // 0.95
    vec2 uv = ( transformMat * vec4(uvPixelPosition.x, uvPixelPosition.y, 0.0, 1.0) ).xy;
    vec4 textureColor=vec4(vec3(0.0), 0.0);
    if(uv.x>=0.0 && uv.x<=1.0 && uv.y>=0.0 && uv.y<=1.0)
    {
        textureColor = texture(textureLabel, vec2(uv.x, uv.y) );
    }
    
    return vec4( mix(acc.rgb, textureColor.rgb, textureColor.a), 1.0);
}


vec4 showHead(vec2 uvPixelPosition)
{
    // Small Lissage shift
    float firstHarmonicX = (sin(fGlobalTime*0.7)/2)*0.005;
    float firstHarmonicY = (cos(fGlobalTime*0.7)/2)*0.009;
    float shiftX = (firstHarmonicX + (sin(fGlobalTime)/2)*0.0097)/2.0;
    float shiftY = (firstHarmonicY + (cos(fGlobalTime)/2)*0.0057)/2.0;

    mat4 transformMat = get2DScaleMatrix(1.2, 1.2*2) * get2DTranslateMatrix(-0.72+shiftX, 0.74+shiftY);

    vec2 uv = ( transformMat * vec4(uvPixelPosition.x, -uvPixelPosition.y, 0.0, 1.0) ).xy;

    vec4 textureColor=vec4(0.0);

    if(uv.x>=0.0 && uv.x<=1.0 && uv.y>=0 && uv.y<=1.0)
    {
        textureColor = pow( texture(textureHead, uv ), TEXTURE_GAMMA_CORRECTION );
    }

    return textureColor;
}


vec4 showShadowKingpin(vec2 uvPixelPosition)
{
    mat4 transformMat = get2DScaleMatrix(10.0, 10.0) * get2DTranslateMatrix(-0.462, 0.535);

    vec2 uv = ( transformMat * vec4(uvPixelPosition.x, -uvPixelPosition.y, 0.0, 1.0) ).xy;

    vec4 textureColor=vec4(0.0);

    if(uv.x>=0.0 && uv.x<=1.0 && uv.y>=0 && uv.y<=1.0)
    {
        textureColor = pow( texture(textureShadowKingpin, uv ), TEXTURE_GAMMA_CORRECTION );
    }

    return textureColor;
}


vec4 showShadowHead(vec2 uvPixelPosition)
{
    // Small Lissage shift with coefficient as showHead
    float firstHarmonicX = (sin(fGlobalTime*0.7)/2)*0.005;
    float firstHarmonicY = (cos(fGlobalTime*0.7)/2)*0.009;
    float shiftX = (firstHarmonicX + (sin(fGlobalTime)/2)*0.0097)/2.0 / 2.0; 
    float shiftY = (firstHarmonicY + (cos(fGlobalTime)/2)*0.0057)/2.0 / 2.0;

    mat4 transformMat = get2DScaleMatrix(1.6, 1.6*4) * get2DTranslateMatrix(-0.745+shiftX, 0.356+shiftY);

    vec2 uv = ( transformMat * vec4(uvPixelPosition.x, -uvPixelPosition.y, 0.0, 1.0) ).xy;

    vec4 textureColor=vec4(0.0);

    if(uv.x>=0.0 && uv.x<=1.0 && uv.y>=0 && uv.y<=1.0)
    {
        textureColor = pow( texture(textureShadowHead, uv ), TEXTURE_GAMMA_CORRECTION );
    }

    return textureColor;
}


vec4 showBackground(vec2 uvPixelPosition)
{
    return pow( texture(textureBackground, vec2(uvPixelPosition.x, -uvPixelPosition.y) ), TEXTURE_GAMMA_CORRECTION );
}


vec4 showForeground(vec2 uvPixelPosition)
{
    return pow( texture(textureForeground, vec2(uvPixelPosition.x, -uvPixelPosition.y) ), TEXTURE_GAMMA_CORRECTION );
}


vec4 showLamp(vec2 uvPixelPosition)
{
    // Small Lissage shift
    float firstHarmonicX = (sin(fGlobalTime*0.7)/2)*0.005;
    float firstHarmonicY = (cos(fGlobalTime*0.7)/2)*0.009;

    float shiftX = (firstHarmonicX + (sin(fGlobalTime)/2)*0.0097)/1.0;
    float shiftY = (firstHarmonicY + (cos(fGlobalTime)/2)*0.0057)/1.0;

    vec2 lampCenter=vec2(0.2+shiftX, 1.02+shiftY);

    float intensity=1.0-rand(fGlobalTime)*0.05; // All fill white color
    float transparent=pow( 1.0-distance(uvPixelPosition, lampCenter)/sqrt(2) , 12 ); // 1.0-pow( sqrt(distance(uvPixelPosition, lampCenter)), 20 );

    vec4 color=vec4( vec3( 1.0*intensity, 0.8*intensity, 0.7*intensity ), transparent );

    // if(color.r<0.00000001)
    //     color=vec4( vec3(0.0), 1.0 );

    return color;
}

// ----------------------------------------------------
// Cinema filter
// Thanks Jmpep! (https://www.shadertoy.com/user/jmpep)
// ----------------------------------------------------

#define CINEMA_FREQUENCY 20
// #define CINEMA_BLACK_AND_WHITE
// #define CINEMA_LINES_AND_FLICKER
#define CINEMA_BLOTCHES
#define CINEMA_GRAIN

vec2 cuv=vec2(0.0); // Cinema uv, speed optimization


float cinemaRandomLine(float seed)
{
    float b = 0.01 * determineRand(seed);
    float a = determineRand(seed+1.0);
    float c = determineRand(seed+2.0) - 0.5;
    float mu = determineRand(seed+3.0);

    float l = 1.0;

    // Show lines, but too more blink
    if ( mu > 0.2)
        l = pow(  abs(a * cuv.x + b * cuv.y + c), 1.0/24.0 ) ;
    else
        l = 2.0 - pow( abs(a * cuv.x + b * cuv.y + c), 1.0/24.0 );

    return mix(0.32, 1.0, l);

    // l = sin(fGlobalTime)/2.0+0.5;
    // return l;
}


float cinemaRandomBlotch(float seed)
{
    float x = rand(seed);
    float y = rand(seed+1.0);
    float s = 0.008 * rand(seed+2.0); // Blotch size

    vec2 p = vec2(x,y) - cuv;
    p.x *= v2Resolution.x / v2Resolution.y;
    float a = atan(p.y,p.x);
    float v = 1.0;
    float ss = s*s * (sin(6.2831*a*x)*0.1 + 1.0);

    if ( dot(p,p) < ss )
        v = 0.25; // 0.2
    else
        v = pow(dot(p,p) - ss, 1.0/48.0);

    return mix(0.3 + 0.2 * (1.0 - (s / 0.02)), 1.0, v);
}


vec4 cinemaFilter(vec2 iuv, vec4 icolor)
{
    cuv=iuv;

    // Set frequency of global effect to 15 variations per second
    float t = float(int(fGlobalTime * CINEMA_FREQUENCY));
    
    // Get some image movement
    // vec2 suv = cuv + 0.002 * vec2( rand(t), rand(t + 23.0));
    
    // Get the image
    // vec3 image = texture( texPreviousFrame, vec2(suv.x, suv.y) ).xyz;
    vec3 image = icolor.xyz;
    
    #ifdef CINEMA_BLACK_AND_WHITE
    // Convert it to B/W
    float luma = dot( vec3(0.2126, 0.7152, 0.0722), image );
    vec3 oldImage = luma * vec3(0.7, 0.7, 0.7);
    #else
    vec3 oldImage = image;
    #endif
    
    // Create a time-varying vignetting effect
    float vI = 16.0 * (cuv.x * (1.0-cuv.x) * cuv.y * (1.0-cuv.y));
    // vI *= mix( 0.7, 1.0, rand(t + 0.5));
    
    // Add additive flicker
    vI += 0.85 + 0.05 * rand(t+8.);
    
    // Add a fixed vignetting (independent of the flicker)
    vI *= pow(16.0 * cuv.x * (1.0-cuv.x) * cuv.y * (1.0-cuv.y), 0.4);
    
    // Add some random lines (and some multiplicative flicker. Oh well.)
    #ifdef CINEMA_LINES_AND_FLICKER
    int l = int(8.0 * rand(t+7.0));
    
    // Accumulation calling
    if ( l > 0 ) vI *= cinemaRandomLine( t+6.0+17.* float(0));
    if ( l > 1 ) vI *= cinemaRandomLine( t+6.0+17.* float(1));
    if ( l > 2 ) vI *= cinemaRandomLine( t+6.0+17.* float(2));
    if ( l > 3 ) vI *= cinemaRandomLine( t+6.0+17.* float(3));
    if ( l > 4 ) vI *= cinemaRandomLine( t+6.0+17.* float(4));
    if ( l > 5 ) vI *= cinemaRandomLine( t+6.0+17.* float(5));
    if ( l > 6 ) vI *= cinemaRandomLine( t+6.0+17.* float(6));
    if ( l > 7 ) vI *= cinemaRandomLine( t+6.0+17.* float(7));
    
    #endif
    
    // Add some random blotches.
    #ifdef CINEMA_BLOTCHES
    int s = int( max(8.0 * rand(t+18.0) -2.0, 0.0 ));

    // Accumulation calling
    if ( s > 0 ) vI *= cinemaRandomBlotch( t+6.0+19.* float(0));
    if ( s > 1 ) vI *= cinemaRandomBlotch( t+6.0+19.* float(1));
    if ( s > 2 ) vI *= cinemaRandomBlotch( t+6.0+19.* float(2));
    if ( s > 3 ) vI *= cinemaRandomBlotch( t+6.0+19.* float(3));
    if ( s > 4 ) vI *= cinemaRandomBlotch( t+6.0+19.* float(4));
    if ( s > 5 ) vI *= cinemaRandomBlotch( t+6.0+19.* float(5));

    #endif

    vec4 color;

    // Show the image modulated by the defects
    color.xyz = oldImage * vI;
    
    // Add some grain
    #ifdef CINEMA_GRAIN
    color.xyz *= (1.0+(rand(cuv+t*.01)-.2)*.15);
    #endif

    return color;
}


// Sinus based random
// My online sample: https://www.shadertoy.com/view/sljXWt
float sinRand(float x)
{
    float y1 = abs((( sin(x+E)) + sin(x*E) )/2.0) * cos(x);
    // float y2 = float(mod( int(sin(float(mod( int(x), 11.0)))*7.0), 7.0))/7.0;
    float y2 = float(mod( floor(sin(float(mod( floor(x), 11.0)))*7.0), 7.0))/7.0;
    return y1*y2;
}


void initNotes()
{
    for(int i=0; i<NOTE_COUNT; ++i)
    {   
        int seed = i*100*NOTE_COUNT;

        int figure = int( floor( determineRand( float(++seed) )*4.0 ) ); // From 0 to 3
        vec3 color=vec3(determineRand( float(++seed) ), determineRand( float(++seed) ), determineRand( float(++seed) ));
        
        float freq       = 1.0 + determineRand( float(++seed)*3.0 );
        float secondFreq = 1.0 + determineRand( float(++seed)*3.0 );

        float phase       = determineRand( float(++seed) ) * 2.0 * PI;
        float secondPhase = determineRand( float(++seed) ) * 2.0 * PI;

        float amp       = determineRand( float(++seed) ) * 1.0;
        float secondAmp = determineRand( float(++seed) ) * 1.0;

        float timeSpeedFactor = 0.2 + determineRand( float(++seed) )*0.8;
        float sizeUpFactor    = determineRand( float(++seed) )*0.31 + 1.0;
        float axeYShift=determineRand( float(++seed) )*0.4-0.2;

        notes[i]=NoteType(figure, 
                          color, 
                          freq, 
                          secondFreq, 
                          phase, 
                          secondPhase, 
                          amp, 
                          secondAmp, 
                          timeSpeedFactor, 
                          sizeUpFactor,
                          axeYShift);
    }
}


int getNoteFigure(int i)
{
    return notes[i].figure;
}


vec2 getNotePosition(int i, float time)
{
    float t1=(time * notes[i].freq       + notes[i].phase)       * notes[i].timeSpeedFactor * 0.2;
    float t2=(time * notes[i].secondFreq + notes[i].secondPhase) * notes[i].timeSpeedFactor * 0.2;

    float yScale=3.8; // Y axe flattening ratio 

    float y=mod( t1, yScale )/yScale;

    float x=0.5 + notes[i].axeYShift + (sin(t1) * notes[i].amp + sin(t2) * notes[i].secondAmp)/2.0;

    return vec2(x, y);
}


vec4 showNotes(vec2 uvPixelPosition)
{
    initNotes();

    // Transparent delay at start Bonzomatic
    float timeMute=10.7;
    float fadeInLen=2.0;
    float transparent=0.0;
    if( fGlobalTime > timeMute && fGlobalTime < timeMute+fadeInLen )
    {
        float time=(fGlobalTime-timeMute)/fadeInLen;
        transparent=smoothstep(0.1, 0.9, time);
    }
    else if ( fGlobalTime > timeMute+fadeInLen)
    {
        transparent=1.0;
    }

    vec4 accColor=vec4(0.0);

    for(int i=0; i<NOTE_COUNT; ++i) 
    {
        vec2 notePosition=getNotePosition(i, fGlobalTime);
        float dist = distance( uvPixelPosition, notePosition );

        // Variable radius for resize note by time
        float r=0.027 * notes[i].sizeUpFactor * (sin(fGlobalTime*notes[i].freq*0.22+notes[i].phase)/4.0+0.8);
    
        if(dist<r)
        {
            // Nontransparent color set after time delay from start
            
            // Easy circle
            // color=vec4( notes[i].color, transparent);

            vec2 uvNoteTexurePosition=(vec2(r, r)+(uvPixelPosition-notePosition))/(2*vec2(r, r));
            vec4 color=vec4( 0.0 );

            if(notes[i].figure==0)
            {
                color=texture(textureNote4, vec2( uvNoteTexurePosition.x, -uvNoteTexurePosition.y) );
            }
            else if(notes[i].figure==1)
            {
                color=texture(textureNote3, vec2( uvNoteTexurePosition.x, -uvNoteTexurePosition.y) );
            }
            else if(notes[i].figure==2)
            {
                color=texture(textureNote2, vec2( uvNoteTexurePosition.x, -uvNoteTexurePosition.y) );
            }
            else
            {
                color=texture(textureNote1, vec2( uvNoteTexurePosition.x, -uvNoteTexurePosition.y) );
            }

            accColor=vec4( mix(accColor.rgb, color.rgb, color.a), 1.0 );
        }
    }

    return vec4( accColor.rgb, transparent );
}


vec4 showCylinder(vec2 uvPixelPosition, 
                  const CylinderType cylinderObject,
                  int texturePlate,
                  int textureRound)
{
    // Shift screen position
    uvPixelPosition+=vec2(-0.5, -0.45);

    // Rotate camera around (0,0,0)
    float rCamRotate=1.5; // 1.4
    float hCam=0.25; // 0.22
    float x=sin(0.0)*rCamRotate; // Dynamic camera: sin(-fGlobalTime*0.5)*rCamRotate;
    float y=hCam;
    float z=cos(0.0)*rCamRotate; // Dynamic camera: cos(-fGlobalTime*0.5)*rCamRotate;
    vec3 ro = vec3(x, y, z);

    vec3 camPointTo=vec3(0.0); // vec3(0.0)

    // Ray direction
    vec3 rd=cameraDirection(ro, camPointTo, uvPixelPosition);
    
    vec4 color = vec4( vec3(0.0), 1.0 ); // Start color for current point
    vec4 textureColor = vec4( 0.0 );
   
    // Get cylinder ray march distance
    cylinderRayMarch=cylinderObject;
    float d = RayMarch(ro, rd);

    if(d < RAY_MARCH_MAX_DIST) 
    {
        vec3 p = ro + rd * d;
        vec3 normal = GetNormal(p);
        // vec3 reflect = reflect(rd, normal); // For reflect support

        float angleByTime=fGlobalTime*0.065;

        // Texturing plate, it detect by normal (0, 1, 0)
        vec2 uvPixelAtTexture=vec2(0.0);
        if( distance(abs(normal), vec3(0.0, 1.0, 0.0)) < 0.001 )
        {
            // uvPixelAtTexture=vec2( (p.z/cylinderObject.r-1)/2.0, (p.x/cylinderObject.r-1)/2.0 );
            float angle=getAngle(p.z, -p.x)+angleByTime*2.0*PI;
            float radius=length(p);
            uvPixelAtTexture=vec2( (sin(angle)*radius-1)/2, (cos(angle)*radius-1)/2 );

            if( texturePlate == TEXTURE_GRAMMOPHONE_PLATE )
            {
                textureColor=pow( texture(textureSkinBlack, uvPixelAtTexture), vec4(1/1.1) );
            }
            else if( texturePlate == TEXTURE_WAVE_PLATE )
            {
                textureColor=textureWavePlate( vec2(sin(angle), cos(angle))*radius ); // vec2( p.z, p.x )
            }
            else if( texturePlate == TEXTURE_KINGPIN )
            {
                textureColor=texture(textureKingpin, uvPixelAtTexture);
            }
            else
            {
                textureColor=vec4( 0.0, 0.0, 1.0, 1.0 ); // Debug color
            }
        }
        else // Texturing round
        {
            // uvPixelAtTexture=vec2( 1/atan(p.x, p.z)-1.0, p.y-1.0 );

            float angle=getAngle(p.z, p.x)/(2.0*PI)-angleByTime;

            uvPixelAtTexture=vec2( angle, p.y*11 ); // vec2( atan(p.x/p.z), p.y)

            if( textureRound == TEXTURE_GRAMMOPHONE_ROUND)
            {
                textureColor=pow( texture(textureGrammophonePlate, uvPixelAtTexture), vec4(1/1.2) );
            }
            else if( textureRound == TEXTURE_WAVE_ROUND)
            {
                textureColor=vec4( vec3(0.0001), 1.0 ); // Dark color
            }
            else if( texturePlate == TEXTURE_KINGPIN )
            {
                textureColor=texture(textureKingpin, uvPixelAtTexture);
            }
            else
            {
                textureColor=vec4( 0.0, 0.0, 1.0, 1.0 ); // Debug color
            }

            // // Blue label
            // if(angle>=0 && angle<0.01)
            // {
            //     textureColor=vec4( 0.0, 0.0, 1.0, 1.0 );
            // }

            // // Lighthblue label
            // if(angle>=(sin(fGlobalTime/4)/2.0+0.5) && angle<(sin(fGlobalTime/4)/2.0+0.5)+0.01)
            // {
            //     textureColor=vec4( 0.5, 0.8, 1.0, 1.0 );
            // }

            // if(angle>=0.1 && angle<=1.0)
            // {
            //     textureColor=vec4( 0.5, 0.8, 1.0, 1.0 );
            // }
        }
       
        vec4 lightColor=vec4( vec3(GetLight(p))/4, 1.0 );

        // // Mix texture color
        color=mix(lightColor, textureColor, 0.65);
    }
    
    // color = vec4( pow(color.rgb, vec3(0.5545)), color.a); // Gamma correction

    return color;
}


vec4 fadeInFilter(vec4 color)
{
    float fadeInLen=5.0;
    float transparent=0.0;

    if( fGlobalTime < fadeInLen )
    {
        float time = fGlobalTime/fadeInLen;
        transparent=smoothstep(0.1, 0.9, time);
    }
    else
    {
        transparent=1.0;
    }

    return vec4( color.rgb, transparent);
}


void main(void)
{
    vec2 uv=vec2(gl_FragCoord.x/v2Resolution.x, gl_FragCoord.y/v2Resolution.y);

    // Translate XY coordinats to UV scane coordinats
    vec2 uvPixelPosition=uv/vec2(v2Resolution.y/v2Resolution.x, 1.0);
    float sideFieldWidth=(v2Resolution.x-v2Resolution.y)/2.0; // Width in pixel
    float uvSideFieldWidth=(v2Resolution.y+sideFieldWidth)/v2Resolution.y-1.0;
    uvPixelPosition=uvPixelPosition-vec2(uvSideFieldWidth, 0.0);
    
    // Pixel color
    vec4 color  = vec4(vec3(0.0), 1.0);
    vec4 color1 = vec4(vec3(0.0), 1.0);
    vec4 color2 = vec4(vec3(0.0), 1.0);
    vec4 color3 = vec4(vec3(0.0), 1.0);
    vec4 color4 = vec4(vec3(0.0), 1.0);
    vec4 color5 = vec4(vec3(0.0), 1.0);
    vec4 color6 = vec4(vec3(0.0), 1.0);
    vec4 color7 = vec4(vec3(0.0), 1.0);
    vec4 color8 = vec4(vec3(0.0), 1.0);
    vec4 color9 = vec4(vec3(0.0), 1.0);
    vec4 color10 = vec4(vec3(0.0), 1.0);

    color1=showBackground(uv);

    color2=showLamp(uv);

    color3=showCylinder(uvPixelPosition, 
                        objectGrammophonePlate,
                        TEXTURE_GRAMMOPHONE_PLATE, 
                        TEXTURE_GRAMMOPHONE_ROUND);

    color4=showCylinder(uvPixelPosition,
                        objectWavePlate,
                        TEXTURE_WAVE_PLATE,
                        TEXTURE_WAVE_ROUND);

    color5=showCylinder(uvPixelPosition,
                        objectKingpin,
                        TEXTURE_KINGPIN,
                        TEXTURE_KINGPIN);

    color6=showShadowKingpin(uvPixelPosition);
    color7=showShadowHead(uvPixelPosition);
    
    color8=showHead(uvPixelPosition);

    color9=showForeground(uv);

    color10=showNotes(uvPixelPosition);

    color=color1;
    if(color1.xyz != vec3(0.0) ) { color=color1; }    
    if(color2.xyz != vec3(0.0) ) { color=vec4( mix(color.rgb, color2.rgb, color2.a), 1.0 ); } // Lamp
    if(color3.xyz != vec3(0.0) ) { color=color3; }
    if(color4.xyz != vec3(0.0) ) { color=color4; }
    if(color5.xyz != vec3(0.0) ) { color=color5; }
    color=vec4( mix(color.rgb, color6.rgb, color6.a), 1.0 ); // Shadow kingpin
    color=vec4( mix(color.rgb, color7.rgb, color7.a), 1.0 ); // Shadow head
    if(color8.xyz != vec3(0.0) ) { color=color8; }
    if(color9.xyz != vec3(0.0) ) { color=color9; }
    if(color10.xyz != vec3(0.0) ) { color=vec4( mix(color.rgb, color10.rgb, color10.a), 1.0 ); } // Notes

    // Apply cinema filter
    vec4 cinemaColor=cinemaFilter(uv, color);
    color=mix(color, cinemaColor, 0.7);

    // Apply fade in filter
    vec4 darkColor=vec4( vec3(0.0), 1.0 );
    color=fadeInFilter(color);
    color=vec4( mix( darkColor.rgb, color.rgb, color.a ), 1.0);

    FragColor=color;
}
