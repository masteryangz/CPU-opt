#!/bin/bash

# Output file
output_file="merged_trace.json"

# Start the JSON structure
echo '{"otherData":{},"traceEvents": [' > "$output_file"

# Initialize a variable to track if this is the first fragment
first_fragment=true

# Collect JSON fragments and append them to the output file
for fragment_file in "$@"; do
    echo "Adding $fragment_file"
    
    # If it's not the first fragment, add a comma before appending
    if [ "$first_fragment" = false ]; then
        echo -n "," >> "$output_file"
    fi
    
    # Append the fragment
    cat "$fragment_file" >> "$output_file"
    
    # Set first_fragment to false after the first iteration
    first_fragment=false
done

# Close the JSON structure
echo "]}" >> "$output_file"

echo "JSON fragments merged into $output_file"