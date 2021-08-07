#version 410 core

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


const float PI=3.1415926535897932384626433832795;

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
const CylinderType objectWavePlate=CylinderType( 0.97, 0.05, 0.0548, 0.003 );
const CylinderType objectKingpin=CylinderType( 0.02, 0.0548, 0.09, 0.008 ); // ( 0.02, 0.0548, 0.09, 0.008 )


const int TEXTURE_GRAMMOPHONE_PLATE=1;
const int TEXTURE_GRAMMOPHONE_ROUND=2;
const int TEXTURE_WAVE_PLATE=3;
const int TEXTURE_WAVE_ROUND=4;
const int TEXTURE_KINGPIN=5;


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
    vec3 lightPos = vec3(5.,5.,5.); // Light Position
    vec3 l = normalize(lightPos-p); // Light Vector
    vec3 n = GetNormal(p); // Normal Vector
   
    float dif = dot(n,l); // Diffuse light
    dif = clamp(dif,0.,1.); // Clamp so it doesnt go below 0

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
    vec2 center=vec2(0, 0); // vec2(.5, 0.38);

    float scaleX=1.0;
    float scaleY=1.0;
    
    // Rotate
    mat4 matPlateRotate=get2DTranslateMatrix(center.x, center.y)*
    get2DRotateMatrix(fGlobalTime)*
    inverse(get2DScaleMatrix(scaleX, scaleY))*
    inverse(get2DTranslateMatrix(center.x, center.y));
    
    vec4 afterRotatePos=vec4(uvPixelPosition.x, uvPixelPosition.y, 0, 1);
    afterRotatePos=matPlateRotate*afterRotatePos;
    
    uvPixelPosition=vec2(afterRotatePos.x, afterRotatePos.y);
    
    // Small mix random by coordinats
    uvPixelPosition.x=uvPixelPosition.x+sin(rand(uvPixelPosition.x*uvPixelPosition.y))/500.0;
    uvPixelPosition.y=uvPixelPosition.y+cos(rand(uvPixelPosition.x/uvPixelPosition.y))/500.0;
    
    float len1=length(uvPixelPosition-center);
    
    if(len1>maxRadius)
    {
        return vec4(0.0, 0.0, 0.0, 0.0); // Transparent color
    }
    
    float c1=sin(len1/waveLen);
    
    float len2=length(uvPixelPosition+focusShift-center);
    float c2=sin(len2/waveLen);
    
    // float c=(c1+c2)/4.0-0.1; // Sybstract for saturation control, best diapason  0.1...0.2
    float c=(c1+c2)/4+0.05; // Sybstract for saturation control, best diapason  0.1...0.2
    
    // Small mix random by color
    // c=c-0.1+rand(uvPixelPosition.x*uvPixelPosition.y)/10;
    
    return vec4( vec3( clamp(0.0, 1.0, c) ), 1.0);
}

vec4 textureWavePlate(vec2 uvPixelPosition)
{
    vec2 focusShift=vec2(sin(fGlobalTime)/650.0+1.0/650.0*4.0, 0.001);
    
    int maxNum=1;
    vec4 acc=vec4(vec3(0.0), 1.0); // Accumulator
    for(int num=0; num<maxNum; num++)
    {
        // todo: Try adding randVec to uvPixelPosition
        // vec2 randVec=vec2(sin(rand(fGlobalTime+num))/1000.0, sin(rand(fGlobalTime+num*num))/1000.0);
        acc+=wavePlate(uvPixelPosition, objectWavePlate.r, 0.00085, focusShift, fGlobalTime);
    }
    
    return vec4(acc.rgb*(1.0/float(maxNum)), 1.0);
}


vec4 showHead(vec2 uvPixelPosition)
{
    float firstHarmonicX = (sin(fGlobalTime*0.7)/2)*0.005;
    float firstHarmonicY = (cos(fGlobalTime*0.7)/2)*0.009;

    float shiftY = (firstHarmonicY + (cos(fGlobalTime)/2)*0.005)/2.0;
    float shiftX = (firstHarmonicX + (sin(fGlobalTime)/2)*0.009)/2.0;

    mat4 transformMat = get2DScaleMatrix(1.9, 1.9) * get2DTranslateMatrix(-0.6+shiftX, 0.85+shiftY);

    vec2 uv = ( transformMat * vec4(uvPixelPosition.x, -uvPixelPosition.y, 0.0, 1.0) ).xy;

    vec4 textureColor=vec4(0.0);

    if(uv.x>=0.0 && uv.x<=1.0 && uv.y>=0 && uv.y<=1.0)
    {
        textureColor = texture(textureHead, vec2(uv.x, uv.y) );
    }

    return textureColor;
}


