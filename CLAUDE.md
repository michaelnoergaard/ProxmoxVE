# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

**Proxmox VE Helper-Scripts** is a community-maintained collection of tools that simplify the setup and management of Proxmox Virtual Environment (VE). Originally created by tteck, these scripts are now continued by the community to provide ongoing resources for Proxmox users worldwide.

## Architecture & Structure

### Core Directories

- **`ct/`** - LXC container creation scripts (300+ applications)
- **`install/`** - Installation scripts for each application
- **`misc/`** - Core system functions and utilities
- **`tools/`** - Additional utilities and management tools
- **`vm/`** - Virtual machine creation scripts
- **`frontend/`** - Next.js website (helper-scripts.com)
- **`api/`** - Go-based API server

### Key Files

- **`misc/build.func`** - Core build and container creation functions
- **`misc/core.func`** - Essential utility functions (colors, messaging, error handling)
- **`misc/install.func`** - Installation framework functions
- **`misc/create_lxc.sh`** - LXC container creation orchestrator

## Common Commands

### Frontend Development (Next.js)
```bash
cd frontend
npm run dev          # Start development server with Turbopack
npm run build        # Build for production
npm run start        # Start production server
npm run lint         # Run ESLint with auto-fix
npm run typecheck    # Run TypeScript type checking
```

### API Development (Go)
```bash
cd api
go mod tidy          # Clean up dependencies
go run main.go       # Run development server
go build -o server main.go  # Build binary
```

### Script Management
- Scripts are executed directly on Proxmox nodes via curl/bash
- No build process required for shell scripts
- Test scripts in Proxmox environment before committing

## Development Workflow

### Adding New Applications

1. **Create container script**: `ct/{app-name}.sh`
2. **Create install script**: `install/{app-name}-install.sh`  
3. **Add JSON metadata**: `frontend/public/json/{app-name}.json`
4. **Create header file**: `ct/headers/{app-name}`

### Script Structure

All container scripts follow this pattern:
```bash
#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)
# Application-specific variables
APP="Application Name"
var_disk="4"
var_cpu="2" 
var_ram="2048"
var_os="debian"
var_version="12"
# Execute main installation
start
```

### Core Functions Available

- **`msg_info()`** - Display progress messages with spinner
- **`msg_ok()`** - Display success messages  
- **`msg_error()`** - Display error messages
- **`header_info()`** - Show application header/logo
- **`build_container()`** - Create and configure LXC container
- **`catch_errors()`** - Enable error handling and traps

## API Integration

The system includes diagnostic API calls that send anonymous installation statistics. Key functions:
- **`post_to_api()`** - Send installation start data
- **`post_update_to_api()`** - Send completion/error status

## Testing Guidelines

- Test all scripts on clean Proxmox 8.x environments
- Verify container resource requirements are appropriate
- Test both default and advanced installation modes
- Ensure error handling works correctly
- Validate networking and storage configurations

## Security & Best Practices

- All scripts run as root on Proxmox nodes
- Never include hardcoded credentials or secrets
- Use proper input validation for user-provided values
- Implement timeout mechanisms for network operations
- Follow principle of least privilege where possible

## Requirements

- **Proxmox VE**: Version 8.1 or later
- **Architecture**: AMD64 (x86_64) only
- **Dependencies**: bash, curl (present on all Proxmox installations)
- **Network**: Internet connectivity required for downloads

## Container Standards

- **Default resources**: 1 vCPU, 1GB RAM, 4GB disk
- **Networking**: DHCP on vmbr0 bridge by default
- **Security**: Unprivileged containers preferred
- **Features**: Enable keyctl and nesting for compatibility
- **Tags**: All containers tagged with "community-script;"

## Common Patterns

### Resource Allocation
Check and validate system resources before installation:
```bash
check_container_resources  # Validates CPU/RAM availability
check_container_storage    # Checks disk space (80% threshold)
```

### Package Management
Different approaches for Debian vs Alpine:
```bash
if is_alpine; then
    apk add package-name
else
    apt-get install -y package-name
fi
```

### Service Management
```bash
systemctl enable --now service-name
systemctl status service-name
```