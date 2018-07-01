#include "split_pairwise.cuh"
#include <catboost/cuda/cuda_lib/kernel/kernel.cuh>

#include <catboost/cuda/cuda_lib/kernel/arch.cuh>
#include <catboost/cuda/cuda_util/kernel/instructions.cuh>
#include <catboost/cuda/cuda_util/kernel/kernel_helpers.cuh>


namespace NKernel {


    //System size <= ROW_SIZE — number of rows for decompose,
    // in pfound and pair classification we don't need last line
    template <int BLOCK_SIZE>
    __launch_bounds__(BLOCK_SIZE)
    __global__ void ExtractMatricesAndTargetsImpl(const float* linearSystem,
                                                  const int matCount,
                                                  const int rowSize,
                                                  float* matrices,
                                                  float* targets) {
        const int lineSize = 32;
        const int matricesPerBlock = BLOCK_SIZE / lineSize;
        const int localMatrixIdx = threadIdx.x / lineSize;

        int matrixIdx = blockIdx.x * matricesPerBlock + localMatrixIdx;

        if (matrixIdx >= matCount) {
            return;
        }


        linearSystem += ((size_t)matrixIdx) * (rowSize * (rowSize + 1) / 2 + rowSize);
        matrices += ((size_t)matrixIdx) * (rowSize * (rowSize + 1) / 2);
        targets += ((size_t)matrixIdx) * rowSize;

        const int x = threadIdx.x & (lineSize - 1);

        #pragma unroll 8
        for (int i = x; i < rowSize * (rowSize + 1) / 2; i += lineSize) {
            matrices[i] = linearSystem[i];
        }

        #pragma unroll 8
        for (int i = x; i < rowSize; i += lineSize) {
            targets[i] = linearSystem[rowSize * (rowSize + 1) / 2 + i];
        }
    }

    void ExtractMatricesAndTargets(const float* linearSystem, int matCount, int rowSize, float* matrices, float* targets, TCudaStream stream) {
        const int blockSize = 256;
        const int numBlocks = (matCount * 32 + blockSize - 1) / blockSize;
        if (numBlocks > 0) {
            ExtractMatricesAndTargetsImpl<blockSize> << < numBlocks, blockSize, 0, stream >> > (linearSystem, matCount, rowSize, matrices, targets);
        }
    }



