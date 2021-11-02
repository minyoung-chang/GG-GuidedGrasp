//
//  gray.metal
//  GuidedGrasp
//
//  Created by Eric Pu Jing on 10/15/21.
//  Copyright © 2021 Yehor Chernenko. All rights reserved.
//

#include <metal_stdlib>
using namespace metal;

kernel void
grayscaleKernel(
    texture2d<float, access::read>  inTexture [[texture(0)]],
    texture2d<float, access::write> outTexture [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
)
{
    float inColor  = inTexture.read(gid).r * 2 / 4;
    
    float inColorl1  = inTexture.read(gid - uint2(1, 0)).r * 1 / 4;
    float inColorl2  = inTexture.read(gid - uint2(2, 0)).r * 1 / 4;
    float inColorl3  = inTexture.read(gid - uint2(3, 0)).r * -1 / 4;
    float inColorl4  = inTexture.read(gid - uint2(4, 0)).r * -2 / 4;
    float inColorr1  = inTexture.read(gid + uint2(1, 0)).r * 1 / 4;
    float inColorr2  = inTexture.read(gid + uint2(2, 0)).r * 1 / 4;
    float inColorr3  = inTexture.read(gid + uint2(3, 0)).r * -1 / 4;
    float inColorr4  = inTexture.read(gid + uint2(4, 0)).r * -2 / 4;
    float  gray     = inColor + inColorl1 + inColorl2 + inColorl3 + inColorl4 + inColorr1 + inColorr2 + inColorr3 + inColorr4;
    
    float inColoru1  = inTexture.read(gid - uint2(0, 1)).r * 1 / 4;
    float inColoru2  = inTexture.read(gid - uint2(0, 2)).r * 1 / 4;
    float inColoru3  = inTexture.read(gid - uint2(0, 3)).r * -1 / 4;
    float inColoru4  = inTexture.read(gid - uint2(0, 4)).r * -2 / 4;
    float inColord1  = inTexture.read(gid + uint2(0, 1)).r * 1 / 4;
    float inColord2  = inTexture.read(gid + uint2(0, 2)).r * 1 / 4;
    float inColord3  = inTexture.read(gid + uint2(0, 3)).r * -1 / 4;
    float inColord4  = inTexture.read(gid + uint2(0, 4)).r * -2 / 4;
    float  gray2     = inColor + inColoru1 + inColoru2 + inColoru3 + inColoru4 + inColord1 + inColord2 + inColord3 + inColord4;
    
    outTexture.write(-min(gray,gray2), gid);
}
