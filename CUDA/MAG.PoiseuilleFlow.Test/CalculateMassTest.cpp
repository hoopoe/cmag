//#include <boost/test/unit_test.hpp>
//#include <boost/format.hpp>
//#include <thrust/device_ptr.h>
//#include <thrust/device_vector.h>
//#include <vector_types.h>
//#include <vector_functions.h>
//#include <iostream>
//#include <math.h>
//#include "poiseuilleFlowSystem.cuh"
//#include "poiseuilleFlowSystem.h"
//#include "magUtil.cuh"
//using namespace std;
//using namespace thrust;
//
//BOOST_FIXTURE_TEST_SUITE(CalculateMass)
//
//BOOST_AUTO_TEST_CASE(CalculateMass)
//{	
//	int boundaryOffset = 3;	
//	float soundspeed = powf(10.0f, -4.0f);		
//	float3 gravity = make_float3(0.0f, 0.0f, 0.0f); 
//	float radius = 1.0f / (2 * (64 - 2 * boundaryOffset) * 1000);
//	//float radius = 1.0f / 300;
//	uint3 gridSize = make_uint3(8, 8, 4);   			
//	uint3 fluidParticlesSize = make_uint3(8, 8 -  2 * boundaryOffset, 1);
//	float delaTime = powf(10.0f, -4.0f);
//	PoiseuilleFlowSystem *psystem = new PoiseuilleFlowSystem(
//			delaTime,
//			fluidParticlesSize,
//			0,0,0,
//			soundspeed,
//			gravity,
//			boundaryOffset, 
//			gridSize,								
//			radius,
//			false);
//
//	uint numParticles = psystem->getNumParticles();		
//	psystem->reset();				
//	psystem->update();							
//
//	host_vector<float4> hPositions(numParticles);
//	host_vector<float4> hResult(numParticles);
//	host_vector<uint> hHash(numParticles);
//	host_vector<uint> hIndex(numParticles);
//
//	device_ptr<float4> positions((float4*)psystem->getCudaPosVBO());		
//	device_ptr<float4> result((float4*)psystem->getMeasures());
//	//getMeasures getPressureForce getPredictedPos getdViscousForce
//	device_ptr<uint> hash((uint*)psystem->getCudaHash());		
//	device_ptr<uint> index((uint*)psystem->getCudaIndex());	
//
//	thrust::copy(positions, positions + numParticles, hPositions.begin());		
//	thrust::copy(result, result + numParticles, hResult.begin());		
//	thrust::copy(hash, hash + numParticles, hHash.begin());		
//	thrust::copy(index, index + numParticles, hIndex.begin());		
//	
//
//	float sum = 0.0f;
//	for(uint i = 0; i < numParticles; i++){					
//			cout 
//			<< hResult[i].x << " "			
//			<< hPositions[hIndex[i]].w << " "
//			<< endl;
//	}
//
//	//cout << sum;
//
//	//double sum = 0.0f;
//	//int cx = 0;
//	//for(uint i = 0; i < psystem->getNumParticles(); i++) 
//	//{	
//	//	//cout << cx++ <<" "<< hPos[4*hIndex[i]+3]	 << endl;
//	//	if(hPos[4 * hIndex[i] + 3] == 0.0f){		
//	//		sum += htemp[4 * i + 0];
//	//		printf("%d id=%d (%d %2d) %f %f %f w=%f\n", 
//	//				cx++,
//	//				i,
//	//				hHash[i],
//	//				hIndex[i],						
//	//				htemp[4*i+0],
//	//				htemp[4*i+1],
//	//				htemp[4*i+2],
//	//				hPos[4 * hIndex[i] + 3]					
//	//			);		
//	//	}
//	//}	
//	//printf("%d %d %f ---------------------\n",psystem->getNumParticles(), cx, sum / cx);		
//	
//	delete psystem;
//}
//BOOST_AUTO_TEST_SUITE_END()