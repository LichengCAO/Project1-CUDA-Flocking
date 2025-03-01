#define GLM_FORCE_CUDA
#include <stdio.h>
#include <cuda.h>
#include <cmath>
#include <glm/glm.hpp>
#include "utilityCore.hpp"
#include <device_launch_parameters.h>//https://blog.csdn.net/xianhua7877/article/details/83830855
#include "kernel.h"

// LOOK-2.1 potentially useful for doing grid-based neighbor search
#ifndef imax
#define imax( a, b ) ( ((a) > (b)) ? (a) : (b) )
#endif

#ifndef imin
#define imin( a, b ) ( ((a) < (b)) ? (a) : (b) )
#endif

#define checkCUDAErrorWithLine(msg) checkCUDAError(msg, __LINE__)

/**
* Check for CUDA errors; print and exit if there was a problem.
*/
void checkCUDAError(const char *msg, int line = -1) {
  cudaError_t err = cudaGetLastError();
  if (cudaSuccess != err) {
    if (line >= 0) {
      fprintf(stderr, "Line %d: ", line);
    }
    fprintf(stderr, "Cuda error: %s: %s.\n", msg, cudaGetErrorString(err));
    exit(EXIT_FAILURE);
  }
}


/*****************
* Configuration *
*****************/

/*! Block size used for CUDA kernel launch. */
#define blockSize 128

// LOOK-1.2 Parameters for the boids algorithm.
// These worked well in our reference implementation.
#define rule1Distance 5.0f
#define rule2Distance 3.0f
#define rule3Distance 5.0f

#define rule1Scale 0.01f
#define rule2Scale 0.1f
#define rule3Scale 0.1f

#define maxSpeed 1.0f

/*! Size of the starting area in simulation space. */
#define scene_scale 100.0f

/***********************************************
* Kernel state (pointers are device pointers) *
***********************************************/

int numObjects;
dim3 threadsPerBlock(blockSize);

// LOOK-1.2 - These buffers are here to hold all your boid information.
// These get allocated for you in Boids::initSimulation.
// Consider why you would need two velocity buffers in a simulation where each
// boid cares about its neighbors' velocities.
// These are called ping-pong buffers.
glm::vec3 *dev_pos;//for coherent part unarranged
glm::vec3* dev_pos2;//for coherent part arranged
glm::vec3 *dev_vel1;//for coherent part arranged
glm::vec3 *dev_vel2;//for coherent part unarranged

cudaEvent_t dev_frameStart;
cudaEvent_t dev_frameEnd;
float timeElapsed = 0.f;
float frameCnt = 0.f;


// LOOK-2.1 - these are NOT allocated for you. You'll have to set up the thrust
// pointers on your own too.

// For efficient sorting and the uniform grid. These should always be parallel.
int *dev_particleArrayIndices; // What index in dev_pos and dev_velX represents this particle?
int *dev_particleGridIndices; // What grid cell is this particle in?
// needed for use with thrust
thrust::device_ptr<int> dev_thrust_particleArrayIndices;
thrust::device_ptr<int> dev_thrust_particleGridIndices;

int *dev_gridCellStartIndices; // What part of dev_particleArrayIndices belongs
int *dev_gridCellEndIndices;   // to this cell?

// TODO-2.3 - consider what additional buffers you might need to reshuffle
// the position and velocity data to be coherent within cells.

// LOOK-2.1 - Grid parameters based on simulation parameters.
// These are automatically computed for you in Boids::initSimulation
int gridCellCount;
int gridSideCount;
float gridCellWidth;
float gridInverseCellWidth;
glm::vec3 gridMinimum;

/******************
* initSimulation *
******************/

__host__ __device__ unsigned int hash(unsigned int a) {
  a = (a + 0x7ed55d16) + (a << 12);
  a = (a ^ 0xc761c23c) ^ (a >> 19);
  a = (a + 0x165667b1) + (a << 5);
  a = (a + 0xd3a2646c) ^ (a << 9);
  a = (a + 0xfd7046c5) + (a << 3);
  a = (a ^ 0xb55a4f09) ^ (a >> 16);
  return a;
}

/**
* LOOK-1.2 - this is a typical helper function for a CUDA kernel.
* Function for generating a random vec3.
*/
__host__ __device__ glm::vec3 generateRandomVec3(float time, int index) {
  thrust::default_random_engine rng(hash((int)(index * time)));
  thrust::uniform_real_distribution<float> unitDistrib(-1, 1);

  return glm::vec3((float)unitDistrib(rng), (float)unitDistrib(rng), (float)unitDistrib(rng));
}

