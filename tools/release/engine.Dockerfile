# The Linux engine's build environment, like the release's (glibc 2.28, CUDA 13.0 Update 2 = nvcc 13.0.88):
# NVIDIA's CUDA image on Rocky Linux 8, GCC 13 (gcc-toolset-13), CMake and Ninja from pip.
FROM nvidia/cuda:13.0.2-devel-rockylinux8
RUN dnf install -y gcc-toolset-13-gcc gcc-toolset-13-gcc-c++ gcc-toolset-13-binutils git python3.11 python3.11-pip patchelf \
 && dnf clean all \
 && python3.11 -m pip install --no-cache-dir "cmake>=3.28,<4" ninja
ENV PATH=/opt/rh/gcc-toolset-13/root/usr/bin:/usr/local/bin:$PATH
