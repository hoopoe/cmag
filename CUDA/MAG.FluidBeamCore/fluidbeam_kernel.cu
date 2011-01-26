#ifndef _FLUIDBEAM_KERNEL_CU_
#define _FLUIDBEAM_KERNEL_CU_

#include <stdio.h>
#include <math.h>
#include "cutil_math.h"
#include "math_constants.h"
#include "fluidbeam_kernel.cuh"

#if USE_TEX
texture<float4, 1, cudaReadModeElementType> oldPosTex;
texture<float4, 1, cudaReadModeElementType> oldVelTex;
texture<float4, 1, cudaReadModeElementType> oldMeasuresTex;

texture<uint, 1, cudaReadModeElementType> gridParticleHashTex;
texture<uint, 1, cudaReadModeElementType> cellStartTex;
texture<uint, 1, cudaReadModeElementType> cellEndTex;
#endif
__constant__ SimParams params;

__device__ int3 calcGridPos(float3 p)
{
    int3 gridPos;
    gridPos.x = floor((p.x - params.worldOrigin.x) / params.cellSize.x);
    gridPos.y = floor((p.y - params.worldOrigin.y) / params.cellSize.y);
    gridPos.z = floor((p.z - params.worldOrigin.z) / params.cellSize.z);
    return gridPos;
}

__device__ uint calcGridHash(int3 gridPos)
{
    gridPos.x = gridPos.x & (params.gridSize.x-1);  
    gridPos.y = gridPos.y & (params.gridSize.y-1);
    gridPos.z = gridPos.z & (params.gridSize.z-1);        
    return __umul24(__umul24(gridPos.z, params.gridSize.y), params.gridSize.x) + __umul24(gridPos.y, params.gridSize.x) + gridPos.x;
}

__global__
void calcHashD(uint*   gridParticleHash,  // output
               uint*   gridParticleIndex, // output
               float4* pos,               // input
               uint    numParticles)
{
    uint index = __umul24(blockIdx.x, blockDim.x) + threadIdx.x;
    if (index >= numParticles) return;
    
    volatile float4 p = pos[index];

    int3 gridPos = calcGridPos(make_float3(p.x, p.y, p.z));
    uint hash = calcGridHash(gridPos);

    gridParticleHash[index] = hash;
    gridParticleIndex[index] = index;
}

__global__
void reorderDataAndFindCellStartD(uint*   cellStart,        // output
							      uint*   cellEnd,          // output
							      float4* sortedPos,        // output
  							      float4* sortedVel,        // output
                                  uint *  gridParticleHash, // input
                                  uint *  gridParticleIndex,// input
				                  float4* oldPos,           // input
							      float4* oldVel,           // input
							      uint    numParticles)
{
	extern __shared__ uint sharedHash[];    // blockSize + 1 elements
    uint index = __umul24(blockIdx.x,blockDim.x) + threadIdx.x;
	
    uint hash;
    if (index < numParticles) {
        hash = gridParticleHash[index];

	    sharedHash[threadIdx.x+1] = hash;

	    if (index > 0 && threadIdx.x == 0)
	    {
		    sharedHash[0] = gridParticleHash[index-1];
	    }
	}

	__syncthreads();
	
	if (index < numParticles) {
	    if (index == 0 || hash != sharedHash[threadIdx.x])
	    {
		    cellStart[hash] = index;
            if (index > 0)
                cellEnd[sharedHash[threadIdx.x]] = index;
	    }

        if (index == numParticles - 1)
        {
            cellEnd[hash] = index + 1;
        }

	    uint sortedIndex = gridParticleIndex[index];
	    float4 pos = FETCH(oldPos, sortedIndex);       
        float4 vel = FETCH(oldVel, sortedIndex);       

        sortedPos[index] = pos;
        sortedVel[index] = vel;
	}
}

__device__
float sumParticlesInDomain(int3    gridPos,
                   uint    index,
                   float4  pos,				   
                   float4* oldPos, 
				   float4  vel,
				   float4* oldVel, 
                   uint*   cellStart,
                   uint*   cellEnd)
{
    uint gridHash = calcGridHash(gridPos);

    uint startIndex = FETCH(cellStart, gridHash);

    float sum = 0.0f;
    if (startIndex != 0xffffffff) {       
        uint endIndex = FETCH(cellEnd, gridHash);
        for(uint j=startIndex; j<endIndex; j++) {
            if (j != index) {             
	            float4 pos2 = FETCH(oldPos, j);
				float4 vel2 = FETCH(oldVel, j);				
				float3 relPos = make_float3(pos2 - pos); 
				float dist = length(relPos);

				 if(pos2.w == 0.0f)//todo: remove w usage
					 continue;

				if (dist < params.smoothingRadius) {					
					float wpolyExpr = pow(params.smoothingRadius,2)- pow(dist,2);
					sum += pow(wpolyExpr,3);																	
				}                
            }
        }
    }
    return sum;
}

