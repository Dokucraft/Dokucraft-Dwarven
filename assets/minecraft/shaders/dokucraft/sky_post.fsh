#version 330

#moj_import <minecraft:fog.glsl>
#moj_import <minecraft:flownoise.glsl>
#moj_import <minecraft:perlin_worley.glsl>
#moj_import <minecraft:oklab.glsl>
#moj_import <dokucraft:config.glsl>

uniform sampler2D MainSampler;
uniform sampler2D MainDepthSampler;
uniform vec2 OutSize;

#if NIGHT_SKY == 0
  uniform sampler2D SkyBoxNightSampler;
#endif

#if ATMOSPHERE == 0
  uniform sampler2D SkyBoxDaySampler;
#elif ATMOSPHERE == 1
  uniform sampler2D CloudsSampler;
  uniform sampler2D SkyColorSampler;
#endif

#ifdef ENABLE_POST_MOON
  uniform sampler2D MoonSampler;
#endif

in vec2 texCoord;
in vec2 oneTexel;
in vec3 direction;
in float timeOfDay; // 1 - Noon, -1 - Midnight
in float near;
in float far;
in mat4 projInv;
in vec4 fogColor;
in vec3 skyColor;
in vec3 up;
in vec3 sunDir;

/* Moon phases:
    0.0:  Full Moon
    0.25: Third Quarter
    0.5:  New Moon
    0.75: First Quarter
  There are 8 of them, and it wraps around at 1.0 so that 1.0 turns into 0.0
*/
in float moonPhase;

/* Weather:
  0.0: Clear
  1.0: Raining
*/
in float weather;

out vec4 fragColor;

const float FUDGE = 0.01;

#define M_PI 3.141592653589793

#define RED_SKY_COLOR vec3(1, 0.6, 0.2)

mat4 rotationMatrix(vec3 axis, float angle) {
    axis = normalize(axis);
    float s = sin(angle);
    float c = cos(angle);
    float oc = 1.0 - c;
    
    return mat4(oc * axis.x * axis.x + c,           oc * axis.x * axis.y - axis.z * s,  oc * axis.z * axis.x + axis.y * s,  0.0,
                oc * axis.x * axis.y + axis.z * s,  oc * axis.y * axis.y + c,           oc * axis.y * axis.z - axis.x * s,  0.0,
                oc * axis.z * axis.x - axis.y * s,  oc * axis.y * axis.z + axis.x * s,  oc * axis.z * axis.z + c,           0.0,
                0.0,                                0.0,                                0.0,                                1.0);
}

vec3 rotate(vec3 v, vec3 axis, float angle) {
  mat4 m = rotationMatrix(axis, angle);
  return (m * vec4(v, 1.0)).xyz;
}

#if NIGHT_SKY >= 1
  float star(vec2 uv, float maxVal) {
    float d = length(uv);
    return min((0.1 / d /* + max(0.0, 1.0 - abs(uv.x * uv.y * 5000))*2 */) * smoothstep(1, 0.1, d), maxVal);
  }

  vec3 starfield(vec3 direction, int scsqrt, float bandPow, float maskOpacity, float maskOffset) {
    float l = length(direction.xz);
    vec3 dir = direction / l;
    vec2 uv = vec2(atan(dir.z, dir.x), dir.y) / M_PI * scsqrt;
    vec2 gv = fract(uv) - 0.5;
    vec2 id = floor(uv);
    int scsqrt2 = scsqrt * 2;
    vec3 col = vec3(0);
    for (int y = -1; y <= 1; y++) for (int x = -1; x <= 1; x++) {
      vec2 o = vec2(x, y);
      float n = hash12(mod(id + o, scsqrt2));
      float size = fract(n * 745.32);
      vec3 color = sin(vec3(0.2, 0.3, 0.9) * fract(n * 2345.7) * 109.2) * 0.5 + 0.5;
      color = color * vec3(0.4, 0.2, 0.1) + vec3(0.4, 0.6, 0.9);
      col += vec3(star(gv - o - vec2(n, fract(n * 34.2)) + 0.5, 15)) * size * color;
    }
    return col / 9 * pow(1.0 - abs(direction.y), bandPow) * (1 - maskOpacity * smoothstep(-0.25, 0.5, vec3(flownoise(normalize(direction + maskOffset) * 2))));
  }
