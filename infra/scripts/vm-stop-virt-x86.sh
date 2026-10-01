#!/bin/sh
set -eu

echo "Stopping bsdos-x86 VM..."

# Try graceful shutdown first
virsh shutdown bsdos-x86 2>/dev/null && {
  echo "Graceful shutdown initiated. Waiting for VM to stop..."
  sleep 5
} || {
  echo "Graceful shutdown failed or VM not running. Force destroying..."
  virsh destroy bsdos-x86 2>/dev/null || true
}

echo "✓ VM stopped"
