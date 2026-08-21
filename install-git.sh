#!/bin/bash

# Check if the script is being run with root privileges
if [ "$EUID" -ne 0 ]; then
  echo "Error: Please run this script with root privileges (sudo)."
  exit 1
fi

# Check if Git is already installed
if command -v git &> /dev/null; then
  echo "Git is already installed. Version: $(git --version)"
else
  echo "Git was not found. Starting installation..."
  
  # Update package lists
  echo "Updating package lists (apt update)..."
  apt update -y
  
  # Install Git
  echo "Installing Git..."
  apt install git -y
  
  # Verify the installation was successful
  if command -v git &> /dev/null; then
    echo "Git installed successfully! Version: $(git --version)"
  else
    echo "Error: Git installation failed."
    exit 1
  fi
fi

# Optionally install GitHub CLI (gh)
read -p "Do you want to install GitHub CLI (gh)? [y/N]: " -r INSTALL_GH
if [[ "$INSTALL_GH" =~ ^[Yy]$ ]]; then
  if command -v gh &> /dev/null; then
    echo "GitHub CLI is already installed. Version: $(gh --version | head -n1)"
  else
    echo "GitHub CLI was not found. Starting installation..."
    
    # Add GitHub's official apt repository
    echo "Adding GitHub CLI apt repository..."
    mkdir -p -m 755 /etc/apt/keyrings
    wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null
    
    # Update package lists and install gh
    echo "Updating package lists (apt update)..."
    apt update -y
    echo "Installing GitHub CLI..."
    apt install gh -y
    
    # Verify the installation was successful
    if command -v gh &> /dev/null; then
      echo "GitHub CLI installed successfully! Version: $(gh --version | head -n1)"
    else
      echo "Error: GitHub CLI installation failed."
      exit 1
    fi
  fi
else
  echo "Skipping GitHub CLI installation."
fi
