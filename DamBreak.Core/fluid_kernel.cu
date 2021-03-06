#include <stdio.h>
#include <math.h>
#include "../Common/helper_math.h"
#include "math_constants.h"
#include "fluid_kernel.cuh"

#if USE_TEX
texture<float4, 1, cudaReadModeElementType> oldPosTex;
texture<float4, 1, cudaReadModeElementType> oldVelTex;
texture<float4, 1, cudaReadModeElementType> oldMeasuresTex;
texture<float4, 1, cudaReadModeElementType> oldVariationsTex;

texture<uint, 1, cudaReadModeElementType> gridParticleHashTex;
texture<uint, 1, cudaReadModeElementType> cellStartTex;
texture<uint, 1, cudaReadModeElementType> cellEndTex;
#endif
__constant__ SimParams params;

__device__ int3 calcGridPos(float3 p){
	int3 gridPos;
	gridPos.x = floor((p.x - params.worldOrigin.x) / params.cellSize.x);
	gridPos.y = floor((p.y - params.worldOrigin.y) / params.cellSize.y);
	gridPos.z = floor((p.z - params.worldOrigin.z) / params.cellSize.z);
	return gridPos;
}

__device__ uint calcGridHash(int3 gridPos){
	gridPos.x = gridPos.x & (params.gridSize.x-1);  
	gridPos.y = gridPos.y & (params.gridSize.y-1);
	gridPos.z = gridPos.z & (params.gridSize.z-1);        
	return __umul24(__umul24(gridPos.z, params.gridSize.y), params.gridSize.x) + __umul24(gridPos.y, params.gridSize.x) + gridPos.x;
}

__global__ void calcHashD(
	uint*   gridParticleHash,  // output
	uint*   gridParticleIndex, // output
	float4* pos,               // input
	uint    numParticles){
		uint index = __umul24(blockIdx.x, blockDim.x) + threadIdx.x;
		if (index >= numParticles) return;			    
		volatile float4 p = pos[index];		

		int3 gridPos = calcGridPos(make_float3(p.x, p.y, p.z));
		uint hash = calcGridHash(gridPos);

		gridParticleHash[index] = hash;
		gridParticleIndex[index] = index;
}

