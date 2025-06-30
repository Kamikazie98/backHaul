# PowerShell script for building Backhaul on Windows

# Function to show colored output
function Write-ColorOutput($ForegroundColor) {
    $fc = $host.UI.RawUI.ForegroundColor
    $host.UI.RawUI.ForegroundColor = $ForegroundColor
    if ($args) {
        Write-Output $args
    }
    $host.UI.RawUI.ForegroundColor = $fc
}

Write-ColorOutput Green "Starting Backhaul build process..."

# Check if Go is installed
if (!(Get-Command go -ErrorAction SilentlyContinue)) {
    Write-ColorOutput Red "Error: Go is not installed. Please install Go first."
    exit 1
}

# Get the current version
$VERSION = "v0.1.0"
try {
    $VERSION = git describe --tags --abbrev=0
} catch {
    Write-ColorOutput Yellow "No git tags found, using default version $VERSION"
}

$BUILD_TIME = Get-Date -Format "yyyy-MM-ddTHH:mm:ssK"

# Create build directory
New-Item -ItemType Directory -Force -Path "build" | Out-Null

# Build function
function Build-Backhaul {
    param (
        [string]$OS,
        [string]$ARCH
    )
    
    $OUTPUT = "build\backhaul_${OS}_${ARCH}"
    if ($OS -eq "windows") {
        $OUTPUT = "${OUTPUT}.exe"
    }
    
    Write-ColorOutput Yellow "Building for ${OS}/${ARCH}..."
    
    $env:GOOS = $OS
    $env:GOARCH = $ARCH
    
    try {
        go build -ldflags "-X main.version=${VERSION} -X main.buildTime=${BUILD_TIME}" -o $OUTPUT
        if ($LASTEXITCODE -eq 0) {
            Write-ColorOutput Green "Successfully built for ${OS}/${ARCH}"
            
            # Create archive
            if ($OS -eq "windows") {
                Compress-Archive -Path $OUTPUT -DestinationPath "build\backhaul_${OS}_${ARCH}.zip" -Force
            } else {
                tar -czf "build/backhaul_${OS}_${ARCH}.tar.gz" -C "build" "backhaul_${OS}_${ARCH}"
            }
        } else {
            Write-ColorOutput Red "Failed to build for ${OS}/${ARCH}"
        }
    } catch {
        Write-ColorOutput Red "Error building for ${OS}/${ARCH}: $_"
    }
}

# Clean build directory
Write-ColorOutput Yellow "Cleaning build directory..."
Remove-Item -Path "build\*" -Recurse -Force -ErrorAction SilentlyContinue

# Build for different platforms
Build-Backhaul -OS "windows" -ARCH "amd64"
Build-Backhaul -OS "windows" -ARCH "arm64"
Build-Backhaul -OS "linux" -ARCH "amd64"
Build-Backhaul -OS "linux" -ARCH "arm64"

Write-ColorOutput Green "Build process completed!"
Write-ColorOutput Yellow "Binaries and archives are available in the 'build' directory" 