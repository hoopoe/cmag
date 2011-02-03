#ifndef _FLUID_KERNEL_CUH
#define _FLUID_KERNEL_CUH

#ifndef __DEVICE_EMULATION__
#define USE_TEX 1
#endif

#if USE_TEX
#define FETCH(t, i) tex1Dfetch(t##Tex, i)
#else
#define FETCH(t, i) t[i]
#endif

#include "vector_types.h"
typedef unsigned int uint;

struct SimParams {     
	uint3 gridSize;
	float3 worldOrigin;
    float3 cellSize;
	uint3 fluidParticlesSize;
	int cellcount; //how many neigbours cell to look

    float3 gravity;    
    float particleRadius;        		        
	float smoothingRadius;
	float particleMass;
	float restDensity;
	float soundspeed;
	float B;//Equation of state    
	
	float Poly6Kern;
	float SpikyKern;		
	float deltaTime;		
	float boundaryDamping;	
};

#endif