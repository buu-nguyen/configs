#!/usr/bin/env bash
set -euo pipefail

#===============================================================================
# GitHub Setup Automation Script
# Supports: macOS (ARM) and Linux (Ubuntu terminal-only)
# Sets up: GitHub CLI authentication (HTTPS) + GPG commit signing
#===============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

#===============================================================================
# Helper Functions
#===============================================================================

print_header() {
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo ""
}

print_step() {
    echo -e "${BLUE}▶ $1${NC}"
}

print_success() {
    echo -e "${GREEN}✔ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_error() {
    echo -e "${RED}✖ $1${NC}"
}

prompt_input() {
    local prompt="$1"
    local default="${2:-}"
    local result

    if [[ -n "$default" ]]; then
        echo -en "${YELLOW}$prompt [${default}]: ${NC}" >&2
    else
        echo -en "${YELLOW}$prompt: ${NC}" >&2
    fi
    read -r result
    echo "${result:-$default}"
}

prompt_password() {
    local prompt="$1"
    local result

    echo -en "${YELLOW}$prompt: ${NC}" >&2
    read -rs result
    echo "" >&2
    echo "$result"
}

command_exists() {
    command -v "$1" &> /dev/null
}

#===============================================================================
# OS Detection
#===============================================================================

detect_os() {
    print_step "Detecting operating system..."
    
    OS=""
    ARCH=""
    
    case "$(uname -s)" in
        Darwin)
            OS="macos"
            ARCH="$(uname -m)"
            if [[ "$ARCH" != "arm64" ]]; then
                print_warning "Detected macOS on $ARCH (script optimized for ARM)"
            fi
            ;;
        Linux)
            OS="linux"
            if [[ -f /etc/os-release ]]; then
                . /etc/os-release
                local id="${ID:-}"
                local id_like="${ID_LIKE:-}"
                if [[ "$id" != "ubuntu" && "$id_like" != *"ubuntu"* && "$id_like" != *"debian"* ]]; then
                    print_warning "Detected ${id:-unknown} - script optimized for Ubuntu/Debian"
                fi
            fi
            ;;
        *)
            print_error "Unsupported operating system: $(uname -s)"
            exit 1
            ;;
    esac
    
    print_success "Detected OS: $OS ($(uname -m))"
}

#===============================================================================
# Prerequisites Installation
#===============================================================================