    //System size <= ROW_SIZE — number of rows for decompose,
    // in pfound and pair classification we don't need last line
    template <int BLOCK_SIZE, int ROW_SIZE, int SYSTEM_SIZE>
    __launch_bounds__(BLOCK_SIZE)
    __global__ void CholeskyDecompositionImpl(float* lower, int matCount) {
        const int lineSize = (ROW_SIZE < 32 ? ROW_SIZE : 32);
        const int matricesPerBlock = BLOCK_SIZE / lineSize;
        const int localMatrixIdx = threadIdx.x / lineSize;

        int matrixIdx = blockIdx.x * matricesPerBlock + localMatrixIdx;

        if (matrixIdx >= matCount)
            return;

        lower += ((size_t)matrixIdx) * (ROW_SIZE * (ROW_SIZE + 1) / 2);

        const int x = threadIdx.x & (lineSize - 1);

        __shared__ float currentLineData[matricesPerBlock * ROW_SIZE];
        volatile float* currentLine = &currentLineData[localMatrixIdx * ROW_SIZE];

        __shared__ float dotRowData[BLOCK_SIZE];
        volatile float* dotRow = &dotRowData[localMatrixIdx * lineSize];

        __shared__ float LjjData[matricesPerBlock];
        volatile float* Ljj = &LjjData[localMatrixIdx];

        if (x == 0) {
            const float l00 = __ldg(lower);
            lower[0] = sqrtf(l00);
        }
        __syncthreads();
    //    #pragma unroll
        for (int row = 1; row < SYSTEM_SIZE; ++row) {
            //we don't modify this value in matrix, so it's pretty safe to load it with ldg.
            #pragma unroll
            for (int col = x; col < SYSTEM_SIZE; col += 32) {
                currentLine[col] = col <= row ? LdgWithFallback(lower, row * (row + 1) / 2 + col) : 0.0f;
            }

            __syncwarp();

            int reduceSize = 1;
            #pragma unroll
            for (int col = 0; col < row;  ++col) {

                if (col & reduceSize) {
                    reduceSize <<= 1;
                }

                {
                    float tmp = 0;
                    #pragma unroll
                    for (int colIdx = x; colIdx <= col; colIdx += 32) {
                        const float val = lower[col * (col + 1) / 2 + colIdx];
                        tmp += colIdx < col ? val * currentLine[colIdx] : 0;
                        if (colIdx == col) {
                            Ljj[0] = val;
                        }
                    }
                    dotRow[x] = tmp;
                }
                const float sum = WarpReduce(x, dotRow, min(reduceSize, 32));

                if (x == 0) {
                    currentLine[col] = Ljj[0] > 0 ? (currentLine[col] - sum) / (Ljj[0] + 1e-9f) : 0.0f;
                }
                __syncwarp();
            }

            {
                {
                    float tmp = 0;
                    #pragma unroll
                    for (int col = x; col < row; col += 32) {
                        tmp += currentLine[col] * currentLine[col];
                    }
                    __syncwarp();
                    dotRow[x] = tmp;
                }

                const float sum = WarpReduce(x, dotRow, min(reduceSize, 32));

                if (x == 0) {
                    const float tmp =  currentLine[row] - sum;
                    currentLine[row] = tmp > 1e-4f ? sqrtf(tmp) : 1e-2f;
                }
                __syncwarp();
            }


            #pragma unroll
            for (int colIdx = x; colIdx <= row; colIdx += 32) {
                lower[row * (row + 1) / 2 + colIdx] = currentLine[colIdx];
            }
            __syncthreads();
        }
    }

    class TDirectSystem {
    private:
        const float* Data;
        float* Target;
    public:

        __device__ TDirectSystem(const float* data, float* target, int rowSize)
            : Data(data)
            , Target(target)
        {
            (void)rowSize;
        }

        __forceinline__ __device__ float Get(int row, int col) const {
            return LdgWithFallback(Data, row * (row + 1) / 2 + col);
        }

        __forceinline__ __device__ float GetTarget(int row) const {
            return LdgWithFallback(Target, row);
        }

        __forceinline__ __device__ void WriteSolution(int row, float solution) const {
            Target[row] = solution;
        }

    };


    class TTransposedSystem {
    private:
        const float* Data;
        float* Target;
        int RowSize;
    public:

        __device__ TTransposedSystem(const float* data, float* target, int rowSize)
            : Data(data)
            , Target(target)
            , RowSize(rowSize) {
        }

        __forceinline__ __device__ float Get(int row, int col) const {
            row = RowSize - row - 1;
            col = RowSize - col - 1;
            return LdgWithFallback(Data, col * (col + 1) / 2 + row);
        }

        __forceinline__ __device__ float GetTarget(int row) const {
            return LdgWithFallback(Target, RowSize - row - 1);
        }

        __forceinline__ __device__ void WriteSolution(int row, float solution) const {
            Target[RowSize - row - 1] = solution;
        }
    };