/**
* LOOK-1.2 - This is a basic CUDA kernel.
* CUDA kernel for generating boids with a specified mass randomly around the star.
*/
__global__ void kernGenerateRandomPosArray(int time, int N, glm::vec3 * arr, float scale) {
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (index < N) {
    glm::vec3 rand = generateRandomVec3(time, index);
    arr[index].x = scale * rand.x;
    arr[index].y = scale * rand.y;
    arr[index].z = scale * rand.z;
  }
}

/**
* Initialize memory, update some globals
*/
void Boids::initSimulation(int N) {
  numObjects = N;
  dim3 fullBlocksPerGrid((N + blockSize - 1) / blockSize);

  // LOOK-1.2 - This is basic CUDA memory management and error checking.
  // Don't forget to cudaFree in  Boids::endSimulation.
  cudaMalloc((void**)&dev_pos, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_pos failed!");

  cudaMalloc((void**)&dev_vel1, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_vel1 failed!");

  cudaMalloc((void**)&dev_vel2, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_vel2 failed!");

  // LOOK-1.2 - This is a typical CUDA kernel invocation.
  kernGenerateRandomPosArray<<<fullBlocksPerGrid, blockSize>>>(1, numObjects,
    dev_pos, scene_scale);
  checkCUDAErrorWithLine("kernGenerateRandomPosArray failed!");

  // LOOK-2.1 computing grid params
  gridCellWidth = 2.0f * std::max(std::max(rule1Distance, rule2Distance), rule3Distance);
  int halfSideCount = (int)(scene_scale / gridCellWidth) + 1;
  gridSideCount = 2 * halfSideCount;

  gridCellCount = gridSideCount * gridSideCount * gridSideCount;
  gridInverseCellWidth = 1.0f / gridCellWidth;
  float halfGridWidth = gridCellWidth * halfSideCount;
  gridMinimum.x -= halfGridWidth;
  gridMinimum.y -= halfGridWidth;
  gridMinimum.z -= halfGridWidth;

  // TODO-2.1 TODO-2.3 - Allocate additional buffers here.
  cudaMalloc((void**)&dev_particleGridIndices, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_particleGridIndices failed!");

  cudaMalloc((void**)&dev_particleArrayIndices, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_particleArrayIndices failed!");

  cudaMalloc((void**)&dev_gridCellStartIndices, gridCellCount * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_gridCellStartIndices failed!");

  cudaMalloc((void**)&dev_gridCellEndIndices, gridCellCount * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_gridCellEndIndices failed!");

  cudaMalloc((void**)&dev_pos2, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_pos2 failed!");

  //Cuda event generation
  cudaEventCreate(&dev_frameStart);
  checkCUDAErrorWithLine("cudaMalloc dev_frameStart failed!");
  cudaEventCreate(&dev_frameEnd);
  checkCUDAErrorWithLine("cudaMalloc dev_frameEnd failed!");

  cudaDeviceSynchronize();
}

void Boids::endSimulation() {
    cudaFree(dev_vel1);
    cudaFree(dev_vel2);
    cudaFree(dev_pos);

    // TODO-2.1 TODO-2.3 - Free any additional buffers here.
    cudaFree(dev_particleGridIndices);
    cudaFree(dev_particleArrayIndices);
    cudaFree(dev_gridCellStartIndices);
    cudaFree(dev_gridCellEndIndices);
    cudaFree(dev_pos2);

    cudaEventDestroy(dev_frameStart);
    cudaEventDestroy(dev_frameEnd);

    if(frameCnt>0)std::cout << "average gpu time per frame: " << timeElapsed/frameCnt << " ms" << std::endl;
}
/******************
* copyBoidsToVBO *
******************/

/**
* Copy the boid positions into the VBO so that they can be drawn by OpenGL.
*/
__global__ void kernCopyPositionsToVBO(int N, glm::vec3 *pos, float *vbo, float s_scale) {
  int index = threadIdx.x + (blockIdx.x * blockDim.x);

  float c_scale = -1.0f / s_scale;

  if (index < N) {
    vbo[4 * index + 0] = pos[index].x * c_scale;
    vbo[4 * index + 1] = pos[index].y * c_scale;
    vbo[4 * index + 2] = pos[index].z * c_scale;
    vbo[4 * index + 3] = 1.0f;
  }
}

__global__ void kernCopyVelocitiesToVBO(int N, glm::vec3 *vel, float *vbo, float s_scale) {
  int index = threadIdx.x + (blockIdx.x * blockDim.x);

  if (index < N) {
    vbo[4 * index + 0] = vel[index].x + 0.3f;
    vbo[4 * index + 1] = vel[index].y + 0.3f;
    vbo[4 * index + 2] = vel[index].z + 0.3f;
    vbo[4 * index + 3] = 1.0f;
  }
}

/**
* Wrapper for call to the kernCopyboidsToVBO CUDA kernel.
*/
void Boids::copyBoidsToVBO(float *vbodptr_positions, float *vbodptr_velocities) {
  dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);

  kernCopyPositionsToVBO << <fullBlocksPerGrid, blockSize >> >(numObjects, dev_pos, vbodptr_positions, scene_scale);
  kernCopyVelocitiesToVBO << <fullBlocksPerGrid, blockSize >> >(numObjects, dev_vel1, vbodptr_velocities, scene_scale);

  checkCUDAErrorWithLine("copyBoidsToVBO failed!");

  cudaDeviceSynchronize();
}


/******************
* stepSimulation *
******************/

/**
* LOOK-1.2 You can use this as a helper for kernUpdateVelocityBruteForce.
* __device__ code can be called from a __global__ context
* Compute the new velocity on the body with index `iSelf` due to the `N` boids
* in the `pos` and `vel` arrays.
*/
__device__ glm::vec3 computeVelocityChange(int N, int iSelf, const glm::vec3 *pos, const glm::vec3 *vel) {
    glm::vec3 myVel = vel[iSelf];
    glm::vec3 myPos = pos[iSelf];
    glm::vec3 rule1 = glm::vec3(0.f);
    glm::vec3 rule2 = glm::vec3(0.f);
    glm::vec3 rule3 = glm::vec3(0.f);
    float rule1Cnt = 0;
    float rule3Cnt = 0;
    for (int i = 0;i < N;++i) {
        glm::vec3 nPos = pos[i];
        glm::vec3 nVel = vel[i];
        float dist = glm::distance(nPos, myPos);
        if (dist < rule1Distance) {
            // Rule 1: boids fly towards their local perceived center of mass, which excludes themselves
            rule1 += nPos;
            ++rule1Cnt;
        }
        if (dist < rule2Distance) {
            // Rule 2: boids try to stay a distance d away from each other
            rule2 += (myPos - nPos);
        }
        if (dist < rule3Distance) {
            // Rule 3: boids try to match the speed of surrounding boids
            rule3 += nVel;
            ++rule3Cnt;
        }
    }
    rule1 /= rule1Cnt;
    rule1 = (rule1 - myPos) * rule1Scale;
    rule2 *= rule2Scale;
    rule3 = rule3 / rule3Cnt * rule3Scale;
    return rule1 + rule2 + rule3;
}

/**
* TODO-1.2 implement basic flocking
* For each of the `N` bodies, update its position based on its current velocity.
*/
__global__ void kernUpdateVelocityBruteForce(int N, glm::vec3 *pos,
  glm::vec3 *vel1, glm::vec3 *vel2) {
  // Compute a new velocity based on pos and vel1
    int iSelf = blockDim.x * blockIdx.x + threadIdx.x;
    if (iSelf >= N)return;
  // Clamp the speed
    glm::vec3 newVel = vel1[iSelf] + computeVelocityChange(N, iSelf, pos, vel1);
    float speed = glm::length(newVel);
    if (speed > maxSpeed) {
        newVel = newVel / speed * maxSpeed;
    }
  // Record the new velocity into vel2. Question: why NOT vel1?
    vel2[iSelf] = newVel;
}

/**
* LOOK-1.2 Since this is pretty trivial, we implemented it for you.
* For each of the `N` bodies, update its position based on its current velocity.
*/
__global__ void kernUpdatePos(int N, float dt, glm::vec3 *pos, glm::vec3 *vel) {
  // Update position by velocity
  int index = threadIdx.x + (blockIdx.x * blockDim.x);
  if (index >= N) {
    return;
  }
  glm::vec3 thisPos = pos[index];
  thisPos += vel[index] * dt;

  // Wrap the boids around so we don't lose them
  thisPos.x = thisPos.x < -scene_scale ? scene_scale : thisPos.x;
  thisPos.y = thisPos.y < -scene_scale ? scene_scale : thisPos.y;
  thisPos.z = thisPos.z < -scene_scale ? scene_scale : thisPos.z;

  thisPos.x = thisPos.x > scene_scale ? -scene_scale : thisPos.x;
  thisPos.y = thisPos.y > scene_scale ? -scene_scale : thisPos.y;
  thisPos.z = thisPos.z > scene_scale ? -scene_scale : thisPos.z;

  pos[index] = thisPos;
}

// LOOK-2.1 Consider this method of computing a 1D index from a 3D grid index.
// LOOK-2.3 Looking at this method, what would be the most memory efficient
//          order for iterating over neighboring grid cells?
//          for(x)
//            for(y)
//             for(z)? Or some other order?
__device__ int gridIndex3Dto1D(int x, int y, int z, int gridResolution) {
  return x + y * gridResolution + z * gridResolution * gridResolution;
}

__global__ void kernComputeIndices(int N, int gridResolution,
  glm::vec3 gridMin, float inverseCellWidth,
  glm::vec3 *pos, int *indices, int *gridIndices) {
    // TODO-2.1
    // - Label each boid with the index of its grid cell.
    // - Set up a parallel array of integer indices as pointers to the actual
    //   boid data in pos and vel1/vel2
    int iSelf = blockDim.x * blockIdx.x + threadIdx.x;
    if (iSelf >= N)return;
    glm::vec3 myPos = pos[iSelf];
    glm::vec3 gridId = (myPos - gridMin) * inverseCellWidth;
    //to make sure consider the right grid in finding neighbors
    // |       |       |
    // |    *******    |
    // |----*******----|
    // |    *******    | 
    // |       |       |
    // only boids in * should be marked in LL grid
    gridId = glm::clamp(gridId - glm::vec3(0.5f), glm::vec3(0.f), glm::vec3(gridResolution));
    indices[iSelf] = iSelf;
    gridIndices[iSelf] = gridIndex3Dto1D(int(gridId.x), int(gridId.y), int(gridId.z), gridResolution);
}

// LOOK-2.1 Consider how this could be useful for indicating that a cell
//          does not enclose any boids
__global__ void kernResetIntBuffer(int N, int *intBuffer, int value) {
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (index < N) {
    intBuffer[index] = value;
  }
}

__global__ void kernIdentifyCellStartEnd(int N, int *particleGridIndices,
  int *gridCellStartIndices, int *gridCellEndIndices) {
  // TODO-2.1
  // Identify the start point of each cell in the gridIndices array.
  // This is basically a parallel unrolling of a loop that goes
  // "this index doesn't match the one before it, must be a new cell!"
    //index: 0  1  2  3  4  5  6 ...//length = N
    //grid:  0  0  0  1  2  2  3 ...//length = N
    //boid:  2  3  1  4  5  6  7 ...//length = N
    //start: 0  3  4  6 ...         //length = grid count
    //end:   2  3  5  ...           //length = grid count
    int index = (blockDim.x * blockIdx.x) + threadIdx.x;
    if (N <= index)return;
    int curGrid = particleGridIndices[index];
    bool isStart = index == 0 || particleGridIndices[index - 1] != curGrid;
    bool isEnd = ((index + 1) == N) || particleGridIndices[index + 1] != curGrid;
    if (isStart) {
        gridCellStartIndices[curGrid] = index;
    }
    if (isEnd) {
        gridCellEndIndices[curGrid] = index + 1;
    }
}

__global__ void kernUpdateVelNeighborSearchScattered(
  int N, int gridResolution, glm::vec3 gridMin,
  float inverseCellWidth, float cellWidth,
  int *gridCellStartIndices, int *gridCellEndIndices,
  int *particleArrayIndices,
  glm::vec3 *pos, glm::vec3 *vel1, glm::vec3 *vel2) {
  // TODO-2.1 - Update a boid's velocity using the uniform grid to reduce
  // the number of boids that need to be checked.
  // - Identify the grid cell that this particle is in
    int iSelf = blockDim.x * blockIdx.x + threadIdx.x;
    if (iSelf >= N)return;
    int boidId = particleArrayIndices[iSelf]; 
    glm::vec3 myPos = pos[boidId];
    glm::vec3 gridPos = (myPos - gridMin) * inverseCellWidth;
    //to make sure consider the right grid in finding neighbors
    // |       |       |
    // |    *******    |
    // |----*******----|
    // |    *******    | 
    // |       |       |
    // only boids in * should be marked in LL grid
    gridPos = glm::clamp(gridPos - glm::vec3(0.5f), glm::vec3(0.f), glm::vec3(gridResolution));
    int gridX = int(gridPos.x); int gridY = int(gridPos.y); int gridZ = int(gridPos.z);
    int gridId = gridIndex3Dto1D(gridX,gridY,gridZ, gridResolution);
    
  // - Identify which cells may contain neighbors. This isn't always 8.
  // - For each cell, read the start/end indices in the boid pointer array.
  // - Access each boid in the cell and compute velocity change from
  //   the boids rules, if this boid is within the neighborhood distance.
	int dx[] = { 0, 1, 0, 1, 0, 1, 0, 1 };
	int dy[] = { 0, 0, 1, 1, 0, 0, 1, 1 };
	int dz[] = { 0, 0, 0, 0, 1, 1, 1, 1 };
    glm::vec3 rule1 = glm::vec3(0.f);
    glm::vec3 rule2 = glm::vec3(0.f);
    glm::vec3 rule3 = glm::vec3(0.f);
    float rule1Cnt = 0;
    float rule3Cnt = 0;
    for (int i = 0; i < 8;++i) {
        int nGridX = dx[i] + gridX; int nGridY = dy[i] + gridY; int nGridZ = dz[i] + gridZ;
        if (nGridX >= gridResolution || nGridY >= gridResolution || nGridZ >= gridResolution)continue;
        int nGridId = gridIndex3Dto1D(nGridX,nGridY,nGridZ , gridResolution);
        int startThreadId = gridCellStartIndices[nGridId];
        int endThreadId = gridCellEndIndices[nGridId];
        for (int j = startThreadId; j < endThreadId; ++j) {
            int nBoidId = particleArrayIndices[j];
            glm::vec3 nPos = pos[nBoidId];
            glm::vec3 nVel = vel1[nBoidId];
            float dist = glm::distance(nPos, myPos);
            if (dist < rule1Distance) {
                // Rule 1: boids fly towards their local perceived center of mass, which excludes themselves
                rule1 += nPos;
                ++rule1Cnt;
            }
            if (dist < rule2Distance) {
                // Rule 2: boids try to stay a distance d away from each other
                rule2 += (myPos - nPos);
            }
            if (dist < rule3Distance) {
                // Rule 3: boids try to match the speed of surrounding boids
                rule3 += nVel;
                ++rule3Cnt;
            }
        }
    }
    rule1 /= rule1Cnt;
    rule1 = (rule1 - myPos) * rule1Scale;
    rule2 *= rule2Scale;
    rule3 = rule3 / rule3Cnt * rule3Scale;
  // - Clamp the speed change before putting the new speed in vel2
    glm::vec3 newVel = vel1[boidId] + rule1 + rule2 + rule3;
    float speed = glm::length(newVel);
    vel2[boidId] = speed > maxSpeed ? (newVel / speed * maxSpeed) : newVel;
}

__global__ void kernUpdateVelNeighborSearchCoherent(
  int N, int gridResolution, glm::vec3 gridMin,
  float inverseCellWidth, float cellWidth,
  int *gridCellStartIndices, int *gridCellEndIndices,
  glm::vec3 *pos, glm::vec3 *vel1, glm::vec3 *vel2) {
  // TODO-2.3 - This should be very similar to kernUpdateVelNeighborSearchScattered,
  // except with one less level of indirection.
    int boidId = blockDim.x * blockIdx.x + threadIdx.x;
    if (boidId >= N)return;
    glm::vec3 myPos = pos[boidId];
    glm::vec3 gridPos = (myPos - gridMin) * inverseCellWidth;
    //to make sure consider the right grid in finding neighbors
    // |       |       |
    // |    *******    |
    // |----*******----|
    // |    *******    | 
    // |       |       |
    // only boids in * should be marked in LL grid
    gridPos = glm::clamp(gridPos - glm::vec3(0.5f), glm::vec3(0.f), glm::vec3(gridResolution));
    int gridX = int(gridPos.x); int gridY = int(gridPos.y); int gridZ = int(gridPos.z);
    int gridId = gridIndex3Dto1D(gridX, gridY, gridZ, gridResolution);

    // - Identify which cells may contain neighbors. This isn't always 8.
    // - For each cell, read the start/end indices in the boid pointer array.
    // - Access each boid in the cell and compute velocity change from
    //   the boids rules, if this boid is within the neighborhood distance.
    //   DIFFERENCE: For best results, consider what order the cells should be
    //   checked in to maximize the memory benefits of reordering the boids data.
    //for( z for(y for(x))), x should change most frequently
    int dx[] = { 0, 1, 0, 1, 0, 1, 0, 1 };
    int dy[] = { 0, 0, 1, 1, 0, 0, 1, 1 };
    int dz[] = { 0, 0, 0, 0, 1, 1, 1, 1 };
    glm::vec3 rule1 = glm::vec3(0.f);
    glm::vec3 rule2 = glm::vec3(0.f);
    glm::vec3 rule3 = glm::vec3(0.f);
    float rule1Cnt = 0;
    float rule3Cnt = 0;
    for (int i = 0; i < 8;++i) {
        int nGridX = dx[i] + gridX; int nGridY = dy[i] + gridY; int nGridZ = dz[i] + gridZ;
        if (nGridX >= gridResolution || nGridY >= gridResolution || nGridZ >= gridResolution)continue;
        int nGridId = gridIndex3Dto1D(nGridX, nGridY, nGridZ, gridResolution);
        int startThreadId = gridCellStartIndices[nGridId];
        int endThreadId = gridCellEndIndices[nGridId];
        for (int j = startThreadId; j < endThreadId; ++j) {
            int nBoidId = j;
            glm::vec3 nPos = pos[nBoidId];
            glm::vec3 nVel = vel1[nBoidId];
            float dist = glm::distance(nPos, myPos);
            if (dist < rule1Distance) {
                // Rule 1: boids fly towards their local perceived center of mass, which excludes themselves
                rule1 += nPos;
                ++rule1Cnt;
            }
            if (dist < rule2Distance) {
                // Rule 2: boids try to stay a distance d away from each other
                rule2 += (myPos - nPos);
            }
            if (dist < rule3Distance) {
                // Rule 3: boids try to match the speed of surrounding boids
                rule3 += nVel;
                ++rule3Cnt;
            }
        }
    }
    rule1 /= rule1Cnt;
    rule1 = (rule1 - myPos) * rule1Scale;
    rule2 *= rule2Scale;
    rule3 = rule3 / rule3Cnt * rule3Scale;
    // - Clamp the speed change before putting the new speed in vel2
    glm::vec3 newVel = vel1[boidId] + rule1 + rule2 + rule3;
    float speed = glm::length(newVel);
    vel2[boidId] = speed > maxSpeed ? (newVel / speed * maxSpeed) : newVel;
}

//update vel1 pos1 to make them arranged
__global__ void kernRearrangeArray(
    int N, int* particleArrayIndices,
    glm::vec3* pos, glm::vec3* vel2,//store the unarranged pos and vel in prev frame
    glm::vec3* pos2, glm::vec3* vel1 // store the arranged pos and vel to update
) {
    int iSelf = blockDim.x * blockIdx.x + threadIdx.x;
    if (iSelf >= N)return;
    int destId = particleArrayIndices[iSelf];
    pos2[iSelf] = pos[destId];
    vel1[iSelf] = vel2[destId];
}

/**
* Step the entire N-body simulation by `dt` seconds.
*/
void Boids::stepSimulationNaive(float dt) {
    //numObjects = N;
    dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);
  // TODO-1.2 - use the kernels you wrote to step the simulation forward in time.
    kernUpdateVelocityBruteForce << <fullBlocksPerGrid, blockSize >> > (numObjects, dev_pos, dev_vel1, dev_vel2);
    checkCUDAErrorWithLine("kernUpdateVelocityBruteForce failed!");
    kernUpdatePos << <fullBlocksPerGrid, blockSize >> > (numObjects, dt, dev_pos, dev_vel2);
    checkCUDAErrorWithLine("kernUpdatePos failed!");
  // TODO-1.2 ping-pong the velocity buffers
    std::swap(dev_vel1, dev_vel2);
}

void Boids::stepSimulationScatteredGrid(float dt) {
    dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);
    int N = numObjects;
    int gridResolution = gridSideCount;
    glm::vec3 gridMin = gridMinimum;
    float inverseCellWidth = gridInverseCellWidth;
    float cellWidth = gridCellWidth;
    int* indices = dev_particleArrayIndices; // thread -> boid id
    int* gridIndices = dev_particleGridIndices; // thread -> grid
    int* gridCellStartIndices = dev_gridCellStartIndices; // grid -> threadBegin
    int* gridCellEndIndices = dev_gridCellEndIndices; // grid -> threadEnd
    int* particleArrayIndices = dev_particleArrayIndices; // thread -> boid id
    glm::vec3* pos = dev_pos; //boid id-> pos
    glm::vec3* vel1 = dev_vel1; //boid id->vel
    glm::vec3* vel2 = dev_vel2;
  // TODO-2.1
  // Uniform Grid Neighbor search using Thrust sort.
  // In Parallel:
  // - label each particle with its array index as well as its grid index.
  //   Use 2x width grids.
    kernComputeIndices << <fullBlocksPerGrid, blockSize >> >
        (N, gridResolution, gridMin, inverseCellWidth, pos, indices, gridIndices);
    checkCUDAErrorWithLine("kernComputeIndices failed!");
  
  // - Unstable key sort using Thrust. A stable sort isn't necessary, but you
  //   are welcome to do a performance comparison.
    dev_thrust_particleArrayIndices = thrust::device_ptr<int>(dev_particleArrayIndices);
    dev_thrust_particleGridIndices = thrust::device_ptr<int>(dev_particleGridIndices);
    thrust::sort_by_key(dev_thrust_particleGridIndices, dev_thrust_particleGridIndices + numObjects, dev_thrust_particleArrayIndices);
  
  // - Naively unroll the loop for finding the start and end indices of each
  //   cell's data pointers in the array of boid indices
    kernIdentifyCellStartEnd << <fullBlocksPerGrid, blockSize >> > (
        N, gridIndices,
        gridCellStartIndices, gridCellEndIndices
        );
    checkCUDAErrorWithLine("kernIdentifyCellStartEnd failed!");
 
  // - Perform velocity updates using neighbor search
    kernUpdateVelNeighborSearchScattered << <fullBlocksPerGrid, blockSize >> > (
        N, gridResolution, gridMin,
        inverseCellWidth, cellWidth,
        gridCellStartIndices, gridCellEndIndices,
        particleArrayIndices,
        pos, vel1, vel2
        );
    checkCUDAErrorWithLine("kernUpdateVelNeighborSearchScattered failed!");

  // - Update positions
    kernUpdatePos << <fullBlocksPerGrid, blockSize >> > (N, dt, pos, vel2);
    checkCUDAErrorWithLine("kernUpdatePos failed!");

  // - Ping-pong buffers as needed
    //std::swap(vel1, vel2); cannot do that, dev_vel1 doesn't change!
    std::swap(dev_vel1, dev_vel2);
}

void Boids::stepSimulationCoherentGrid(float dt) {
  // TODO-2.3 - start by copying Boids::stepSimulationNaiveGrid

    dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);
    int N = numObjects;
    int gridResolution = gridSideCount;
    glm::vec3 gridMin = gridMinimum;
    float inverseCellWidth = gridInverseCellWidth;
    float cellWidth = gridCellWidth;
    int* indices = dev_particleArrayIndices; // thread -> boid id
    int* gridIndices = dev_particleGridIndices; // thread -> grid
    int* gridCellStartIndices = dev_gridCellStartIndices; // grid -> threadBegin
    int* gridCellEndIndices = dev_gridCellEndIndices; // grid -> threadEnd
    int* particleArrayIndices = dev_particleArrayIndices; // thread -> boid id
    glm::vec3* pos = dev_pos; //prev frame unsorted for the grid at now
    glm::vec3* vel1 = dev_vel1; //prev frame unsorted for the grid at now
    glm::vec3* vel2 = dev_vel2;//going to be sorted for the grid at now
    glm::vec3* pos2 = dev_pos2;//going to be sorted for the grid at now

    // - label each particle with its array index as well as its grid index.
    //   Use 2x width grids.
    kernComputeIndices << <fullBlocksPerGrid, blockSize >> >
        (N, gridResolution, gridMin, inverseCellWidth, pos, indices, gridIndices);
    checkCUDAErrorWithLine("kernComputeIndices failed!");

    // - Unstable key sort using Thrust. A stable sort isn't necessary, but you
    //   are welcome to do a performance comparison.
    dev_thrust_particleArrayIndices = thrust::device_ptr<int>(dev_particleArrayIndices);
    dev_thrust_particleGridIndices = thrust::device_ptr<int>(dev_particleGridIndices);
    thrust::sort_by_key(dev_thrust_particleGridIndices, dev_thrust_particleGridIndices + numObjects, dev_thrust_particleArrayIndices);

    // - Naively unroll the loop for finding the start and end indices of each
    //   cell's data pointers in the array of boid indices
    kernIdentifyCellStartEnd << <fullBlocksPerGrid, blockSize >> > (
        N, gridIndices,
        gridCellStartIndices, gridCellEndIndices
        );
    checkCUDAErrorWithLine("kernIdentifyCellStartEnd failed!");

    //here we rearrange the readonly array pos2, and vel1 based on the previous frame
    //after the kern arranged: pos2, vel1
    kernRearrangeArray << <fullBlocksPerGrid, blockSize >> > (
        N, particleArrayIndices,
        pos, vel1,//store the unarranged pos and vel in prev frame
        pos2, vel2
        );

    // - Perform velocity updates using neighbor search
    //after the kern arranged: pos2, vel1, vel2
    kernUpdateVelNeighborSearchCoherent << <fullBlocksPerGrid, blockSize >> > (
        N, gridResolution, gridMin,
        inverseCellWidth, cellWidth,
        gridCellStartIndices, gridCellEndIndices,
        pos2, vel2, vel1//make the vel1 to become arranged
        );
    checkCUDAErrorWithLine("kernUpdateVelNeighborSearchCoherent failed!");

    // - Update positions
    kernUpdatePos << <fullBlocksPerGrid, blockSize >> > (N, dt, pos2, vel1);
    checkCUDAErrorWithLine("kernUpdatePos failed!");

    // - BIG DIFFERENCE: use the rearranged array index buffer to reshuffle all
    //   the particle data in the simulation array.
    //   CONSIDER WHAT ADDITIONAL BUFFERS YOU NEED
    // - Ping-pong buffers as needed. THIS MAY BE DIFFERENT FROM BEFORE.
    std::swap(dev_pos2, dev_pos);
    //std::swap(dev_vel1, dev_vel2); we already store the vel1 for the next frame
}

void Boids::stepSimulation(float dt, SIMULATION_TYPE type) {
    cudaEventRecord(dev_frameStart);
    switch (type)
    {
    case NAIVE:
    {
        stepSimulationNaive(dt);
        break;
    }
    case SCATTERED:
    {
        stepSimulationScatteredGrid(dt);
        break;
    }
    case COHERENT:
    {
        stepSimulationCoherentGrid(dt);
        break;
    }
    default:
        break;
    }
    
    cudaEventRecord(dev_frameEnd);
    cudaEventSynchronize(dev_frameEnd);
    float tmpTime = 0.f;
    cudaEventElapsedTime(&tmpTime, dev_frameStart, dev_frameEnd);
    timeElapsed+=tmpTime;
    ++frameCnt;
}


void Boids::unitTest() {
  // LOOK-1.2 Feel free to write additional tests here.

  // test unstable sort
  int *dev_intKeys;
  int *dev_intValues;
  int N = 10;

  std::unique_ptr<int[]>intKeys{ new int[N] };
  std::unique_ptr<int[]>intValues{ new int[N] };

  intKeys[0] = 0; intValues[0] = 2;
  intKeys[1] = 1; intValues[1] = 1;
  intKeys[2] = 0; intValues[2] = 0;
  intKeys[3] = 3; intValues[3] = 3;
  intKeys[4] = 0; intValues[4] = 4;
  intKeys[5] = 2; intValues[5] = 5;
  intKeys[6] = 2; intValues[6] = 6;
  intKeys[7] = 0; intValues[7] = 7;
  intKeys[8] = 5; intValues[8] = 8;
  intKeys[9] = 6; intValues[9] = 9;

  cudaMalloc((void**)&dev_intKeys, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_intKeys failed!");

  cudaMalloc((void**)&dev_intValues, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_intValues failed!");

  dim3 fullBlocksPerGrid((N + blockSize - 1) / blockSize);

  std::cout << "before unstable sort: " << std::endl;
  for (int i = 0; i < N; i++) {
    std::cout << "  key: " << intKeys[i];
    std::cout << " value: " << intValues[i] << std::endl;
  }

  // How to copy data to the GPU
  cudaMemcpy(dev_intKeys, intKeys.get(), sizeof(int) * N, cudaMemcpyHostToDevice);
  cudaMemcpy(dev_intValues, intValues.get(), sizeof(int) * N, cudaMemcpyHostToDevice);

  // Wrap device vectors in thrust iterators for use with thrust.
  thrust::device_ptr<int> dev_thrust_keys(dev_intKeys);
  thrust::device_ptr<int> dev_thrust_values(dev_intValues);
  // LOOK-2.1 Example for using thrust::sort_by_key
  thrust::sort_by_key(dev_thrust_keys, dev_thrust_keys + N, dev_thrust_values);

  // How to copy data back to the CPU side from the GPU
  cudaMemcpy(intKeys.get(), dev_intKeys, sizeof(int) * N, cudaMemcpyDeviceToHost);
  cudaMemcpy(intValues.get(), dev_intValues, sizeof(int) * N, cudaMemcpyDeviceToHost);
  checkCUDAErrorWithLine("memcpy back failed!");

  std::cout << "after unstable sort: " << std::endl;
  for (int i = 0; i < N; i++) {
    std::cout << "  key: " << intKeys[i];
    std::cout << " value: " << intValues[i] << std::endl;
  }

  // cleanup
  cudaFree(dev_intKeys);
  cudaFree(dev_intValues);
  checkCUDAErrorWithLine("cudaFree failed!");
  return;
}