__global__ 
void calcDensityAndPressureD(			
			float4* measures, //output
			float4* oldPos,	  //input 
			float4* oldVel,	  //input 
			uint* gridParticleIndex,
			uint* cellStart,
			uint* cellEnd,
			uint numParticles)
			
{
	uint index = __mul24(blockIdx.x,blockDim.x) + threadIdx.x;
    if (index >= numParticles) return;    

	float4 pos = FETCH(oldPos, index);
	float4 vel = FETCH(oldVel, index);

    int3 gridPos = calcGridPos(make_float3(pos));

    float sum = 0.0f;
	
    for(int z=-params.cellcount; z<=params.cellcount; z++) {
        for(int y=-params.cellcount; y<=params.cellcount; y++) {
            for(int x=-params.cellcount; x<=params.cellcount; x++) {
                int3 neighbourPos = gridPos + make_int3(x, y, z);
                sum += sumParticlesInDomain(neighbourPos, index, pos, oldPos, vel, oldVel, cellStart, cellEnd);
            }
        }
    }		
	float dens =  sum * params.particleMass * params.Poly6Kern;
    measures[index].x = dens;	
	measures[index].y =  params.B * (pow(dens / params.restDensity ,7.0f) - 1.0f); 		
}

__device__
float3 sumNavierStokesForces(int3    gridPos,
                   uint    index,
                   float4  pos,
                   float4* oldPos, 
				   float4  vel,
				   float4* oldVel,
				   float density,
				   float pressure,				   
				   float4* oldMeasures,
                   uint*   cellStart,
                   uint*   cellEnd)
{
    uint gridHash = calcGridHash(gridPos);

    uint startIndex = FETCH(cellStart, gridHash);
    
	float3 tmpForce = make_float3(0.0f);
	float texp = 0.0f;
	float pexp = 0.0f;
    if (startIndex != 0xffffffff) {               
        uint endIndex = FETCH(cellEnd, gridHash);
        for(uint j=startIndex; j<endIndex; j++) {
            if (j != index) {             
	            float4 pos2 = FETCH(oldPos, j);
				float4 vel2 = FETCH(oldVel, j);				
				float4 measure = FETCH(oldMeasures, j);
				float density2 = measure.x;
				float pressure2 = measure.y;								
				float3 relPos = make_float3(pos - pos2);
				float dist = length(relPos);
				float artViscosity = 0.0f;
				
				 if(pos2.w == 0.0f)//todo: remove w usage
				 {					 		
					float q = dist / params.particleRadius;
					float k = pow(params.soundspeed, 2);
					float3 coeff = k * (params.particleMass + params.particleMass) / params.particleMass 
						/ dist * normalize(relPos);					
					if((q >= 1.0f) && (q < 2.0f))
						tmpForce += coeff * 0.5f * pow(2.0f - q, 2);
					if((q >= 2.0f / 3.0f) && (q < 1.0f))
						tmpForce += coeff * (2.0f * q - 3.0f / 2 * q * q);
					if(q < 2.0f / 3.0f)
						tmpForce += coeff * 2.0f / 3.0f;	
					 continue;
				 }

				if (dist < params.smoothingRadius) {
					float temp = (params.smoothingRadius - dist);				
					float artViscosity = 0.0f;
					float vij_pij = dot(make_float3(vel - vel2),relPos);
					if(vij_pij < 0)
					{
						float nu = 2.0f * 0.18f * params.smoothingRadius *
							params.soundspeed / (density + density2);

						artViscosity = -1.0f * nu * vij_pij / 
							(dot(relPos, relPos) + 0.01f * pow(params.smoothingRadius, 2));
					}
					tmpForce +=  -1.0f * params.particleMass *
						(pressure / pow(density,2) + pressure2 / pow(density2,2) +
						artViscosity) * params.SpikyKern * normalize(relPos) * temp * temp;							
				}                
            }
        }
    }		
	return tmpForce;
}