    template <class TLowerMatrixSystem, int BLOCK_SIZE>
    __global__ void SolveForwardImpl(const float* lower, int rowSize, int systemSize, int matCount, float* targets) {
        const int matricesPerBlock = BLOCK_SIZE / rowSize;

        int matrixIdx = blockIdx.x * matricesPerBlock + threadIdx.x / rowSize;
        const int col = threadIdx.x & (rowSize - 1);
        const int inBlockOffset = threadIdx.x / rowSize;

        __shared__ float solutionsData[BLOCK_SIZE];
        __shared__ float dotProductCacheData[BLOCK_SIZE];

        if (matrixIdx >= matCount) {
            return;
        }

        lower += ((size_t)matrixIdx) * rowSize * (rowSize + 1) / 2;
        targets += matrixIdx * rowSize;

        float* solutions = &solutionsData[inBlockOffset * rowSize];
        float* dotProductCache = &dotProductCacheData[inBlockOffset * rowSize];

        TLowerMatrixSystem system(lower, targets, systemSize);
        solutions[col] = col < systemSize ? system.GetTarget(col) : 0;
        __syncthreads();


        int reduceSize = 1;

        #pragma unroll
        for (int row = 0; row < systemSize; ++row) {

            if (row & reduceSize) {
                reduceSize <<= 1;
            }

            dotProductCache[col] = col <= row ? system.Get(row, col)  : 0.0f;
            __syncthreads();

            float lastCoeff = 0.0f;

            if (col == 0) {
                lastCoeff = dotProductCache[row];
                dotProductCache[row] = 0;
            }
            __syncthreads();

            dotProductCache[col] *= solutions[col];
            __syncthreads();

            const float sum = FastInBlockReduce(col, dotProductCache, reduceSize);

            if (col == 0) {
                solutions[row] = lastCoeff > 1e-20f ? (solutions[row] - sum) / (lastCoeff + 1e-20f) : 0;
            }

            __syncthreads();
        }

        if (col < systemSize) {
            system.WriteSolution(col, solutions[col]);
        }
    }



    template <int BLOCK_SIZE>
    __global__ void RegularizeImpl(float* lower, int rowSize,
                                   int matCount, float lambda0, float lambda1) {
        const int matricesPerBlock = BLOCK_SIZE / rowSize;
        int matrixIdx = blockIdx.x * matricesPerBlock + threadIdx.x / rowSize;
        lower += ((size_t)matrixIdx) * rowSize * (rowSize + 1) / 2;

        const int col = threadIdx.x & (rowSize - 1);
        if (matrixIdx >= matCount) {
            return;
        }

        const float cellPrior = 1.0f / rowSize;

        for (int row = 0; row < rowSize; ++row) {
            //beta prior (uniform). Makes rank(lower) = rowSize - 1
            if (col <= row) {
                float val = lower[row * (row + 1) / 2 + col];
                if (col == row && val <= 1e-9f) {
                    val += 10.0f;
                }
                val += col < row ? -lambda0 * cellPrior : (lambda0 * (1 - cellPrior) + lambda1);
                lower[row * (row + 1) / 2 + col] = val;
            }
        }
    }



    void Regularize(float* matrices, int rowSize, int matCount, double lambdaNonDiag, double lambdaDiag, TCudaStream stream) {
        const int blockSize = 256;
        const int numBlocks = (matCount * rowSize + blockSize - 1) / blockSize;
        if (numBlocks > 0) {
            RegularizeImpl<blockSize><<<numBlocks, blockSize, 0, stream>>>(matrices, rowSize, matCount, lambdaNonDiag, lambdaDiag);
        }
    }


    template <int BLOCK_SIZE>
    __global__ void ZeroMeanImpl(float* solutions, int rowSize, int matCount) {

        const int matricesPerBlock = BLOCK_SIZE / rowSize;

        const int matrixIdx = blockIdx.x * matricesPerBlock + threadIdx.x / rowSize;
        const int tid = threadIdx.x;
        const int col = threadIdx.x & (rowSize - 1);
        const int inBlockOffset = threadIdx.x / rowSize;

        __shared__ double beta[BLOCK_SIZE];
        __shared__ double line[BLOCK_SIZE];

        if (matrixIdx >= matCount) {
            return;
        }

        solutions += matrixIdx * rowSize;
        beta[tid] = col != (rowSize - 1) ? solutions[col] : 0;
        line[tid] = beta[tid];
        __syncthreads();

        for (int s = rowSize >> 1; s > 0; s >>= 1) {
            if (col < s) {
                line[tid] += line[tid + s];
            }
            __syncthreads();
        }

        beta[tid] -= line[rowSize * inBlockOffset] / rowSize;
        solutions[col] = beta[tid];
    }

