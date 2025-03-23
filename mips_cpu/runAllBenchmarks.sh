set -e
echo "Running all tests in parallel..."

# Create temporary files
nqueens_file=$(mktemp)
coin_file=$(mktemp)
esift2_file=$(mktemp)
quickSort_file=$(mktemp)

# Run all commands in parallel and redirect output to temp files
(obj_dir/Vmips_core -sb nqueens   | tail -n 2 > "$nqueens_file"; echo "nqueens DONE") &
(obj_dir/Vmips_core -sb coin      | tail -n 1 > "$coin_file"; echo "coin DONE") &
(obj_dir/Vmips_core -sb esift2    | tail -n 1 > "$esift2_file"; echo "esift2 DONE") &
(obj_dir/Vmips_core -sb quickSort | tail -n 1 > "$quickSort_file"; echo "quickSort DONE") &

# Wait for all background processes to finish
wait

# Read the results into variables
nqueens_out=$(cat "$nqueens_file")
coin_out=$(cat "$coin_file")
esift2_out=$(cat "$esift2_file")
quickSort_out=$(cat "$quickSort_file")

# Clean up temporary files
rm "$nqueens_file" "$coin_file" "$esift2_file" "$quickSort_file"

# Save to output file
echo "$nqueens_out" > output.txt
echo "$coin_out" >> output.txt
echo "$esift2_out" >> output.txt
echo "$quickSort_out" >> output.txt

echo "Saved to output.txt"
