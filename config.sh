#!/bin/bash
# Configuration file for image server
# Source this file in scripts to get configuration variables

# User configuration - UPDATE THIS FOR YOUR SYSTEM
export IMAGE_SERVER_USER="${IMAGE_SERVER_USER:-yourusername}"
export IMAGE_SERVER_HOME="${IMAGE_SERVER_HOME:-/home/$IMAGE_SERVER_USER}"
export IMAGE_SERVER_DIR="${IMAGE_SERVER_DIR:-$IMAGE_SERVER_HOME/image-server}"

# Paths
export IMAGES_DIR="${IMAGES_DIR:-$IMAGE_SERVER_HOME/images}"
export LOG_FILE="${LOG_FILE:-$IMAGE_SERVER_HOME/image-server.log}"

