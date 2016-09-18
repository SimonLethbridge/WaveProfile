//
//  Shaders.metal
//  WaveProfile
//
//  Created by Simon Lethbridge on 03/07/2016.
//  Copyright (c) 2016 Simon Lethbridge. All rights reserved.
//

#include <metal_stdlib>

using namespace metal;

struct VertexInOut
{
    float4  position [[position]];
    float4  colour;
};

struct ProfileCoord
{
    float x,y;
};

struct Constants
{
    float4 colour;
    float4 offset;
};

struct WaveParams
{
    float Qbase, amplitude, height;
};

kernel void profileKernel (
    const device ProfileCoord *meshCoordsIn  [[ buffer(0) ]],
          device ProfileCoord *meshCoordsOut [[ buffer(1) ]],
    constant WaveParams *waveParams             [[ buffer(2) ]],
          uint id [[thread_position_in_grid]]
    )
{
    if (meshCoordsIn[id].y > -1.0f)
    {
        const float Q  = waveParams->Qbase * 0.5f;
        const float phase = meshCoordsIn[id].x * 10.0f;
        
        ProfileCoord tmp;
        tmp.x = meshCoordsIn[id].x + Q * waveParams->amplitude *  cos (phase);
        tmp.y = meshCoordsIn[id].y*waveParams->height +     waveParams->amplitude * (sin (phase) - 1.0f);
        meshCoordsOut[id]=tmp;
    }
    else
    {
        meshCoordsOut[id]=meshCoordsIn[id];
    }
}

vertex VertexInOut passThroughVertex(uint vid                         [[ vertex_id ]],
                                     constant ProfileCoord* position  [[ buffer(0) ]],
                                     constant Constants &constants    [[ buffer(1) ]])
{
    VertexInOut outVertex;
    
    outVertex.position.x = position[vid].x;
    outVertex.position.y = position[vid].y;
    outVertex.position.z = constants.offset[3];
    outVertex.position.w = 1.0f;

//    outVertex.color    = float4(0.5f, 0.5f, 1.0f, 1.0f);
    outVertex.colour    = float4(constants.colour);
    
    return outVertex;
};

fragment half4 passThroughFragment(VertexInOut inFrag [[stage_in]])
{
    return half4(inFrag.colour);
};

