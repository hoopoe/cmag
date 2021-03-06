#include <thrust/device_ptr.h>
#include <thrust/device_vector.h>
#include <vector_functions.h>
#include <iostream>
#include <fstream>
#include <sstream>
#include <queue>
#include <math.h>

#include "../Poiseuille.Core/poiseuilleFlowSystem.h"

using namespace std;
using namespace thrust;

void dump() 
{
	int boundaryOffset = 3;	
	uint3 gridSize = make_uint3(16, 64, 4);    	
	float radius = 1.0f / (2 * (gridSize.y - 2 * boundaryOffset) * 1000);	
	uint3 fluidParticlesSize = make_uint3(gridSize.x, gridSize.y -  2 * boundaryOffset, 1);	       

	PoiseuilleFlowSystem *psystem = new PoiseuilleFlowSystem(
		fluidParticlesSize,
		boundaryOffset, 
		gridSize, 
		radius,
		false); 	
	psystem->reset();		

	uint numParticles = psystem->getNumParticles();		

	host_vector<float4> position(numParticles);			
	host_vector<float4> velocity(numParticles);
	host_vector<uint> index(numParticles);

	device_ptr<float4> d_position((float4*)psystem->getCudaPosVBO());	
	device_ptr<float4> d_velocity((float4*)psystem->getCudaVelVBO());
	device_ptr<uint> d_index((uint*)psystem->getCudaIndex());	
	

	std::queue<float>  timeFrames;			
	timeFrames.push(0.0225f);
	timeFrames.push(0.045f);
	timeFrames.push(0.1125f);
	timeFrames.push(0.225f);
	timeFrames.push(1.0f);	

	while (!(timeFrames.empty())){
		float timeSlice = timeFrames.front();
		timeFrames.pop();

		while(psystem->getElapsedTime() < timeSlice)
			psystem->update();

		thrust::copy(d_position, d_position + numParticles, position.begin());	
		thrust::copy(d_index, d_index + numParticles, index.begin());			
		thrust::copy(d_velocity, d_velocity + numParticles, velocity.begin());			

		ostringstream buffer;	
		buffer << timeSlice;
		//string str = "XVelocityYPosition" + buffer.str().replace(1,1,"x");// + ".dat";
		string str = "XVelocityYPosition" + buffer.str() + ".dat";
		ofstream fp1;	
		
		fp1.open(str.c_str());
		//fp1 << "velocity X " << "position Y" << endl;
		fp1 << "0.0 " << "0.0" << endl;
		for(int i = 0; i < position.size(); i++){			
			if((position[i].x > 0) 
				&& (position[i].x < 2 * radius)){
					if(position[i].w == 0.0f){//fluid
						fp1 << velocity[i].x << " "
							<< position[i].y 
							+ fabs(psystem->getWorldOrigin().y)
							- boundaryOffset * 2 * radius
							<< endl;
					}else{
						//cout << "boundary " << i<< endl;
					}
			}
		}	
		fp1 << "0.000000 " << "0.001000" << endl;
		fp1.close();
	}	
	delete psystem;
}
