// Recursive quicksort + insertion sort, checked against each other.
#include "rt.h"
#define N 200
static uint32_t a[N], b[N];

static uint32_t lcg(uint32_t *s) { *s = *s * 1103515245u + 12345u; return *s >> 8; }

static void qsort_r(uint32_t *v, int lo, int hi) {
    if (lo >= hi) return;
    uint32_t p = v[(lo + hi) / 2];
    int i = lo, j = hi;
    while (i <= j) {
        while (v[i] < p) i++;
        while (v[j] > p) j--;
        if (i <= j) { uint32_t t = v[i]; v[i] = v[j]; v[j] = t; i++; j--; }
    }
    qsort_r(v, lo, j);
    qsort_r(v, i, hi);
}

int main(void) {
    uint32_t s = 42;
    for (int i = 0; i < N; i++) a[i] = b[i] = lcg(&s) % 1000;
    qsort_r(a, 0, N - 1);
    for (int i = 1; i < N; i++) {
        uint32_t k = b[i];
        int j = i - 1;
        while (j >= 0 && b[j] > k) { b[j + 1] = b[j]; j--; }
        b[j + 1] = k;
    }
    for (int i = 0; i < N; i++) CHECK(a[i] == b[i]);
    for (int i = 1; i < N; i++) CHECK(a[i - 1] <= a[i]);
    rt_puts("sort ok\n");
    return 0;
}
