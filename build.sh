#!/bin/bash
# Build the OpenCode desktop widget
# Requires: macOS, swiftc (Xcode CommandLineTools), libsqlite3
set -e
cd "$(dirname "$0")"
swiftc -O -lsqlite3 -framework AppKit -framework SwiftUI -o opencode-widget main.swift
echo "built: $(pwd)/opencode-widget"
echo "run with: ./opencode-widget &"