    template <int BLOCK_SIZE>
    __global__ void CalcScoresCholeskyImpl(const float* linearSystem,
                                           const float* solutions,
                                           int rowSize,
                                           int matCount,
                                           float* scores) {

        const int matricesPerBlock = BLOCK_SIZE / rowSize;

        const int matrixIdx = blockIdx.x * matricesPerBlock + threadIdx.x / rowSize;
        const int tid = threadIdx.x;
        const int col = threadIdx.x & (rowSize - 1);
        const int inBlockOffset = threadIdx.x / rowSize;

        __shared__ float beta[BLOCK_SIZE];
        __shared__ float line[BLOCK_SIZE];

        if (matrixIdx >= matCount) {
            return;
        }

        linearSystem += ((size_t)matrixIdx) * (rowSize * (rowSize + 1) / 2 + rowSize);
        solutions += matrixIdx * rowSize;
        scores += matrixIdx;

        beta[tid] = solutions[col];
        line[tid] = beta[tid];
        const float tidTarget = linearSystem[rowSize * (rowSize + 1) / 2 + col];

        __syncthreads();
        //we store matrix  cholesky-decomposition.  For score we need to maximize ||beta^{T}L||^2 - 2 <beta, y> (1)
        //score to minimize: (A\beta - y)^{T}W(A\beta - y) + \beta^{T} J \beta, where J — some positive-defined matrix
        //we don't need square sum, so we maximize (1)

        {
            float partb1 = 0;
            #pragma unroll 4
            for (int row = 0; row < rowSize; ++row) {
                double val = col <= row  ? LdgWithFallback(linearSystem, row * (row + 1) / 2 + col)
                                         : LdgWithFallback(linearSystem, col * (col + 1) / 2 + row);
                val *= beta[rowSize * inBlockOffset + row];
                partb1 += val;
            }
            line[tid] = beta[tid] * (tidTarget - 0.5 * partb1);
        }
        __syncthreads();

        for (int s = rowSize >> 1; s > 0; s >>= 1) {
            if (col < s) {
                line[tid] += line[tid + s];
            }
            __syncthreads();
        }

        if (col == 0) {
            scores[0] = line[tid];
        }
    }


    //Inplace solver
    template<int BLOCK_SIZE, int SOLVER_BLOCK_SIZE, int REMOVE_LAST>
    inline void RunCholeskySolver(float* matrices, float* solutions,
                                  int rowSize, int matCount,
                                  TCudaStream stream) {

        const int numBlocksCholesky = (matCount * min(rowSize, 32) + BLOCK_SIZE - 1) / BLOCK_SIZE;

        if (numBlocksCholesky > 0) {
            #define CHOLESKY_DECOMPOSITION(ROW_SIZE) \
            const int SYSTEM_SIZE = ROW_SIZE - REMOVE_LAST; \
            CholeskyDecompositionImpl<BLOCK_SIZE, ROW_SIZE, SYSTEM_SIZE> <<< numBlocksCholesky, BLOCK_SIZE, 0, stream>>> (matrices, matCount); \
            break;

            switch (rowSize) {
                case 1: {
                    CHOLESKY_DECOMPOSITION(1);
                }
                case 2: {
                    CHOLESKY_DECOMPOSITION(2);
                }
                case 4: {
                    CHOLESKY_DECOMPOSITION(4);
                }
                case 8: {
                    CHOLESKY_DECOMPOSITION(8);
                }
                case 16: {
                    CHOLESKY_DECOMPOSITION(16);
                }
                case 32: {
                    CHOLESKY_DECOMPOSITION(32);
                }
                case 64: {
                    CHOLESKY_DECOMPOSITION(64);
                }
                case 128: {
                    CHOLESKY_DECOMPOSITION(128);
                }
                case 256: {
                    CHOLESKY_DECOMPOSITION(256);
                }
            }

            const int solverNumBlocks = (matCount * rowSize + SOLVER_BLOCK_SIZE - 1) / SOLVER_BLOCK_SIZE;
            if (solverNumBlocks) {
                SolveForwardImpl<TDirectSystem, SOLVER_BLOCK_SIZE> << < solverNumBlocks, SOLVER_BLOCK_SIZE, 0, stream >> > (matrices, rowSize, rowSize - REMOVE_LAST, matCount, solutions);
                SolveForwardImpl<TTransposedSystem, SOLVER_BLOCK_SIZE> << < solverNumBlocks, SOLVER_BLOCK_SIZE, 0, stream >> > (matrices, rowSize, rowSize - REMOVE_LAST, matCount, solutions);
            }
        }
    }

