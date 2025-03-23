#include "custom_inst.h"

int begin() {
	int x, y, n = 2;

	//for (y = 0; y < n; ++y)
	//for (x = 0; x < n; ++x) {
	//	int hash = y << 8 | x;
	//	PASS(hash);
	//}

	// Fibonacci
	int a = 1, b = 1;
	do {
		PASS(a);

		int next = a + b;
		a = b;
		b = next;
	} while (a < 0x1000);

	int k = 105;

	DONE(k);
	return 0;
}