install_prerequisites() {
    print_header "Installing Prerequisites"
    
    local missing_packages=()
    
    # Check for required commands
    if ! command_exists git; then
        missing_packages+=("git")
    fi
    
    if ! command_exists gpg; then
        missing_packages+=("gnupg")
    fi
    
    if ! command_exists gh; then
        missing_packages+=("gh")
    fi
    
    # OS-specific pinentry
    if [[ "$OS" == "macos" ]]; then
        if ! command_exists pinentry-mac; then
            missing_packages+=("pinentry-mac")
        fi
    else
        if ! command_exists pinentry-tty && ! command_exists pinentry; then
            missing_packages+=("pinentry-tty")
        fi
    fi
    
    if [[ ${#missing_packages[@]} -eq 0 ]]; then
        print_success "All prerequisites are already installed"
        return 0
    fi
    
    print_step "Missing packages: ${missing_packages[*]}"
    
    if [[ "$OS" == "macos" ]]; then
        if ! command_exists brew; then
            print_error "Homebrew is not installed. Please install it first:"
            echo "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
            exit 1
        fi
        
        print_step "Installing packages via Homebrew..."
        brew install "${missing_packages[@]}"
    else
        print_step "Installing packages via apt..."
        sudo apt update
        sudo apt install -y "${missing_packages[@]}"
    fi
    
    print_success "Prerequisites installed successfully"
}

#===============================================================================
# GitHub CLI Authentication
#===============================================================================

# Required scopes for this script
# - repo: full repository access (push, pull, branches, tags, etc.)
# - write:gpg_key (or admin:gpg_key): upload GPG keys
# - write:public_key (or admin:public_key): upload SSH keys
REQUIRED_SCOPES="repo,write:gpg_key,write:public_key"

# Global variable for GitHub username
GH_USERNAME=""

check_gh_user_authenticated() {
    # Check if specific user is authenticated
    gh auth status 2>&1 | grep -qi "Logged in to github.com account $GH_USERNAME"
}

check_gh_user_active() {
    # Check if specific user is the active account
    gh auth status 2>&1 | grep -A1 "account $GH_USERNAME" | grep -qi "Active account: true"
}

check_gh_scopes() {
    # Get scopes for the active user's token via API header.
    # This is more robust than parsing the output of `gh auth status`.
    local scopes_header
    scopes_header=$(gh api -i / 2>/dev/null | grep -i '^x-oauth-scopes:')

    # Check required scopes (admin: includes write: permissions)
    if ! echo "$scopes_header" | grep -q "repo"; then
        return 1
    fi
    if ! echo "$scopes_header" | grep -qE "write:gpg_key|admin:gpg_key"; then
        return 1
    fi
    if ! echo "$scopes_header" | grep -qE "write:public_key|admin:public_key"; then
        return 1
    fi
    return 0
}

collect_gh_username() {
    print_header "GitHub Account"
    
    echo -e "${CYAN}Please enter your GitHub username to authenticate:${NC}"
    echo ""
    
    # Try to get current active user as default
    local current_user=""
    current_user=$(gh api user --jq '.login' 2>/dev/null || echo "")
    
    if [[ -n "$current_user" ]]; then
        GH_USERNAME=$(prompt_input "GitHub username" "$current_user")
    else
        GH_USERNAME=$(prompt_input "GitHub username")
    fi
    
    if [[ -z "$GH_USERNAME" ]]; then
        print_error "GitHub username is required"
        exit 1
    fi
}

setup_gh_auth() {
    print_header "GitHub CLI Authentication"
    
    # Check if user is already authenticated
    if check_gh_user_authenticated; then
        print_success "Account '$GH_USERNAME' is authenticated"
        
        # Check if this user is the active account
        if ! check_gh_user_active; then
            print_step "Switching to account '$GH_USERNAME'..."
            gh auth switch --user "$GH_USERNAME"
            print_success "Switched to account '$GH_USERNAME'"
        fi
        
        # Check if we have required scopes
        print_step "Checking GitHub CLI scopes for '$GH_USERNAME'..."
        if ! check_gh_scopes; then
            print_warning "Missing required scopes, refreshing authentication..."
            # Switch to user first, then refresh (gh auth refresh doesn't have --user flag)
            gh auth switch --user "$GH_USERNAME" 2>/dev/null || true
            gh auth refresh -s "$REQUIRED_SCOPES"
            
            if ! check_gh_scopes; then
                print_error "Failed to obtain required scopes"
                exit 1
            fi
        fi
        print_success "GitHub CLI has required scopes"
        
        # Ensure HTTPS protocol is used for git operations
        print_step "Setting git protocol to HTTPS..."
        gh config set -h github.com git_protocol https
        print_success "Git protocol set to HTTPS"
        
        # Setup gh as git credential helper
        print_step "Setting up GitHub CLI as git credential helper..."
        gh auth setup-git
        print_success "Git credential helper configured"
        return 0
    fi
    
    print_step "Account '$GH_USERNAME' is not authenticated"
    print_step "Please authenticate with GitHub CLI..."
    print_warning "A browser window will open for authentication (or use device code flow)"
    
    gh auth login --web --git-protocol https -s "$REQUIRED_SCOPES"
    
    # Verify the correct user logged in
    local logged_in_user
    logged_in_user=$(gh api user --jq '.login' 2>/dev/null || echo "")
    
    if [[ "$logged_in_user" != "$GH_USERNAME" ]]; then
        print_error "Logged in as '$logged_in_user' but expected '$GH_USERNAME'"
        print_error "Please run the script again and login with the correct account"
        exit 1
    fi
    
    print_success "GitHub CLI authentication successful for '$GH_USERNAME'"
    
    # Setup gh as git credential helper
    print_step "Setting up GitHub CLI as git credential helper..."
    gh auth setup-git
    print_success "Git credential helper configured"
}

#===============================================================================
# Interactive User Input
#===============================================================================

collect_user_input() {
    print_header "User Information"
    
    echo -e "${CYAN}Please provide the following information for Git and GPG setup:${NC}"
    echo ""
    
    # Get current git config for defaults
    local current_git_name=""
    local current_git_email=""
    current_git_name=$(git config --global user.name 2>/dev/null || echo "")
    current_git_email=$(git config --global user.email 2>/dev/null || echo "")
    
    # Get GitHub username for noreply email suggestion
    local gh_username=""
    if gh auth status &> /dev/null; then
        gh_username=$(gh api user --jq '.login' 2>/dev/null || echo "")
    fi
    
    # Full name
    if [[ -n "$current_git_name" ]]; then
        USER_NAME=$(prompt_input "Full name (for git commits)" "$current_git_name")
    else
        USER_NAME=$(prompt_input "Full name (for git commits)")
    fi
    if [[ -z "$USER_NAME" ]]; then
        print_error "Name is required"
        exit 1
    fi
    
    # Email address
    echo ""
    echo -e "${CYAN}Tip: Use your GitHub noreply email for privacy:${NC}"
    if [[ -n "$gh_username" ]]; then
        echo -e "${CYAN}     ${gh_username}@users.noreply.github.com${NC}"
    else
        echo -e "${CYAN}     <username>@users.noreply.github.com${NC}"
    fi
    if [[ -n "$current_git_email" ]]; then
        USER_EMAIL=$(prompt_input "Email address" "$current_git_email")
    else
        USER_EMAIL=$(prompt_input "Email address")
    fi
    if [[ -z "$USER_EMAIL" ]]; then
        print_error "Email is required"
        exit 1
    fi
    
    # SSH key name
    echo ""
    SSH_KEY_NAME=$(prompt_input "SSH key name" "$GH_USERNAME")
    
    # SSH passphrase
    echo ""
    echo -e "${CYAN}SSH passphrase (press Enter for no passphrase)${NC}"
    SSH_PASSPHRASE=$(prompt_password "SSH Passphrase")
    
    # Confirm passphrase only if one was entered
    if [[ -n "$SSH_PASSPHRASE" ]]; then
        local ssh_passphrase_confirm
        ssh_passphrase_confirm=$(prompt_password "Confirm SSH Passphrase")
        
        if [[ "$SSH_PASSPHRASE" != "$ssh_passphrase_confirm" ]]; then
            print_error "SSH passphrases do not match"
            exit 1
        fi
    fi
    
    # GPG key expiration
    echo ""
    echo -e "${CYAN}GPG key expiration (e.g., 1y, 2y, 0 for no expiration)${NC}"
    GPG_EXPIRATION=$(prompt_input "GPG key expiration" "2y")
    
    # GPG passphrase
    echo ""
    echo -e "${CYAN}GPG passphrase (press Enter for no passphrase)${NC}"
    GPG_PASSPHRASE=$(prompt_password "GPG Passphrase")
    
    # Confirm passphrase only if one was entered
    if [[ -n "$GPG_PASSPHRASE" ]]; then
        local gpg_passphrase_confirm
        gpg_passphrase_confirm=$(prompt_password "Confirm GPG Passphrase")
        
        if [[ "$GPG_PASSPHRASE" != "$gpg_passphrase_confirm" ]]; then
            print_error "Passphrases do not match"
            exit 1
        fi
    fi
    
    echo ""
    print_success "Configuration collected"
    echo ""
    echo -e "  Name:           ${GREEN}$USER_NAME${NC}"
    echo -e "  Email:          ${GREEN}$USER_EMAIL${NC}"
    echo -e "  SSH Key Name:   ${GREEN}$SSH_KEY_NAME${NC}"
    if [[ -n "$SSH_PASSPHRASE" ]]; then
        echo -e "  SSH Passphrase: ${GREEN}[set]${NC}"
    else
        echo -e "  SSH Passphrase: ${YELLOW}[none]${NC}"
    fi
    echo -e "  GPG Expiration: ${GREEN}$GPG_EXPIRATION${NC}"
    if [[ -n "$GPG_PASSPHRASE" ]]; then
        echo -e "  GPG Passphrase: ${GREEN}[set]${NC}"
    else
        echo -e "  GPG Passphrase: ${YELLOW}[none]${NC}"
    fi
    echo ""
    
    local confirm
    confirm=$(prompt_input "Continue with these settings? (y/n)" "y")
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_warning "Setup cancelled"
        exit 0
    fi
}

#===============================================================================
# SSH Setup
#===============================================================================

setup_ssh() {
    print_header "SSH Key Setup"
    
    local ssh_key_path="$HOME/.ssh/$SSH_KEY_NAME"
    
    # Create .ssh directory if it doesn't exist
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    
    # Check if key already exists
    if [[ -f "$ssh_key_path" ]]; then
        print_warning "SSH key already exists at $ssh_key_path"
        local overwrite
        overwrite=$(prompt_input "Overwrite existing key? (y/n)" "n")
        if [[ "$overwrite" != "y" && "$overwrite" != "Y" ]]; then
            print_step "Using existing SSH key"
        else
            rm -f "$ssh_key_path" "$ssh_key_path.pub"
        fi
    fi
    
    # Generate new key if it doesn't exist
    if [[ ! -f "$ssh_key_path" ]]; then
        print_step "Generating new ED25519 SSH key..."
        ssh-keygen -t ed25519 -C "$USER_EMAIL" -f "$ssh_key_path" -N "$SSH_PASSPHRASE"
        print_success "SSH key generated at $ssh_key_path"
    fi
    
    # Clear passphrase from memory
    SSH_PASSPHRASE=""
    
    # Start ssh-agent and add key
    print_step "Adding SSH key to ssh-agent..."
    eval "$(ssh-agent -s)" > /dev/null
    
    if [[ "$OS" == "macos" ]]; then
        # macOS: Add to keychain
        ssh-add --apple-use-keychain "$ssh_key_path" 2>/dev/null || ssh-add "$ssh_key_path"
        
        # Create/update SSH config for keychain
        local ssh_config="$HOME/.ssh/config"
        if ! grep -q "Host github.com" "$ssh_config" 2>/dev/null; then
            print_step "Updating SSH config for keychain integration..."
            cat >> "$ssh_config" << EOF

# GitHub SSH config (added by setup-github.sh)
Host github.com
    AddKeysToAgent yes
    UseKeychain yes
    IdentityFile "$ssh_key_path"
EOF
        fi
    else
        ssh-add "$ssh_key_path"
    fi
    
    # Upload to GitHub via gh CLI
    print_step "Uploading SSH key to GitHub..."
    local key_title="$SSH_KEY_NAME-$(hostname)-$(date +%Y%m%d)"
    
    local gh_output
    if gh_output=$(gh ssh-key add "$ssh_key_path.pub" --title "$key_title" 2>&1); then
        print_success "SSH key uploaded to GitHub"
    else
        # Check if key already exists (not an error)
        if echo "$gh_output" | grep -qi "already exists\|already been added"; then
            print_success "SSH key already exists on GitHub"
        else
            print_error "Failed to upload SSH key: $gh_output"
            exit 1
        fi
    fi
    
    # Test SSH connection
    print_step "Testing SSH connection to GitHub..."
    local ssh_result
    ssh_result=$(ssh -T git@github.com 2>&1 || true)
    if echo "$ssh_result" | grep -qi "successfully authenticated\|You've successfully authenticated"; then
        print_success "SSH authentication successful!"
    else
        print_warning "SSH test result: $ssh_result"
    fi
}

#===============================================================================
# GPG Setup
#===============================================================================

setup_gpg() {
    print_header "GPG Key Setup"
    
    # Create GPG directory
    print_step "Setting up GPG configuration..."
    mkdir -p "$HOME/.gnupg"
    chmod 700 "$HOME/.gnupg"
    
    # Create gpg.conf
    cat > "$HOME/.gnupg/gpg.conf" << 'EOF'
use-agent
EOF
    
    # Create gpg-agent.conf with OS-specific pinentry
    if [[ "$OS" == "macos" ]]; then
        local pinentry_path="/opt/homebrew/bin/pinentry-mac"
        # Fallback for Intel Macs
        if [[ ! -f "$pinentry_path" ]]; then
            pinentry_path="/usr/local/bin/pinentry-mac"
        fi
        
        cat > "$HOME/.gnupg/gpg-agent.conf" << EOF
default-cache-ttl 34560000
max-cache-ttl 34560000
pinentry-program $pinentry_path
EOF
    else
        # Linux terminal-only: use pinentry-tty
        local pinentry_path="/usr/bin/pinentry-tty"
        if [[ ! -f "$pinentry_path" ]]; then
            pinentry_path=$(which pinentry-tty 2>/dev/null || which pinentry 2>/dev/null || echo "/usr/bin/pinentry")
        fi
        
        cat > "$HOME/.gnupg/gpg-agent.conf" << EOF
default-cache-ttl 34560000
max-cache-ttl 34560000
pinentry-program $pinentry_path
allow-loopback-pinentry
EOF
        
        # Add GPG_TTY to shell profile for Linux
        setup_gpg_tty
    fi
    
    chmod 600 "$HOME/.gnupg/gpg.conf" "$HOME/.gnupg/gpg-agent.conf"
    
    # Restart gpg-agent to pick up new config
    gpgconf --kill gpg-agent 2>/dev/null || true
    
    # Check for existing GPG key
    local existing_key
    existing_key=$(gpg --list-secret-keys --keyid-format LONG "$USER_EMAIL" 2>/dev/null | grep -A 1 "sec" | tail -n 1 | tr -d ' ' || echo "")
    
    if [[ -n "$existing_key" ]]; then
        print_warning "GPG key already exists for $USER_EMAIL"
        local overwrite
        overwrite=$(prompt_input "Overwrite existing key? (y/n)" "n")
        if [[ "$overwrite" != "y" && "$overwrite" != "Y" ]]; then
            GPG_KEY_ID="$existing_key"
            print_step "Using existing GPG key: $GPG_KEY_ID"
            configure_git_gpg
            upload_gpg_key
            return 0
        fi
    fi
    
    # Generate new GPG key
    print_step "Generating new GPG key..."
    
    # Create batch file for GPG key generation
    local gpg_batch_file
    gpg_batch_file=$(mktemp)
    trap 'if [ -n "${gpg_batch_file:-}" ]; then rm -f -- "$gpg_batch_file"; fi' EXIT
    # Build batch file - use %no-protection for empty passphrase
    cat > "$gpg_batch_file" << EOF
%echo Generating GPG key
Key-Type: RSA
Key-Length: 4096
Key-Usage: sign
Name-Real: $USER_NAME
Name-Email: $USER_EMAIL
Expire-Date: $GPG_EXPIRATION
EOF
    
    if [[ -n "$GPG_PASSPHRASE" ]]; then
        echo "Passphrase: $GPG_PASSPHRASE" >> "$gpg_batch_file"
    else
        echo "%no-protection" >> "$gpg_batch_file"
    fi
    
    cat >> "$gpg_batch_file" << EOF
%commit
%echo GPG key generation complete
EOF
    
    # Set GPG_TTY for current session
    export GPG_TTY=$(tty)
    
    # Generate the key
    if [[ "$OS" == "linux" ]]; then
        # For Linux terminal, we need loopback pinentry mode
        gpg --batch --pinentry-mode loopback --generate-key "$gpg_batch_file"
    else
        gpg --batch --generate-key "$gpg_batch_file"
    fi
    
    # Securely remove batch file (contains passphrase)
    rm -f "$gpg_batch_file"
    
    # Clear passphrase from memory
    GPG_PASSPHRASE=""
    
    # Get the key ID
    GPG_KEY_ID=$(gpg --list-secret-keys --keyid-format LONG "$USER_EMAIL" 2>/dev/null | grep -A 1 "sec" | tail -n 1 | tr -d ' ')
    
    if [[ -z "$GPG_KEY_ID" ]]; then
        print_error "Failed to generate GPG key"
        exit 1
    fi
    
    print_success "GPG key generated: $GPG_KEY_ID"
    
    # Test GPG signing
    print_step "Testing GPG signing..."
    if echo "test" | gpg --clearsign > /dev/null 2>&1; then
        print_success "GPG signing works correctly"
    else
        print_warning "GPG signing test had issues (may still work for commits)"
    fi
    
    configure_git_gpg
    upload_gpg_key
}

setup_gpg_tty() {
    print_step "Setting up GPG_TTY environment variable..."
    
    local shell_rc=""
    local current_shell=$(basename "$SHELL")
    
    case "$current_shell" in
        zsh)
            shell_rc="$HOME/.zshrc"
            ;;
        bash)
            shell_rc="$HOME/.bashrc"
            ;;
        *)
            shell_rc="$HOME/.profile"
            ;;
    esac
    
    local gpg_tty_line='export GPG_TTY=$(tty)'
    
    if ! grep -q "GPG_TTY" "$shell_rc" 2>/dev/null; then
        echo "" >> "$shell_rc"
        echo "# GPG TTY for terminal pinentry (added by setup-github.sh)" >> "$shell_rc"
        echo "$gpg_tty_line" >> "$shell_rc"
        print_success "Added GPG_TTY to $shell_rc"
    else
        print_success "GPG_TTY already configured in $shell_rc"
    fi
    
    # Export for current session
    export GPG_TTY=$(tty)
}

