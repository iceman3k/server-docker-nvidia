#!/bin/bash
# Log original args
echo "nvcc args before filtering: $@" >> /usr/src/nvcc-wrapper.log

# Count number of -gencode flags
gencode_count=0
for arg in "$@"; do
  if [[ "$arg" == -gencode* ]]; then
    ((gencode_count++))
  fi
done

# Build new arg list
args=()
for arg in "$@"; do
  # Only remove -ptx/--ptx if multiple -gencode flags are present
  if [[ $gencode_count -gt 1 && ( "$arg" == "-ptx" || "$arg" == "--ptx" ) ]]; then
    echo "Filtered out: $arg (due to multiple -gencode flags)" >> /usr/src/nvcc-wrapper.log
  else
    args+=("$arg")
  fi
done

echo "nvcc args after filtering: ${args[@]}" >> /usr/src/nvcc-wrapper.log
exec /usr/local/cuda/bin/nvcc.original "${args[@]}"