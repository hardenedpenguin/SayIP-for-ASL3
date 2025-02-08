#!/bin/sh -e

# Enhanced script for configuring sayip/reboot/halt for AllStar Link (ASL3)
# Copyright (C) 2024 Jory A. Pratt - W5GLE
# Released under the GNU General Public License v2 or later.

LOG_FILE="/var/log/asl3_sayip_setup.log"
touch "$LOG_FILE"
exec >> "$LOG_FILE" 2>&1

# Ensure the script is run as root
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root or with sudo"
  exit 1
fi

# Validate input arguments
if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <NodeNumber>"
  exit 1
fi

NODE_NUMBER="$1"
if ! echo "$NODE_NUMBER" | grep -qE '^[0-9]+$'; then
  echo "Error: NodeNumber must be a positive integer."
  exit 1
fi

CONF_FILE="/etc/asterisk/rpt.conf"
BASE_URL="https://dev.gentoo.org/~anarchy/asl3-scripts"
TARGET_DIR="/etc/asterisk/local"

# Create target directory and change to it
mkdir -p "$TARGET_DIR" && cd "$TARGET_DIR" || {
  echo "Failed to create and change directory to $TARGET_DIR"
  exit 1
}

CHECKSUM_URL="$BASE_URL/checksums.sha256"
CHECKSUM_FILE="checksums.sha256"

# Download the checksum file to verify the integrity of other downloaded files.
curl -s -o "$CHECKSUM_FILE" "$CHECKSUM_URL" || {
  echo "Error: Failed to download checksum file."
  exit 1
}

download_and_verify() {
    local expected_hash="$1"
    local filename="$2"

    if [ ! -f "$filename" ]; then  # Check if file *doesn't* exist first
        echo "$filename: Missing, downloading..."
    else
        actual_hash=$(sha256sum "$filename" | awk '{print $1}')
        if [ "$expected_hash" = "$actual_hash" ]; then
            echo "$filename: OK"
            return 0
        else
            echo "$filename: Checksum mismatch, re-downloading..."
            rm -f "$filename"
            echo "$filename: Missing, downloading..." # Immediately download after removal
        fi
    fi

    curl -s -o "$filename" "$BASE_URL/$filename" || {
        echo "Error downloading $filename"
        return 1
    }
    actual_hash=$(sha256sum "$filename" | awk '{print $1}') # Checksum after download
    if [ "$expected_hash" = "$actual_hash" ]; then
        echo "$filename: Downloaded and verified"
        return 0
    else
        echo "$filename: Download failed verification"
        return 1
    fi
}

# Verify and download files
while read -r expected_hash filename; do
    if ! download_and_verify "$expected_hash" "$filename"; then
        echo "Error with $filename, exiting"
        exit 1
    fi
done < "$CHECKSUM_FILE"

rm "$CHECKSUM_FILE"

# Set permissions and ownership
for file in *.sh *.ulaw; do
    chmod 750 "$file"
    chmod 640 "$file"
    chown root:asterisk "$file" 2>/dev/null || echo "Unable to set ownership (run as root for this step)"
done

# Create systemd service file
cat <<EOF > /etc/systemd/system/allstar-sayip.service
[Unit]
Description=AllStar SayIP Service
After=asterisk.service
Requires=asterisk.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'sleep 5s && /etc/asterisk/local/sayip.sh $NODE_NUMBER'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable allstar-sayip

# Backup and modify the configuration file
if ! grep -q "cmd,/etc/asterisk/local/sayip.sh" "$CONF_FILE"; then
  echo "Backing up and modifying $CONF_FILE..."
  cp "$CONF_FILE" "${CONF_FILE}.bak"
  sed -i '/\[functions\]/a \
A1 = cmd,/etc/asterisk/local/sayip.sh $NODE_NUMBER\n\
A3 = cmd,/etc/asterisk/local/saypublicip.sh $NODE_NUMBER\n\
\n\
B1 = cmd,/etc/asterisk/local/halt.sh $NODE_NUMBER\n\
B3 = cmd,/etc/asterisk/local/reboot.sh $NODE_NUMBER\n\
\n' "$CONF_FILE"
else
  echo "Commands already exist in $CONF_FILE, skipping modification."
fi

# Redirect final output to terminal (stdout)
printf "ASL3 support for sayip/reboot/halt is configured for node %s.\nLogs can be found in %s.\n" "$NODE_NUMBER" "$LOG_FILE" > /dev/tty