#endif

/* ------------------------------ Auroras ---------------------------------- */
// Auroras by nimitz 2017 (twitter: @stormoid)
// License Creative Commons Attribution-NonCommercial-ShareAlike 3.0 Unported License
// Modified to get the time from the sun direction, remove the unnecessary
// ray origin vector, and to return a vec3 instead of vec4.

#ifdef ENABLE_AURORAS
  mat2 mm2(in float a){float c = cos(a), s = sin(a);return mat2(c,s,-s,c);}
  mat2 m2 = mat2(0.95534, 0.29552, -0.29552, 0.95534);
  float tri(in float x){return clamp(abs(fract(x)-.5),0.01,0.49);}
  vec2 tri2(in vec2 p){return vec2(tri(p.x)+tri(p.y),tri(p.y+tri(p.x)));}

  float triNoise2d(in vec2 p, float spd, float time) {
    float z=1.8;
    float z2=2.5;
    float rz = 0.0;
    p *= mm2(p.x*0.06);
    vec2 bp = p;
    for (float i = 0.0; i < 5.0; i++) {
      vec2 dg = tri2(bp*1.85)*.75;
      dg *= mm2(time*spd);
      p -= dg/z2;
      bp *= 1.3;
      z2 *= .45;
      z *= .42;
      p *= 1.21 + (rz-1.0)*.02;
      rz += tri(p.x+tri(p.y))*z;
      p*= -m2;
    }
    return clamp(1./pow(rz*29., 1.3),0.,.55);
  }

  #define INV_AURORA_COLOR vec3(1) / AURORA_COLOR
  vec3 aurora(vec3 direction, float time) {
    vec3 col = vec3(0);
    vec3 avgCol = vec3(0);

    for (float i = 0.0; i < 50.0; i++) {
      float of = 0.006*hash12(gl_FragCoord.xy)*smoothstep(0.,15., i);
      float pt = (.8+pow(i,1.4)*.002)/(direction.y*2.+0.4) - of;
      vec3 bpos = pt*direction;
      avgCol = mix(avgCol, (sin(1.-INV_AURORA_COLOR+i*0.043)*0.5+0.5)*triNoise2d(bpos.zx, 0.06, time), 0.5);
      col += avgCol*exp2(-i*0.065 - 2.5)*smoothstep(0.,5., i);
    }

    col *= clamp(direction.y*15.+.4,0.,1.);
    return max(vec3(0), col*1.8);
  }
#endif

/* ------------------------------------------------------------------------- */


float linearizeDepth(float depth) {
  return (2.0 * near * far) / (far + near - depth * (far - near));    
}

vec3 sampleSkybox(sampler2D skyboxSampler, vec3 direction) {
  float l = max(max(abs(direction.x), abs(direction.y)), abs(direction.z));
  vec3 dir = direction / l;
  vec3 absDir = abs(dir);

  vec2 skyboxUV;
  if (absDir.x >= absDir.y && absDir.x > absDir.z) {
    if (dir.x > 0) {
      skyboxUV = vec2(0, 0.5) + (dir.zy * vec2(1, -1) + 1) / 2 / vec2(3, 2);
    } else {
      skyboxUV = vec2(2.0 / 3, 0.5) + (-dir.zy + 1) / 2 / vec2(3, 2);
    }
  } else if (absDir.y >= absDir.z) {
    if (dir.y > 0) {
      skyboxUV = vec2(1.0 / 3, 0) + (dir.xz * vec2(-1, 1) + 1) / 2 / vec2(3, 2);
    } else {
      skyboxUV = vec2(0, 0) + (-dir.xz + 1) / 2 / vec2(3, 2);
    }
  } else {
    if (dir.z > 0) {
      skyboxUV = vec2(1.0 / 3, 0.5) + (-dir.xy + 1) / 2 / vec2(3, 2);
    } else {
      skyboxUV = vec2(2.0 / 3, 0) + (dir.xy * vec2(1, -1) + 1) / 2 / vec2(3, 2);
    }
  }
  return texture(skyboxSampler, skyboxUV).rgb;
}

