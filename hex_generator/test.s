	.set noat
    .text
	.align	2
	.globl	_ftext
    .extern begin
	.set	nomips16
	.set	nomicromips
	.ent	_ftext
_ftext:
	la   $t0, array         # Load base address
    li   $t1, 256           # Number of words in the array

    # Initialize the array with values: array[i] = i * 4
    li   $t2, 0             # Counter i = 0
init_loop:
    sll  $t3, $t2, 2        # t3 = i * 4
    sw   $t3, 0($t0)        # Store i * 4 into array[i]
    addi $t0, $t0, 4        # Move to next word
    addi $t2, $t2, 1        # i++
    bne  $t2, $t1, init_loop

    # Verify stored values
    la   $t0, array         # Reset to base address
    li   $t2, 0             # Reset counter i
verify_loop:
    lw   $t3, 0($t0)        # Load array[i]
    mtc0 $t3, $23           # PASS
    sll  $t4, $t2, 2        # Expected value = i * 4
    bne  $t3, $t4, test_fail # If mismatch, fail
    addi $t0, $t0, 4        # Move to next word
    addi $t2, $t2, 1        # i++
    bne  $t2, $t1, verify_loop

    # Randomized writes and re-verification
    la   $t0, array
    li   $t2, 0
random_store_loop:
    sll  $t3, $t2, 3        # New pattern: i * 8
    sw   $t3, 0($t0)        # Store into array[i]
    addi $t0, $t0, 4
    addi $t2, $t2, 1
    bne  $t2, $t1, random_store_loop

    # Verify random writes
    la   $t0, array
    li   $t2, 0
random_verify_loop:
    lw   $t3, 0($t0)        # Load array[i]
    sll  $t4, $t2, 3        # Expected value = i * 8
    bne  $t3, $t4, test_fail
    addi $t0, $t0, 4
    addi $t2, $t2, 1
    bne  $t2, $t1, random_verify_loop

    # Mark as PASS
    li   $t7, 1
    mtc0 $t7, $23           # PASS

    # Mark as DONE
    mtc0 $t7, $25           # DONE
    nop
	nop

test_fail:
    li   $t7, 1
    mtc0 $t7, $24           # FAIL
    mtc0 $t7, $25           # DONE
    mtc0 $t7, $25  # DONE
	nop
	nop

$loop:
 	j	$loop
 	nop
 	nop
	.end	_ftext

.data
array:  .space 1024    # 256 words = 1024 bytes of storage