__global__
void calcAndApplyAccelerationD(
			float4* acceleration,			
			float4* oldMeasures,
			float4* oldPos,			
			float4* oldVel,
			uint* gridParticleIndex,
			uint* cellStart,
			uint* cellEnd,
			uint numParticles)			
{
	uint index = __mul24(blockIdx.x,blockDim.x) + threadIdx.x;
    if (index >= numParticles) return;    

	float4 pos = FETCH(oldPos, index);
	float4 vel = FETCH(oldVel, index);
	float4 measure = FETCH(oldMeasures,index);
	float density = measure.x;
	float pressure = measure.y;

    int3 gridPos = calcGridPos(make_float3(pos));

    float3 force = make_float3(0.0f);	
    for(int z=-params.cellcount; z<=params.cellcount; z++) {
        for(int y=-params.cellcount; y<=params.cellcount; y++) {
            for(int x=-params.cellcount; x<=params.cellcount; x++) {
                int3 neighbourPos = gridPos + make_int3(x, y, z);
				if(pos.w == 1.0f)
				{
					force += sumNavierStokesForces(
						neighbourPos, 
						index, 
						pos, 
						oldPos,
						vel,
						oldVel,
						density,
						pressure,					
						oldMeasures,
						cellStart, 
						cellEnd);
				}else
				{
					force += make_float3(-0.1f,0.0f,0.0f);
				}
            }
        }
    }
	uint originalIndex = gridParticleIndex[index];						
	float3 acc = force;	
	acceleration[originalIndex] =  make_float4(acc, 0.0f);
}

__global__
void integrate(float4* posArray,		 // input, output
               float4* velArray,		 // input, output  
			   float4* velLeapFrogArray, // output
			   float4* acceleration,	 // input
               uint numParticles)
{
    uint index = __umul24(blockIdx.x,blockDim.x) + threadIdx.x;
    if (index >= numParticles) return;          

	volatile float4 posData = posArray[index]; 
    volatile float4 velData = velArray[index];
	volatile float4 accData = acceleration[index];
	volatile float4 velLeapFrogData = velLeapFrogArray[index];

    float3 pos = make_float3(posData.x, posData.y, posData.z);
    float3 vel = make_float3(velData.x, velData.y, velData.z);
	float3 acc = make_float3(accData.x, accData.y, accData.z);

	//float3 nextVel = vel + (params.gravity + acc) * params.deltaTime;
	float3 nextVel = vel + (params.gravity + acc) * params.deltaTime * velData.w; //todo: remove w usage
	//float3 nextVel = vel + acc * params.deltaTime * velData.w;

	float3 velLeapFrog = vel + nextVel;
	velLeapFrog *= 0.5;

    vel = nextVel;   	
    pos += vel * params.deltaTime;   

	float scale = params.gridSize.x * params.particleRadius;
	float bound = 2.0f * params.particleRadius * params.fluidParticlesSize.z - 1.0f * scale;	
	//float bound = 2.0f * params.particleRadius * (params.fluidParticlesSize.z + 6) - 1.0f * scale;		

	if (pos.x > 1.0f * scale - params.particleRadius) {
		pos.x = 1.0f * scale - params.particleRadius; vel.x *= params.boundaryDamping; }
    if (pos.x < -1.0f * scale + params.particleRadius) {
		pos.x = -1.0f * scale + params.particleRadius; vel.x *= params.boundaryDamping;}
    if (pos.y > 1.0f * scale - params.particleRadius) {
		pos.y = 1.0f * scale - params.particleRadius; vel.y *= params.boundaryDamping; }    
    if (pos.z > bound - params.particleRadius) {
		pos.z = bound - params.particleRadius; vel.z *= params.boundaryDamping; }
    if (pos.z < -1.0f * scale + params.particleRadius) {
		pos.z = -1.0f * scale + params.particleRadius; vel.z *= params.boundaryDamping;}
    if (pos.y < -1.0f * scale + params.particleRadius) {
		pos.y = -1.0f * scale + params.particleRadius; vel.y *= params.boundaryDamping;}		
    
    posArray[index] = make_float4(pos, posData.w);
    velArray[index] = make_float4(vel, velData.w);
	velLeapFrogArray[index] = make_float4(velLeapFrog, velLeapFrogData.w);
}
#endif