vec4 showCylinder(vec2 uvPixelPosition, 
                  CylinderType cylinderObject,
                  int texturePlate,
                  int textureRound)
{
    // Shift screen position
    uvPixelPosition+=vec2(-0.5, -0.45);

    // Rotate camera around (0,0,0)
    float rCamRotate=1.4; // 1.4
    float hCam=0.22; // 0.22
    float x=sin(-fGlobalTime*0.5)*rCamRotate;
    float y=hCam;
    float z=cos(-fGlobalTime*0.5)*rCamRotate;
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

        // Texturing plate, it detect by normal (0, 1, 0)
        vec2 uvPixelAtTexture=vec2(0.0);
        if( distance(abs(normal), vec3(0.0, 1.0, 0.0)) < 0.001 )
        {
            // uvPixelAtTexture=vec2( cylinderObject.r+p.z/cylinderObject.r/2.0, cylinderObject.r+p.x/cylinderObject.r/2.0 );
            uvPixelAtTexture=vec2( (p.z/cylinderObject.r-1)/2.0, (p.x/cylinderObject.r-1)/2.0 );

            if( texturePlate == TEXTURE_GRAMMOPHONE_PLATE )
            {
                textureColor=texture(textureSkinBlack, uvPixelAtTexture);
            }
            else if( texturePlate == TEXTURE_WAVE_PLATE )
            {
                textureColor=textureWavePlate( vec2( p.z, p.x ) );
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

            float angle=getAngle(p.z, p.x)/(2.0*PI);

            uvPixelAtTexture=vec2( angle, p.y ); // vec2( atan(p.x/p.z), p.y)

            if( textureRound == TEXTURE_GRAMMOPHONE_ROUND)
            {
                textureColor=texture(textureGrammophonePlate, uvPixelAtTexture);
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
        color=mix(lightColor, textureColor, 0.5);
    }
    
    // color = vec4( pow(color.rgb, vec3(0.5545)), color.a); // Gamma correction

    return color;
}


void main(void)
{
    // Translate XY coordinats to UV coordinats
    vec2 uvPixelPosition=vec2(gl_FragCoord.x/v2Resolution.x, gl_FragCoord.y/v2Resolution.y);
    uvPixelPosition/=vec2(v2Resolution.y/v2Resolution.x, 1.0);
    float sideFieldWidth=(v2Resolution.x-v2Resolution.y)/2.0; // Width in pixel
    float uvSideFieldWidth=(v2Resolution.y+sideFieldWidth)/v2Resolution.y-1.0;
    uvPixelPosition=uvPixelPosition-vec2(uvSideFieldWidth, 0.0);
    
    // Pixel color
    vec4 color  = vec4(vec3(0.0), 1.0);
    vec4 color1 = vec4(vec3(0.0), 1.0);
    vec4 color2 = vec4(vec3(0.0), 1.0);
    vec4 color3 = vec4(vec3(0.0), 1.0);
    vec4 color4 = vec4(vec3(0.0), 1.0);

    color1=showCylinder(uvPixelPosition, 
                        objectGrammophonePlate,
                        TEXTURE_GRAMMOPHONE_PLATE, 
                        TEXTURE_GRAMMOPHONE_ROUND);

    color2=showCylinder(uvPixelPosition,
                        objectWavePlate,
                        TEXTURE_WAVE_PLATE,
                        TEXTURE_WAVE_ROUND);

    color3=showCylinder(uvPixelPosition,
                        objectKingpin,
                        TEXTURE_KINGPIN,
                        TEXTURE_KINGPIN);

    color4=showHead(uvPixelPosition);

    color=color1;
    if(color2.xyz != vec3(0.0) )
    {
        color=color2;
    }
    if(color3.xyz != vec3(0.0) )
    {
        color=color3;
    }
    if(color4.xyz != vec3(0.0) )
    {
        color=color4;
    }

    FragColor=color;
}