__global__ void reorderDataAndFindCellStartD(
	uint*   cellStart,        // output
	uint*   cellEnd,          // output
	float4* sortedPos,        // output
	float4* sortedVel,        // output
	uint *  gridParticleHash, // input
	uint *  gridParticleIndex,// input
	float4* oldPos,           // input
	float4* oldVel,           // input
	uint    numParticles){
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

__device__ float sumDensity(
	int3    gridPos,
	uint    index,
	float3  pos,
	float4* oldPos, 
	uint*   cellStart,
	uint*   cellEnd){
		uint gridHash = calcGridHash(gridPos);
		uint startIndex = FETCH(cellStart, gridHash);

		float sum = 0.0f;
		if (startIndex != 0xffffffff) {        // cell is not empty
			uint endIndex = FETCH(cellEnd, gridHash);
			for(uint j=startIndex; j<endIndex; j++) {	
					float4 post = FETCH(oldPos, j);
					//if(post.w < RightSecondType) // RightFirstType + FirstType
					//	continue;

					float3 pos2 = make_float3(post);						
					float3 relPos = pos - pos2;
					float dist = length(relPos);
					float q = dist / params.smoothingRadius;									
					float coeff = 7.0f / 4 / CUDART_PI_F / powf(params.smoothingRadius, 2);
					if(q < 2){
						sum += coeff *(powf(1 - 0.5f * q, 4) * (2 * q + 1));	
					}
			}
		}
		return sum;
}

__global__ void calculateDamBreakDensityD(			
	float4* measuresOutput, //output
	float4* oldMeasures, //input
	float4* oldPos,	  //input 
	float4* oldVel,   //input
	uint* gridParticleIndex,
	uint* cellStart,
	uint* cellEnd,
	uint numParticles){
		uint index = __mul24(blockIdx.x,blockDim.x) + threadIdx.x;
		if (index >= numParticles) return;    

		float4 pos1 = FETCH(oldPos, index);
		/*if(pos1.w < RightSecondType) 
			return;*/
		float3 pos = make_float3(pos1);

		//float3 pos = make_float3(FETCH(oldPos, index));	
		float3 vel = make_float3(FETCH(oldVel, index));
		int3 gridPos = calcGridPos(pos);

		float sum = 0.0f;		
		for(int z=-params.cellcount; z<=params.cellcount; z++) {
			for(int y=-params.cellcount; y<=params.cellcount; y++) {
				for(int x=-params.cellcount; x<=params.cellcount; x++) {
					int3 neighbourPos = gridPos + make_int3(x, y, z);
					sum += sumDensity(
						neighbourPos,
						index,
						pos,
						oldPos,
						cellStart,
						cellEnd);
				}
			}
		}					
		float dens = sum * params.particleMass;
		measuresOutput[index].x = dens;	
		measuresOutput[index].y = params.B * (powf(dens / params.restDensity ,params.gamma) - 1.0f);
}


__device__ float3 sumNavierStokesForces(
	int3    gridPos,
	uint    index,
	float3  pos,
	float4* oldPos, 
	float3  vel,
	float4* oldVel,
	float density,
	float pressure,				   
	float4* oldMeasures,
	uint*   cellStart,
	uint*   cellEnd){
		uint gridHash = calcGridHash(gridPos);
		uint startIndex = FETCH(cellStart, gridHash);
	    
		float3 tmpForce = make_float3(0.0f);
		float texp = 0.0f;
		float pexp = 0.0f;
		if (startIndex != 0xffffffff) {               
			uint endIndex = FETCH(cellEnd, gridHash);
			for(uint j=startIndex; j<endIndex; j++) {
				if (j != index) {             

					float4 post = FETCH(oldPos, j);
					float3 pos2 = make_float3(post);
					//if(post.w  < RightSecondType) 

					if(post.w != Fluid) 
					{
						float3 relPos = pos - pos2;
						float dist = length(relPos);
						
						tmpForce += params.D * (powf(params.a / dist, 12)
							- powf(params.a / dist, 6)) * relPos / powf(dist, 2);						
						
						continue;
					}					

					//float3 pos2 = make_float3(FETCH(oldPos, j));
					float3 vel2 = make_float3(FETCH(oldVel, j));				
					float4 measure = FETCH(oldMeasures, j);
					float density2 = measure.x;
					float pressure2 = measure.y;				
					float tempExpr = 0.0f;

					float3 relPos = pos - pos2;
					float dist = length(relPos);				

					float q = dist / params.smoothingRadius;		
					float temp = 0.0f;
					float coeff = 7.0f / 2 / CUDART_PI_F / powf(params.smoothingRadius, 3);
					if(q < 2){
						temp = coeff * (-powf(1 - 0.5f * q,3) * (2 * q + 1) +powf(1 - 0.5f * q, 4));
						float artViscosity = 0.0f;
						float vij_pij = dot((vel - vel2),relPos);
						
						if(vij_pij < 0){						
							float nu = 2.0f * 0.38f * params.smoothingRadius *
								params.soundspeed / (density + density2);

							artViscosity = -1.0f * nu * vij_pij / 
								(dot(relPos, relPos) + 0.001f * pow(params.smoothingRadius, 2));
						}
						tmpForce +=  -1.0f * params.particleMass *
							(pressure / pow(density,2) + pressure2 / pow(density2,2) +
							artViscosity) * normalize(relPos) * temp;						
					}        
				}
			}
		}
		return tmpForce;				
}

__global__ void calcAndApplyAccelerationD(
	float4* acceleration,			
	float4* oldMeasures,
	float4* oldPos,			
	float4* oldVel,
	uint* gridParticleIndex,
	uint* cellStart,
	uint* cellEnd,
	uint numParticles){
		uint index = __mul24(blockIdx.x,blockDim.x) + threadIdx.x;
		if (index >= numParticles) return;    

		float4 pos1 = FETCH(oldPos, index);
		if(pos1.w != Fluid) 
			return;
		float3 pos = make_float3(pos1);

		//float3 pos = make_float3(FETCH(oldPos, index));
		float3 vel = make_float3(FETCH(oldVel, index));
		float4 measure = FETCH(oldMeasures,index);
		float density = measure.x;
		float pressure = measure.y;

		int3 gridPos = calcGridPos(pos);

		float3 force = make_float3(0.0f);	
		for(int z=-params.cellcount; z<=params.cellcount; z++) {
			for(int y=-params.cellcount; y<=params.cellcount; y++) {
				for(int x=-params.cellcount; x<=params.cellcount; x++) {
					int3 neighbourPos = gridPos + make_int3(x, y, z);
					force += sumNavierStokesForces(neighbourPos, 
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
				}
			}
		}
		uint originalIndex = gridParticleIndex[index];					
		float3 acc = force;			
		acceleration[originalIndex] =  make_float4(acc, 0.0f);
}

__global__ void shiftRightBoundaryD(
	float4* posArray,		 
	uint numParticles){
		uint index = __umul24(blockIdx.x,blockDim.x) + threadIdx.x;
		if (index >= numParticles) return;          		
		
		volatile float4 posData = posArray[index]; 
		if((posData.w != RightFirstType) && (posData.w != RightSecondType))
			return;

		float halfWorldXSize = params.fluidParticlesSize.x * 2 * params.particleRadius;				
		posArray[index] = make_float4(posData.x + halfWorldXSize, posData.y, posData.z, posData.w);
}

__global__ void removeRightBoundaryD(
	float4* posArray,		 
	uint numParticles){
		uint index = __umul24(blockIdx.x,blockDim.x) + threadIdx.x;
		if (index >= numParticles) return;          		
		
		volatile float4 posData = posArray[index]; 
		if((posData.w != RightFirstType) && (posData.w != RightSecondType))
			return;

		float fluidWidth = params.fluidParticlesSize.x * 2 * params.particleRadius;				
		float height = params.gridSize.y * 2 * params.particleRadius;
		posArray[index] = make_float4(fluidWidth, height, posData.z, posData.w);
}

__global__ void integrate(
	float4* posArray,		 // input, output
	float4* velArray,		 // input, output  
	float4* velLeapFrogArray, // output
	float4* acceleration,	 // input
	uint numParticles){
		uint index = __umul24(blockIdx.x,blockDim.x) + threadIdx.x;
		if (index >= numParticles) return;          		

		volatile float4 posData = posArray[index]; 
		volatile float4 velData = velArray[index];
		volatile float4 accData = acceleration[index];
		volatile float4 velLeapFrogData = velLeapFrogArray[index];

		if(posData.w != Fluid)
			return;

		float3 pos = make_float3(posData.x, posData.y, posData.z);
		float3 vel = make_float3(velData.x, velData.y, velData.z);
		float3 acc = make_float3(accData.x, accData.y, accData.z);

		float3 nextVel = vel + (params.gravity + acc) * params.deltaTime;

		float3 velLeapFrog = vel + nextVel;
		velLeapFrog *= 0.5;

		vel = nextVel;   	
		pos += vel * params.deltaTime;   

		float leftBorder = params.worldOrigin.x + params.boundaryOffset * 2 * params.particleRadius;		
		float bottomBorder = params.worldOrigin.y + params.boundaryOffset * 2 * params.particleRadius;	
		
		if (pos.x < leftBorder){
			pos.x = leftBorder; vel.x *= params.boundaryDamping;}
		if (pos.x > params.rightBoundary) {
			pos.x = params.rightBoundary; vel.x *= params.boundaryDamping;}

		if (pos.y < bottomBorder){
			pos.y = bottomBorder; vel.y *= params.boundaryDamping;}	
	    
		posArray[index] = make_float4(pos, posData.w);
		velArray[index] = make_float4(vel, velData.w);
		velLeapFrogArray[index] = make_float4(velLeapFrog, velLeapFrogData.w);
}