configure_git_gpg() {
    print_step "Configuring Git to use GPG key..."
    git config --global user.signingkey "$GPG_KEY_ID"
    print_success "Git configured with GPG signing key"
}

upload_gpg_key() {
    print_step "Uploading GPG public key to GitHub..."
    
    local gpg_public_key
    gpg_public_key=$(gpg --armor --export "$GPG_KEY_ID")
    
    if [[ -z "$gpg_public_key" ]]; then
        print_error "Failed to export GPG public key"
        exit 1
    fi
    
    # Save key to temp file for gh cli
    local gpg_key_file
    gpg_key_file=$(mktemp)
    echo "$gpg_public_key" > "$gpg_key_file"
    
    # Upload via gh CLI
    local gh_output
    if gh_output=$(gh gpg-key add "$gpg_key_file" 2>&1); then
        print_success "GPG key uploaded to GitHub"
        rm -f "$gpg_key_file"
    else
        rm -f "$gpg_key_file"
        
        # Check if key already exists (not an error)
        if echo "$gh_output" | grep -qi "already exists\|already been added"; then
            print_success "GPG key already exists on GitHub"
            return 0
        fi
        
        print_error "Failed to upload GPG key: $gh_output"
        exit 1
    fi
}

#===============================================================================
# Git Configuration
#===============================================================================

