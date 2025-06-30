#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Starting Backhaul build process...${NC}"

# Check if Go is installed
if ! command -v go &> /dev/null; then
    echo -e "${RED}Error: Go is not installed. Please install Go first.${NC}"
    exit 1
fi

# Get the current version
VERSION=$(git describe --tags --abbrev=0 2>/dev/null || echo "v0.1.0")
BUILD_TIME=$(date +%FT%T%z)

# Create build directory
mkdir -p build

# Build function
build() {
    local OS=$1
    local ARCH=$2
    local OUTPUT="build/backhaul_${OS}_${ARCH}"
    
    if [ "$OS" = "windows" ]; then
        OUTPUT="${OUTPUT}.exe"
    fi

    echo -e "${YELLOW}Building for ${OS}/${ARCH}...${NC}"
    
    GOOS=$OS GOARCH=$ARCH go build \
        -ldflags "-X main.version=${VERSION} -X main.buildTime=${BUILD_TIME}" \
        -o "$OUTPUT" .
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Successfully built for ${OS}/${ARCH}${NC}"
        # Create zip archive
        if [ "$OS" = "windows" ]; then
            zip -j "build/backhaul_${OS}_${ARCH}.zip" "$OUTPUT"
        else
            tar czf "build/backhaul_${OS}_${ARCH}.tar.gz" -C build "backhaul_${OS}_${ARCH}"
        fi
    else
        echo -e "${RED}Failed to build for ${OS}/${ARCH}${NC}"
    fi
}

# Clean build directory
echo -e "${YELLOW}Cleaning build directory...${NC}"
rm -rf build/*

# Build for different platforms
build linux amd64
build linux arm64
build windows amd64
build darwin amd64
build darwin arm64

echo -e "${GREEN}Build process completed!${NC}"
echo -e "Binaries and archives are available in the ${YELLOW}build/${NC} directory" 