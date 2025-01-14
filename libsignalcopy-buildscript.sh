set -euo pipefail

# Define the local directory containing the architecture-specific files
LOCAL_LIBSIGNAL_FFI_DIR="/Users/jgnoonan/libsignal/target"

# List of architectures to handle
ARCHITECTURES=("aarch64-apple-ios" "aarch64-apple-ios-sim")

# Iterate through architectures and copy each file
for ARCH in "${ARCHITECTURES[@]}"; do
    # Path to the local libsignal_ffi.a file
    LOCAL_LIB_PATH="${LOCAL_LIBSIGNAL_FFI_DIR}/${ARCH}/release/libsignal_ffi.a"

    # Ensure the file exists
    if [ ! -e "${LOCAL_LIB_PATH}" ]; then
        echo "Error: libsignal_ffi.a for architecture ${ARCH} not found at ${LOCAL_LIB_PATH}"
        exit 1
    fi

    # Define the destination path in the Pods directory
    DEST_PATH="${PODS_ROOT}/libsignal_ffi_${ARCH}.a"

    # Copy the local file to the destination
    cp "${LOCAL_LIB_PATH}" "${DEST_PATH}"
    echo "Copied ${LOCAL_LIB_PATH} to ${DEST_PATH}"
done

# Exit successfully
exit 0
