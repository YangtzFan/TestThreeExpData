#include <stdint.h>

/* volatile 保证后续比较不同编译/执行模式时，输入读取不会被常量折叠。 */
static volatile int32_t matrix_a[2][3] = {
    {1, 2, 3},
    {4, 5, 6},
};
static volatile int32_t matrix_b[3][5] = {
    {7, 8, 9, 10, 11},
    {12, 13, 14, 15, 16},
    {17, 18, 19, 20, 21},
};
volatile int32_t matrix_c[2][5];

void matmul_scalar(void)
{
    for (int i = 0; i < 2; ++i) {
        for (int j = 0; j < 5; ++j) {
            int32_t sum = 0;
            for (int k = 0; k < 3; ++k) {
                sum += matrix_a[i][k] * matrix_b[k][j];
            }
            matrix_c[i][j] = sum;
        }
    }
}

int main(void)
{
    matmul_scalar();
    return 0;
}
