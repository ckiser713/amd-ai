#!/usr/bin/env python3
"""
PyTorch benchmark and validation for AMD ROCm
"""
import torch
import time
import numpy as np

def validate_rocm():
    """Validate ROCm installation and basic functionality"""
    print("=" * 60)
    print("PyTorch ROCm Validation")
    print("=" * 60)
    
    # Basic info
    print(f"PyTorch version: {torch.__version__}")
    print(f"ROCm available: {torch.cuda.is_available()}")
    
    if torch.cuda.is_available():
        device = torch.device('cuda')
        print(f"GPU device: {torch.cuda.get_device_name(0)}")
        print(f"GPU memory: {torch.cuda.get_device_properties(0).total_memory / 1e9:.2f} GB")
    else:
        device = torch.device('cpu')
        print("Running on CPU")
    
    return device

def benchmark_matmul(device, size=4096):
    """Benchmark matrix multiplication"""
    print(f"\nMatrix Multiplication Benchmark ({size}x{size})")
    
    # Create random matrices
    a = torch.randn(size, size, device=device)
    b = torch.randn(size, size, device=device)
    
    # Warmup
    for _ in range(10):
        _ = torch.mm(a, b)
    
    if device.type == 'cuda':
        torch.cuda.synchronize()
    
    # Benchmark
    times = []
    for i in range(50):
        start = time.time()
        _ = torch.mm(a, b)
        
        if device.type == 'cuda':
            torch.cuda.synchronize()
        
        times.append(time.time() - start)
    
    avg_time = np.mean(times) * 1000  # Convert to ms
    gflops = (2 * size**3) / (np.mean(times) * 1e9)  # 2n^3 operations
    
    print(f"  Average time: {avg_time:.2f} ms")
    print(f"  Performance: {gflops:.2f} GFLOPs")
    return avg_time, gflops

def benchmark_transformer(device, batch_size=4, seq_len=512):
    """Benchmark simple transformer operations"""
    print(f"\nTransformer Benchmark (batch={batch_size}, seq={seq_len})")
    
    # Create tensors
    hidden_size = 768
    x = torch.randn(batch_size, seq_len, hidden_size, device=device)
    
    # Simple self-attention components
    w_q = torch.randn(hidden_size, hidden_size, device=device)
    w_k = torch.randn(hidden_size, hidden_size, device=device)
    w_v = torch.randn(hidden_size, hidden_size, device=device)
    
    # Warmup
    for _ in range(5):
        q = torch.matmul(x, w_q)
        k = torch.matmul(x, w_k)
        v = torch.matmul(x, w_v)
    
    if device.type == 'cuda':
        torch.cuda.synchronize()
    
    # Benchmark
    start = time.time()
    iterations = 100
    
    for _ in range(iterations):
        q = torch.matmul(x, w_q)
        k = torch.matmul(x, w_k)
        v = torch.matmul(x, w_v)
        
        # Simple attention (without softmax for benchmarking)
        scores = torch.matmul(q, k.transpose(-2, -1))
    
    if device.type == 'cuda':
        torch.cuda.synchronize()
    
    total_time = time.time() - start
    iter_per_sec = iterations / total_time
    
    print(f"  Time: {total_time:.2f} seconds")
    print(f"  Iterations/sec: {iter_per_sec:.2f}")
    return iter_per_sec

def memory_bandwidth_test(device):
    """Test memory bandwidth"""
    print("\nMemory Bandwidth Test")
    
    size = 100 * 1024 * 1024  # 100MB
    if device.type == 'cuda':
        # GPU memory test
        data = torch.randn(size // 4, device=device)  # 100MB of floats
        torch.cuda.synchronize()
        
        start = time.time()
        # Simple memory operations
        for _ in range(100):
            data = data * 1.1 + 0.1
        
        torch.cuda.synchronize()
        elapsed = time.time() - start
        
        bandwidth = (size * 100 * 2) / (elapsed * 1e9)  # GB/s
        print(f"  GPU Memory bandwidth: {bandwidth:.2f} GB/s")
    else:
        # CPU memory test
        data = np.random.randn(size // 8).astype(np.float64)  # 100MB
        
        start = time.time()
        for _ in range(50):
            data = data * 1.1 + 0.1
        
        elapsed = time.time() - start
        bandwidth = (size * 50 * 2) / (elapsed * 1e9)
        print(f"  CPU Memory bandwidth: {bandwidth:.2f} GB/s")

if __name__ == "__main__":
    print("Starting PyTorch benchmarks...")
    
    device = validate_rocm()
    
    # Run benchmarks
    try:
        benchmark_matmul(device, 2048)  # Smaller size for stability
        benchmark_matmul(device, 4096)  # Standard size
        
        benchmark_transformer(device, batch_size=2, seq_len=256)
        
        memory_bandwidth_test(device)
        
    except Exception as e:
        print(f"\n⚠️  Benchmark error: {e}")
        print("Running simpler CPU-only test...")
        device = torch.device('cpu')
        benchmark_matmul(device, 1024)
    
    print("\n" + "=" * 60)
    print("Benchmark complete")
    print("=" * 60)