#ifdef ENABLE_POST_MOON
  vec2 getMoonUV(vec3 direction) {
    float l = max(max(abs(direction.x), abs(direction.y)), abs(direction.z));
    vec3 dir = direction / l;

    vec2 moonUV;
    if (dir.x > 0) {
      moonUV = vec2(0);
    } else {
      moonUV = (-dir.zy + 1) / 2;
    }
    return clamp((moonUV - vec2(0.5)) / MOON_SCALE + vec2(0.5), vec2(0), vec2(1));
  }
#endif

float linearstep(float edge0, float edge1, float x) {
  return clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
}

vec3 colorBlend(vec3 base, vec3 blend) {
  return oklab2rgb(vec3(rgb2oklab(base).x, rgb2oklab(blend).yz));
}

vec3 blendSkyColor(vec3 atmosphere, vec3 skyColor) {
  float dist = length(skyColor - vec3(0.486, 0.639, 1));
  return mix(atmosphere, colorBlend(atmosphere, skyColor), smoothstep(0.0, 0.2, dist));
}

#if ATMOSPHERE == 1
  vec2 sampleCloudNorm(vec2 uv, vec3 px) {
    float v = texture(CloudsSampler, uv).r;
    float u = texture(CloudsSampler, uv - px.zy).r;
    float d = texture(CloudsSampler, uv + px.zy).r;
    float l = texture(CloudsSampler, uv - px.xz).r;
    float r = texture(CloudsSampler, uv + px.xz).r;
    return vec2(
      sqrt(clamp(v - d, 0, 1)) - sqrt(clamp(v - u, 0, 1)),
      sqrt(clamp(v - l, 0, 1)) - sqrt(clamp(v - r, 0, 1))
    );
  }
#endif

#ifdef ENABLE_POST_SUN
  float rayOpacity(vec2 dir, vec2 ref, float time, float seedA, float seedB) {
    float ca = dot(normalize(dir), ref);
    return clamp((0.48 + 0.16 * sin( ca * seedA + time)) + (0.29 + 0.23 * cos(-ca * seedB + time)), 0.0, 1.0);
  }

  vec4 postSun(vec3 color, vec3 nd, float ddsd, float sunAngle) {
    vec3 wsd = (rotationMatrix(vec3(0, 0, -1), M_PI - atan(sunDir.y, sunDir.x)) * vec4(nd, 1.0)).xyz;
    vec2 sunUV;
    if (wsd.x > 0) {
      sunUV = vec2(0);
    } else {
      sunUV = (-wsd.zy + 1) / 2 - vec2(0.5);
    }

    float raysX = rayOpacity(sunUV, vec2(1, 0), sunAngle * 350 * SUN_ANIM_SPEED, 36.2214, 21.1139);
    float raysY = rayOpacity(sunUV, vec2(0, 1), sunAngle * 350 * SUN_ANIM_SPEED, 26.1953, 34.9584);
    float sa = atan(sunUV.y, sunUV.x);
    vec2 raysMask = abs(sunUV);
    float rays = mix(raysX, raysY, clamp(pow(1 - (raysMask.y - raysMask.x) * 2, 10), 0, 1)) + 0.17 * (
      sin(sa * 7 + sunAngle * 250 * SUN_ANIM_SPEED) +
      sin(sa * 5 - sunAngle * 169 * SUN_ANIM_SPEED) +
      2
    );

    float distSun = dot(wsd, vec3(-1, 0, 0)) * 0.995;
    float sunOpacity = smoothstep(0.995, 0.99999, distSun) + pow(rays, smoothstep(1, 0.97, distSun)) * smoothstep(0.97, 1, distSun) + pow(smoothstep(0.998, 1.0015, ddsd), 2);
    return vec4(mix(vec3(1, 0.1, 0), vec3(2), sunOpacity), sunOpacity * sunOpacity * (1.0 - weather));
  }
#endif

#ifdef ENABLE_NIGHT_FOG
  vec4 nightFog(vec3 nd, vec3 ndr, float m) {
    float distHorizon = 1.0 - abs(dot(nd, vec3(0, 1, 0)));
    float distMoon = max(0, dot(ndr, vec3(-1, 0, 0)));
    return vec4(
      // Base fog
        vec3(0.243, 0.325, 0.392)
      // Moonlit fog
      + mix(vec3(0.156, 0.274, 0.38), vec3(0.737, 0.76, 0.745), distMoon) * distMoon * distMoon * m
      , mix(0.1, 0.9, distHorizon)
    );
  }