    template<int BLOCK_SIZE>
    inline void RunCalcScores(const float* linearSystem, const float* solutions, int rowSize, float* scores,
                              int matCount, TCudaStream stream) {
        const int numBlocks = (matCount * BLOCK_SIZE + BLOCK_SIZE - 1) / BLOCK_SIZE;

        CalcScoresCholeskyImpl<BLOCK_SIZE> << < numBlocks, BLOCK_SIZE, 0, stream >> >(linearSystem, solutions, rowSize, matCount, scores);
    }

    void ZeroMean(float* solutions, int rowSize, int matCount, TCudaStream stream) {
        const int blockSize = 256;
        const int numBlocks = (matCount * rowSize + blockSize - 1) / blockSize;
        if (numBlocks > 0) {
            ZeroMeanImpl<blockSize> << < numBlocks, blockSize, 0, stream >> > (solutions, rowSize, matCount);
        }
    }

    void CalcScores(const float* linearSystem, const float* solutions,
                    float* scores, int rowSize, int matCount, TCudaStream stream)
    {
        if (rowSize == 256) {
            RunCalcScores<256>(linearSystem, solutions, rowSize, scores, matCount, stream);
        } else {
            RunCalcScores<128>(linearSystem, solutions, rowSize, scores, matCount, stream);
        }
    }

    void CholeskySolver(float* matrices, float* solutions, int rowSize, int matCount, bool removeLast, TCudaStream stream)
    {
        if (TArchProps::GetMajorVersion() == 2) {
            if (removeLast) {
                RunCholeskySolver<192, 256, 1>(matrices, solutions, rowSize, matCount, stream);
            } else {
                RunCholeskySolver<192, 256, 0>(matrices, solutions, rowSize, matCount, stream);
            }

        } else {
            if (removeLast) {
                RunCholeskySolver<128, 256, 1>(matrices, solutions, rowSize, matCount, stream);
            } else {
                RunCholeskySolver<128, 256, 0>(matrices, solutions, rowSize, matCount, stream);
            }
        }
    }

    void SolverForward(float* matrices, float* solutions, int rowSize, int matCount, TCudaStream stream) {
        const int blockSize = 256;
        const int numBlocks = (matCount * rowSize + blockSize - 1) / blockSize;
        if (numBlocks > 0) {
            SolveForwardImpl<TDirectSystem, blockSize><<<numBlocks, blockSize, 0, stream>>>(matrices, rowSize, rowSize - 1, matCount, solutions);
        }
    }


    void SolverBackward(float* matrices, float* solutions, int rowSize, int matCount, TCudaStream stream) {
        const int blockSize = 256;
        const int numBlocks = (matCount * rowSize + blockSize - 1) / blockSize;
        if (numBlocks > 0) {
            SolveForwardImpl<TTransposedSystem, blockSize><<<numBlocks, blockSize, 0, stream>>>(matrices, rowSize, rowSize - 1, matCount, solutions);
        }
    }



}
