#include "custom_inst.h"
#define N 100
#define SUM(n) (((n-1)*n)/2)

void fill(int *arr) {
    for (int i = 0; i < N; ++i)
        arr[i] = i;
}

int begin() {
    int x[N];
    fill(x);

    int sum = 0;
    for (int i = 0; i < N; ++i)
        sum += x[i];

    if (sum == SUM(N)) {
        PASS(sum);
    }
    else {
        FAIL(sum);
    }

	int k = 105;
	DONE(k);
	return 0;
}