#endif

vec3 stormyWeather(vec3 ndr, float sunAngle, float screenNoise) {
  vec3 fc = linear_fog(vec4(1), 1, 0, 1, fogColor).rgb;
  if (dot(ndr, rotate(vec3(0, -1, 0), vec3(0, 0, 1), sunAngle - 0.522875)) > 0) {
    return fc.rgb;
  }
  float saf = mod(sunAngle / M_PI * 0.5, 1);
  return fc.rgb + (0.5 * fc.rgb + 0.1) * (vec3(
    worleyNoise(ndr * 4  - vec2(saf * 15*4, 0).yxy, 4) +
    worleyNoise(ndr * 8  - vec2(saf * 9*8, 0).yxy, 8) * 0.5 +
    worleyNoise(ndr * 16 - vec2(saf * 4*16, 0).yxy, 16) * 0.25 +
    worleyNoise(ndr * 32 - vec2(saf * 2*32, 0).yxy, 32) * 0.125 +
    worleyNoise(ndr * 64 - vec2(saf * 64, 0).yxy, 64) * 0.0625
  ) / 1.9375 * 2 - 1);
}

void main() {
  float realDepth = linearizeDepth(texture(MainDepthSampler, texCoord).r);
  fragColor = texture(MainSampler, texCoord);

  vec3 temp = fragColor.rgb - vec3(0.157, 0.024, 0.024);
  bool isNether = dot(temp, temp) < FUDGE;
  vec3 nd = normalize(direction);

  if (far > 50 && realDepth > far / 2 - 5) {

    vec3 stars = vec3(0);
    vec4 moon = vec4(0);
    vec4 atmosphere = vec4(0);
    vec3 auroras = vec3(0);
    vec4 clouds = vec4(0);
    vec3 cloudsAdditive = vec3(0);

    float dayLight = smoothstep(-0.1, 0.1, timeOfDay);
    float sunAngle = atan(sunDir.y, sunDir.x);
    mat4 timeRotMat = rotationMatrix(vec3(0, 0, 1), sunAngle - M_PI / 6);
    vec3 ndr = (timeRotMat * vec4(nd, 1.0)).xyz;
    float screenNoise = hash12(gl_FragCoord.xy);

    #ifdef ENABLE_POST_MOON
      vec2 moonUV = getMoonUV((rotationMatrix(vec3(0, 0, 1), atan(sunDir.y, sunDir.x)) * vec4(nd, 1.0)).xyz);
      moon = texture(MoonSampler, moonUV);

      // Moon radius in UV space: 0.95 / 2 = 0.475
      vec2 moonNormXY = (moonUV - vec2(0.5)) / 0.475;
      vec3 moonNorm = normalize(vec3(moonNormXY, 1.0 - length(moonNormXY)));
      vec3 fakeSunDir = rotate(vec3(0, 0, 1), vec3(0.5, 0.5, 0), M_PI * 2 * moonPhase);

      // Add shading to the moon based on moon phase
      float fullMoonMod = -0.2 * abs(0.5 - moonPhase);
      moon.rgb *= smoothstep(-0.2 + fullMoonMod, 0.4 + fullMoonMod, dot(moonNorm, fakeSunDir));
    #endif

    if (timeOfDay < 0.1) { // Night time
      #if NIGHT_SKY == 0
        stars = sampleSkybox(SkyBoxNightSampler, (rotationMatrix(vec3(0, 0, 1), atan(sunDir.y, sunDir.x)) * vec4(nd, 1.0)).xyz).rgb;

        #ifdef ENABLE_NIGHT_FOG
        atmosphere = nightFog(nd, ndr,
          #ifdef ENABLE_POST_MOON
            (fakeSunDir.z + 2.0) / 3.0
          #else
            0.8
          #endif
        );
      #endif

      #elif NIGHT_SKY == 1 || NIGHT_SKY == 2
        #ifdef ENABLE_NORTH_STAR
          vec3 nsp = normalize(normalize(vec3(0, 0.57, 1)) - nd);
        #endif

        stars =
          // Galactic disk
            starfield(rotate(ndr, vec3(1, 0, 0), 2.4), 96, 6, 0.75, 25) * 3
          // Nearby stars
          + starfield(rotate(ndr, vec3(0.7, 0.3, -0.6), 1.2), 32, 2, 1, 3)
          + starfield(rotate(ndr, vec3(-0.8, 0.2, -0.5), 0.3), 16, 2, 1, 9)
          + starfield(rotate(ndr, vec3(-0.9, 0.8, 0.4), 2.1), 40, 2, 1, 13) * 1.1
          // Distant stars/galaxies
          + starfield(rotate(ndr, vec3(1), 1.5), 160, 1, 1, 31)
          // Nebulae
          #if NIGHT_SKY == 1
            + vec3(0.2, 0.5, 0.9) * smoothstep(0.2, 1, flownoise(ndr * 2 + 46) * 0.5 + 0.5) * 0.4
            + vec3(0.8, 0.1, 0.9) * smoothstep(0.1, 1.1, flownoise(ndr * 2 + 14) * 0.5 + 0.5) * 0.1
          #elif NIGHT_SKY == 2
            + vec3(0.2, 0.5, 0.9) * smoothstep(0.2, 1, flownoise(ndr * 2 + 46) * 0.5 + 0.5) * 0.08
            + vec3(0.8, 0.1, 0.9) * smoothstep(0.1, 1.1, flownoise(ndr * 2 + 14) * 0.5 + 0.5) * 0.02
          #endif

          #ifdef ENABLE_NORTH_STAR
            + max(vec3(1 - abs(nsp.x * nsp.y * 150000)) * 2, 0) * smoothstep(0.0175, 0.00175, length(nsp.xy)) * vec3(0.5, 0.75, 1)
          #endif
        ;
      #endif

      #ifdef ENABLE_NIGHT_FOG
        atmosphere = nightFog(nd, ndr,
          #ifdef ENABLE_POST_MOON
            (fakeSunDir.z + 2.0) / 3.0
          #else
            0.5
          #endif
        );
      #endif

      #ifdef ENABLE_AURORAS
        auroras = aurora(nd, sunAngle * 1000) * 0.5
          #ifndef ENABLE_POST_MOON
            * smoothstep(-1.025, -0.9, dot(nd, sunDir))
          #endif
        ;
      #endif
    }

    float hm = (1.5 + clamp(dot(nd, vec3(0, -1, 0)) * 2, -1.5, 0.5)) / 2;
    vec3 horizon = vec3(0.728308,0.04059,0.036865);
    float rm = max(0, (1 + dot(nd, normalize(sunDir))) / 2);
    rm *= rm * (max(0.75, 1 - abs(timeOfDay)) - 0.75) * 4;

    #if ATMOSPHERE == 0
      atmosphere = mix(
        atmosphere,
        vec4(
          blendSkyColor(
            sampleSkybox(SkyBoxDaySampler, (vec4(direction, 1) * rotationMatrix(vec3(0, 1, 0), 1.3)).xyz),
            skyColor
          ),
          dayLight
        ),
        dayLight
      );

      // Rainy weather
      if (weather > 0) {
        atmosphere.rgb = mix(atmosphere.rgb, stormyWeather(ndr, sunAngle, screenNoise), weather);
        atmosphere.a = max(dayLight, weather);
      }

      // Make the sky more red near the sun during sunrise/sunset
      atmosphere.rgb = mix(
        atmosphere.rgb,
        mix(
          colorBlend(atmosphere.rgb, horizon),
          horizon,
          mix(hm, hm * 0.1, weather)
        ) / (1 - pow(smoothstep(-5, 3, dot(nd, sunDir)), 4) * RED_SKY_COLOR),
        mix(rm, rm * 0.1, weather)
      );

      #ifdef ENABLE_POST_SUN
        vec4 sun = postSun(atmosphere.rgb, nd, dot(nd, sunDir), sunAngle);
        atmosphere.rgb = mix(atmosphere.rgb, sun.rgb, sun.a);
      #endif

    #elif ATMOSPHERE == 1
      float ddsd = dot(nd, sunDir);
      float skyTopMask = smoothstep(1.0, 0.8, nd.y);
      vec2 cloudsUV = vec2(atan(nd.z, nd.x) / (M_PI * 2), abs((nd.y - 1.35) / 1.6));
      float texValue = texture(CloudsSampler, cloudsUV).r;
      vec3 pxSize = vec3(vec2(1.0) / textureSize(CloudsSampler, 0), 0);
      vec3 cloudNorm = vec3(vec2(
        sampleCloudNorm(cloudsUV + vec2(-1, -1) * pxSize.xy, pxSize) * 0.0625 +
        sampleCloudNorm(cloudsUV + vec2(-1,  0) * pxSize.xy, pxSize) * 0.125 +
        sampleCloudNorm(cloudsUV + vec2(-1,  1) * pxSize.xy, pxSize) * 0.0625 +
        sampleCloudNorm(cloudsUV + vec2( 0, -1) * pxSize.xy, pxSize) * 0.125 +
        sampleCloudNorm(cloudsUV,                            pxSize) * 0.25 +
        sampleCloudNorm(cloudsUV + vec2( 0,  1) * pxSize.xy, pxSize) * 0.125 +
        sampleCloudNorm(cloudsUV + vec2( 1, -1) * pxSize.xy, pxSize) * 0.0625 +
        sampleCloudNorm(cloudsUV + vec2( 1,  0) * pxSize.xy, pxSize) * 0.125 +
        sampleCloudNorm(cloudsUV + vec2( 1,  1) * pxSize.xy, pxSize) * 0.0625
      ), 0);
      cloudNorm.z = sqrt(1.0 - dot(cloudNorm.xy, cloudNorm.xy));
      vec3 dirR = normalize(cross(nd, vec3(0, 1, 0)));
      vec3 dirD = normalize(cross(nd, dirR));
      cloudNorm = normalize(mat3(dirD, -dirR, -nd) * cloudNorm);

      // Adding a tiny bit of noise here lessens the color banding in the gradient
      float fAtmos = nd.y + screenNoise * 0.02;
      atmosphere = mix(atmosphere, vec4(
        blendSkyColor(
          mix(
            mix(
              texelFetch(SkyColorSampler, ivec2(0, 2), 0).rgb,
              texelFetch(SkyColorSampler, ivec2(0, 1), 0).rgb,
              linearstep(0, 0.5, fAtmos)
            ),
            texelFetch(SkyColorSampler, ivec2(0, 0), 0).rgb,
            linearstep(0.5, 1, fAtmos)
          ),
          skyColor
        ), max(weather, dayLight)
      ), max(weather, dayLight));

      // Rainy weather
      if (weather > 0) {
        atmosphere.rgb = mix(atmosphere.rgb, stormyWeather(ndr, sunAngle, screenNoise), weather);
      }

      // Make the sky more red near the sun during sunrise/sunset
      atmosphere.rgb = mix(
        atmosphere.rgb,
        mix(
          colorBlend(atmosphere.rgb, horizon),
          horizon,
          mix(hm, hm * 0.1, weather)
        ) / (1 - pow(smoothstep(-5, 3, dot(nd, sunDir)), 4) * RED_SKY_COLOR),
        mix(rm, rm * 0.1, weather)
      );

      #ifdef ENABLE_POST_SUN
        vec4 sun = postSun(atmosphere.rgb, nd, ddsd, sunAngle);
        atmosphere.rgb = mix(atmosphere.rgb, sun.rgb, sun.a);
      #endif

      float cndsd = dot(cloudNorm, sunDir);

      vec3 dayCloudsColor = mix(
        texelFetch(SkyColorSampler, ivec2(1, 0), 0).rgb,
        texelFetch(SkyColorSampler, ivec2(1, 1), 0).rgb,
        smoothstep(0.5, -1.2, cndsd) * texValue * texValue * texValue
      );
      vec3 nightCloudsColor = mix(
        texelFetch(SkyColorSampler, ivec2(2, 0), 0).rgb,
        texelFetch(SkyColorSampler, ivec2(2, 1), 0).rgb,
        smoothstep(-0.5, 1.2, cndsd) * texValue * texValue * texValue
      );

      float fSunsetClouds = smoothstep(0.9, -0.9, cndsd);
      vec3 sunsetCloudsColor = mix(
        mix(
          texelFetch(SkyColorSampler, ivec2(3, 0), 0).rgb,
          texelFetch(SkyColorSampler, ivec2(3, 1), 0).rgb,
          linearstep(0, 0.5, fSunsetClouds)
        ),
        texelFetch(SkyColorSampler, ivec2(3, 2), 0).rgb,
        linearstep(0.5, 1, fSunsetClouds)
      );

      clouds = vec4(
        mix(
          blendSkyColor(
            mix(nightCloudsColor, dayCloudsColor, dayLight),
            skyColor
          ),
          sunsetCloudsColor,
          smoothstep(-0.35, 0, timeOfDay) * smoothstep(0.25, 0, timeOfDay) * smoothstep(-1 + 0.6 * (1 - dayLight), 1, dot(nd, sunDir))
        ),
        mix(smoothstep(0, 0.8, texValue), texValue, dayLight) * skyTopMask * (1.0 - weather)
        #ifdef ENABLE_POST_SUN
          * (1.0 - sun.a * sun.a * sun.a)
        #endif
      );

      // Light up the edges of clouds near the sun, moon and auroras
      cloudsAdditive = vec3((
        // Sun
          dayLight * smoothstep(0.0, 1.0, ddsd) * 0.8
        // Moon + auroras
        + (1.0 - dayLight) * (
          smoothstep(0.0, -1.0, ddsd)
          #ifdef ENABLE_POST_MOON
            * (fakeSunDir.z + 2.0) / 6.0
          #else
            * 0.45
          #endif
          + auroras
        )
      ) * smoothstep(0.05, 0.5, texValue) * smoothstep(0.9, 0, texValue) * skyTopMask) * (1.0 - weather);
    #endif

    vec4 screenPos = gl_FragCoord;
    screenPos.xy = (screenPos.xy / OutSize - vec2(0.5)) * 2.0;
    screenPos.zw = vec2(1.0);
    vec3 view = normalize((projInv * screenPos).xyz);
    float ndusq = clamp(dot(view, vec3(0.0, 1.0, 0.0)), 0.0, 1.0);
    ndusq = ndusq * ndusq;

    vec4 finalColor = linear_fog(vec4(
      mix(
        mix(
          mix(stars, moon.rgb, moon.a),
          atmosphere.rgb, atmosphere.a - 0.3 * moon.a * moon.a * dayLight
        ) + auroras * (1.0 - dayLight),
        clouds.rgb, clouds.a
      ) + cloudsAdditive, 1
    ), pow(1.0 - ndusq, 6.0), 0.0, 1.0, mix(fogColor, vec4(0.827, 0.447, 0.27, 1), rm));

    #ifdef ENABLE_POST_SUN
      fragColor = vec4(mix(
        finalColor.rgb,
        fragColor.rgb,
        fragColor.a
      ), 1.0);
    #else
      vec3 ok1 = rgb2oklab(finalColor.rgb);
      vec3 ok2 = rgb2oklab(fragColor.rgb);
      vec3 ok3 = mix(
        ok2,
        mix(
          ok1,
          ok2,
          pow(linearstep(0.08, 1.0, fragColor.a), 0.5)
        ),
        (1.0 - fragColor.a) * smoothstep(0.99, 0.985, dot(nd, sunDir) - fragColor.a * fragColor.a)
      );
      vec3 ok4 = mix(
        ok3,
        max(ok1, ok3),
        smoothstep(0.98, 0.99, dot(nd, sunDir))
      );
      fragColor = vec4(oklab2rgb(
        #ifdef DISABLE_CORE_STARS
          ok4
        #else
          mix(
            ok1,
            ok4,
            clamp(
              smoothstep(0.7, 0.3,
                smoothstep(1.0, 0.9, 1.0 - fragColor.a)
                * (1.0 - fragColor.a)
                * smoothstep(0.975, 0.96, dot(nd, sunDir))
              ) + smoothstep(-0.98, -0.99, dot(nd, sunDir)),
              0.0, 1.0
            )
          )
        #endif
      ), 1);
    #endif
  }
}
