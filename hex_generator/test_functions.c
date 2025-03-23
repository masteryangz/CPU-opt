#include "custom_inst.h"

__attribute__((noinline)) int foo(int x) {
    int j = 0, k = 1;
    for (int i = 0; i < 40; ++i) {
        x += k;
        j += 1;
        k += j;
        PASS(x);
    }
    return x;
}

int begin() {    
    int r = foo(7);
    if (r == 0x29d3) {
        PASS(r);
    }
    else {
        FAIL(r);
    }

	int k = 105;
	DONE(k);
	return 0;
}
