#include <hip/hip_runtime.h>
#include <iostream>

__device__ void test() {
    constexpr int w = __AMDGCN_WAVEFRONT_SIZE__;
    (void)w;
}

int main() {
    return 0;
}
