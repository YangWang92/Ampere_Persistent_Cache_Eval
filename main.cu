/*
 * an example of persistent cache use case on A100
 * */

#include <stdio.h>
#include <chrono>
#include <iostream>
#include <iomanip>

using namespace std;

const int block_num = 1024;
const int block_size = 1024;

#define ENABLE_PERSIST

__global__
void cuda_kernel(float *freq_data, float *stream_data, int freq_size, int stream_size) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  int num = (freq_size + stream_size) / block_size / block_num;
  for(int j = 0; j < num; j++) {
    freq_data[((i * num) + j) % freq_size] = freq_data[((i * num) + j) % freq_size] * 2;
    stream_data[((i * num) + j) % stream_size] = stream_data[((i * num) + j) % stream_size] * 2;
  }
}

int main(int argc, char** argv) {
  int device_id = 0;
  // 128 * 4 MB 
  const int data_size = 1024 * 1024 * 1024 / sizeof(float);
  const int freq_size = 1024 * 1024 * 10 / sizeof(float);
  const int stream_size = data_size - freq_size;

  cudaEvent_t start, stop;
  cudaEventCreate(&start);
  cudaEventCreate(&stop);

  cudaCtxResetPersistingL2Cache();
  cudaStream_t stream;
  cudaStreamCreate(&stream);                                                                  // Create CUDA stream

  cudaDeviceProp prop;                                                                        // CUDA device properties variable
  cudaGetDeviceProperties(&prop, device_id);                                                 // Query GPU properties
  cout << "l2 cache size: " << prop.l2CacheSize << endl;
  cout << "max persisting cache size: " << prop.persistingL2CacheMaxSize << " Byte"<< endl;
  cout << "set persisting cache size: " << freq_size * sizeof(float) << " Byte"<< endl;
  cudaDeviceSetLimit( cudaLimitPersistingL2CacheSize, freq_size * sizeof(float));                                  // set-aside 3/4 of L2 cache for persisting accesses or the max allowed

  float* h_data = (float *)malloc(data_size * sizeof(float));
  float* data;
  // init host data
  for (int i = 0; i < data_size; i++) {
    h_data[i] = 1.0f;
  }

  cudaMalloc(&data, data_size * sizeof(float)); 
  cudaMemcpy(data, h_data, data_size * sizeof(float), cudaMemcpyHostToDevice);
  
 #ifdef ENABLE_PERSIST 
  cudaStreamAttrValue stream_attribute;
  stream_attribute.accessPolicyWindow.base_ptr  = reinterpret_cast<void*>(data);              // Global Memory data pointer
  stream_attribute.accessPolicyWindow.num_bytes = min((long)(freq_size * sizeof(float)), (long)(prop.accessPolicyMaxWindowSize));                  // Number of bytes for persistence access
  stream_attribute.accessPolicyWindow.hitRatio  = 1.0;                                        // Hint for cache hit ratio
  stream_attribute.accessPolicyWindow.hitProp   = cudaAccessPropertyPersisting;               // Persistence Property
  stream_attribute.accessPolicyWindow.missProp  = cudaAccessPropertyStreaming;                // Type of access property on cache miss
  
  cout << "window num_bytes: " << stream_attribute.accessPolicyWindow.num_bytes << endl;
  cout << "window hit ratio: " << stream_attribute.accessPolicyWindow.hitRatio << endl;
  
  cudaStreamSetAttribute(stream, cudaStreamAttributeAccessPolicyWindow, &stream_attribute);   // Set the attributes to a CUDA Stream
#endif
  float accum = 0;
  for(int i = 0; i < 100; i++) {
    cudaEventRecord(start);
    
    cuda_kernel <<<block_num, block_size, 0, stream>>> (data, data + freq_size, freq_size, stream_size); // This data1 is used by a kernel multiple times
    cudaEventRecord(stop);
    // copy results
    cudaMemcpy(h_data, data, data_size * sizeof(float), cudaMemcpyDeviceToHost);
    cudaEventSynchronize(stop);
    float milliseconds = 0;
    cudaEventElapsedTime(&milliseconds, start, stop);
    accum += milliseconds;
  }
  cout << "Time: " << fixed << setprecision(6) << accum / 100 << " ms" << endl;

  cudaCtxResetPersistingL2Cache();
}