setup_git_config() {
    print_header "Git Global Configuration"
    
    print_step "Configuring Git global settings..."
    
    # Unset any conflicting format
    git config --global --unset gpg.format 2>/dev/null || true
    
    # Set user info
    git config --global user.name "$USER_NAME"
    git config --global user.email "$USER_EMAIL"
    
    # Enable GPG signing
    git config --global commit.gpgSign true
    git config --global tag.gpgSign true
    
    print_success "Git global configuration complete"
}

#===============================================================================
# Verification
#===============================================================================

verify_setup() {
    print_header "Setup Verification"
    
    echo -e "${CYAN}Git Global Configuration:${NC}"
    echo ""
    git config --global --list | grep -E "^user\.|^commit\.gpgsign|^tag\.gpgsign|^gpg\.|^credential\." | while read -r line; do
        echo -e "  ${GREEN}$line${NC}"
    done
    
    echo ""
    echo -e "${CYAN}SSH Key:${NC}"
    echo -e "  Private: ${GREEN}$HOME/.ssh/$SSH_KEY_NAME${NC}"
    echo -e "  Public:  ${GREEN}$HOME/.ssh/$SSH_KEY_NAME.pub${NC}"
    
    echo ""
    echo -e "${CYAN}GPG Key:${NC}"
    echo -e "  Key ID:  ${GREEN}$GPG_KEY_ID${NC}"
    
    echo ""
    echo -e "${CYAN}GitHub CLI:${NC}"
    echo -e "  Account: ${GREEN}$GH_USERNAME${NC}"
    gh auth status 2>&1 | grep -A3 "account $GH_USERNAME" | grep -E "Active account|Git operations|Token scopes" | while read -r line; do
        echo -e "  ${GREEN}$line${NC}"
    done
    
    echo ""
    print_success "Setup complete!"
    
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  Git Authentication Options${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${GREEN}HTTPS (default, recommended):${NC}"
    echo -e "    Git push/pull uses GitHub CLI automatically"
    echo ""
    echo -e "  ${GREEN}SSH (alternative):${NC}"
    echo -e "    To switch a repo from HTTPS to SSH, run:"
    echo -e "    ${BLUE}url=\$(git remote get-url origin | sed 's|https://github.com/|git@github.com:|') && git remote set-url origin \"\$url\" && git remote set-url --push origin \"\$url\"${NC}"
    echo ""
    
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  Next Steps${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  1. Your commits will now be signed automatically"
    echo -e "  2. You'll see a ${GREEN}'Verified'${NC} badge on GitHub commits"
    echo ""
    
    if [[ "$OS" == "linux" ]]; then
        echo -e "  ${YELLOW}Note: Run 'source ~/.bashrc' or 'source ~/.zshrc' to enable GPG_TTY${NC}"
        echo -e "  ${YELLOW}      in your current terminal session.${NC}"
        echo ""
    fi
    
    echo -e "  To test, make a commit and check it on GitHub:"
    echo -e "    ${BLUE}git commit --allow-empty -m 'Test signed commit'${NC}"
    echo -e "    ${BLUE}git log --show-signature -1${NC}"
    echo ""
    
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  SSO Configuration (if using SSH with organization repos)${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  If your organization uses SAML SSO and you want to use SSH,"
    echo -e "  you need to authorize your SSH key for SSO access:"
    echo ""
    echo -e "  1. Go to: ${BLUE}https://github.com/settings/keys${NC}"
    echo -e "  2. Find your SSH key and click ${GREEN}'Configure SSO'${NC}"
    echo -e "  3. Authorize it for your organization"
    echo ""
    echo -e "  ${YELLOW}Note: HTTPS authentication (default) does not require SSO setup.${NC}"
    echo ""
}

#===============================================================================
# Main
#===============================================================================

main() {
    print_header "GitHub Setup Automation Script"
    echo -e "${CYAN}This script will set up GitHub CLI, SSH keys, and GPG commit signing${NC}"
    echo ""
    
    # Detect OS
    detect_os
    
    # Install prerequisites
    install_prerequisites
    
    # Collect GitHub username first
    collect_gh_username
    
    # Setup GitHub CLI authentication for the specific user
    setup_gh_auth
    
    # Collect user input (name, email, SSH, GPG settings)
    collect_user_input
    
    # Setup SSH
    setup_ssh
    
    # Setup GPG
    setup_gpg
    
    # Configure Git
    setup_git_config
    
    # Verify setup
    verify_setup
}

# Run main function
main "$@"
