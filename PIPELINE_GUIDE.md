# GitHub Actions Update Pipeline - Complete Guide

## Table of Contents
1. [Architecture Overview](#architecture-overview)
2. [File-by-File Breakdown](#file-by-file-breakdown)
3. [Security Features](#security-features)
4. [Setup and Configuration](#setup-and-configuration)
5. [How It Works (Step-by-Step)](#how-it-works-step-by-step)
6. [Troubleshooting](#troubleshooting)

---

## Architecture Overview

This pipeline uses a **reusable workflow pattern** in GitHub Actions:

```
┌─────────────────────────────────────────────────────────────────┐
│ automatic_checker.yaml (CALLER / ENTRY POINT)                  │
│ - Triggered manually via workflow_dispatch button              │
│ - Defines deployment configuration (server IPs, paths, etc.)   │
│ - Calls the reusable template and passes configuration values  │
└────────────────────┬────────────────────────────────────────────┘
                     │ calls with inputs
                     ↓
┌─────────────────────────────────────────────────────────────────┐
│ update_pipeline_template.yml (REUSABLE TEMPLATE)               │
│ - Contains all pipeline logic                                  │
│ - Receives configuration from caller                           │
│ - Performs: fetch → verify → scan → deploy                    │
│ - Can be called by multiple workflows                          │
└─────────────────────────────────────────────────────────────────┘
```

**Why this pattern?**
- **Separation of concerns**: Caller defines "where/what", template defines "how".
- **Reusability**: Template can be called by different workflows with different configurations.
- **Maintainability**: Update pipeline logic once, all callers benefit.
- **Simplicity**: Non-technical users edit `automatic_checker.yaml` to change deployment targets; technical users maintain `update_pipeline_template.yml`.

---

## File-by-File Breakdown

### 1. `automatic_checker.yaml` (The Caller / Entry Point)

**Location**: `.github/workflows/automatic_checker.yaml`

**Purpose**: Orchestrates when and how the pipeline runs. Acts as the "configuration file" for deployment.

**Key Sections**:

```yaml
name: Run update pipeline

on:
  workflow_dispatch:
```
- **`on: workflow_dispatch`**: Allows manual triggering from GitHub UI. No schedule or push required.

```yaml
jobs:
  run-update:
    uses: ./.github/workflows/update_pipeline_template.yml
    with:
      web_server: 172.16.1.10
      web_path: /var/www/html
      deploy_user: student
      public_key_path: /home/github-runner/public.key
      workdir_base: /home/github-runner/update-workdir
      gpg_fingerprint: ""
      ssh_known_hosts: ""
      enable_verification: false
```
- **`uses:`** Calls the reusable template (`./.github/workflows/update_pipeline_template.yml` means "in this repo").
- **`with:`** Passes configuration values to the template as inputs.

**What to edit here**:
- `web_server`: Change the target server IP or hostname.
- `web_path`: Change where files are deployed on the web server.
- `deploy_user`: Change the SSH user account used for SCP.
- `gpg_fingerprint`: Paste the GPG fingerprint (obtained from setup step).
- `ssh_known_hosts`: Paste the SSH host key (obtained from setup step).
- `enable_verification`: Set to `true` to run post-deployment health checks.

**When to edit**:
- When deploying to a different server.
- When updating security credentials (GPG fingerprint, SSH host key).
- When enabling/disabling verification checks.

---

### 2. `update_pipeline_template.yml` (The Reusable Template)

**Location**: `.github/workflows/update_pipeline_template.yml`

**Purpose**: Contains the entire secure update pipeline logic. Receives configuration from caller and executes all steps.

**Key Sections**:

#### **Workflow Metadata**
```yaml
name: Update pipeline template

on:
  workflow_call:
    inputs:
      # All input definitions
```
- **`on: workflow_call`**: Declares this as a reusable workflow. Cannot run standalone; must be called by another workflow.
- **`inputs:`** Defines configuration parameters that the caller must provide.

#### **Inputs (Configuration Parameters)**

| Input | Type | Purpose | Default |
|-------|------|---------|---------|
| `web_server` | string | Target web server IP/hostname | `172.16.1.10` |
| `web_path` | string | Deployment directory on web server | `/var/www/html` |
| `deploy_user` | string | SSH user for file transfer | `student` |
| `public_key_path` | string | Path to GPG public key on runner | `/home/github-runner/public.key` |
| `workdir_base` | string | Temporary workspace base directory | `/home/github-runner/update-workdir` |
| `gpg_fingerprint` | string | Expected GPG key fingerprint (ZTN) | `` (empty = disabled) |
| `ssh_known_hosts` | string | SSH host key entry (ZTN) | `` (empty = disabled) |
| `enable_verification` | boolean | Run post-deploy health checks | `false` |

#### **Job Configuration**
```yaml
jobs:
  run-update:
    runs-on: [self-hosted, linux]
    defaults:
      run:
        shell: bash
```
- **`runs-on: [self-hosted, linux]`**: Runs on a self-hosted runner labeled "linux" (your update server).
- **`defaults: run: shell: bash`**: All steps use bash by default.

#### **Steps**

##### **Step 1: Checkout Repository**
```yaml
- name: Checkout repository
  uses: actions/checkout@v4
```
- Clones the repository to the runner.
- Provides access to `latest.txt`, `.zip`, and `.sig` files.

##### **Step 2: Show Runner Context**
```yaml
- name: Show runner context
  run: |
    echo "Runner OS: ${RUNNER_OS}"
    echo "Runner name: ${RUNNER_NAME}"
    echo "Workspace: ${GITHUB_WORKSPACE}"
    pwd
```
- Diagnostic step. Prints runner information for debugging.

##### **Step 3: Execute Secure Update Pipeline**
```yaml
- name: Execute secure update pipeline
  env:
    REPO_DIR: ${{ github.workspace }}
    WEB_SERVER: ${{ inputs.web_server }}
    # ... more env vars
  run: |
    # 300+ lines of bash script containing all pipeline functions
```
- Main step. Contains the entire pipeline logic as a bash script.
- Injects all inputs as environment variables.

---

## Security Features

The pipeline implements **Zero Trust Network (ZTN)** security principles:

### 1. **GPG Signature Verification** (Package Authenticity)

**What it does**:
- Verifies that the update package was signed by the publisher using their private key.
- Ensures the package has not been modified in transit or at rest.

**How it works**:
1. Publisher signs the ZIP file: `gpg --detach-sign update.zip` → creates `update.zip.sig`.
2. Pipeline imports the public key from `public_key_path`.
3. Pipeline runs `gpg --verify update.zip.sig update.zip`.
4. If signature is valid, continues; if invalid, fails.

**Fingerprint Validation** (Additional ZTN Control):
- Prevents key substitution attacks.
- Pipeline compares imported key fingerprint to expected `gpg_fingerprint`.
- If mismatch, fails even if signature verifies.

**Command to set up**:
```bash
# Export public key (share with runner)
gpg --armor --export you@example.com > public.key

# Get fingerprint (provide to pipeline)
gpg --with-colons --list-keys you@example.com | grep fpr | cut -d: -f10
```

### 2. **SSH Host Key Pinning** (Connection Security)

**What it does**:
- Prevents man-in-the-middle attacks during SCP file transfer.
- Ensures the runner connects only to the correct web server.

**How it works**:
1. Operator captures web server's host key: `ssh-keyscan -H 172.16.1.10`.
2. Pipeline writes host key to temporary `known_hosts` file.
3. Pipeline forces `StrictHostKeyChecking=yes` in SSH options.
4. If server presents a different key, connection fails.

**Command to set up**:
```bash
# Capture host key (run from trusted machine)
ssh-keyscan -H 172.16.1.10 2>/dev/null
# Example output:
# 172.16.1.10 ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQD...
```

### 3. **Malware Scanning** (Content Verification)

**What it does**:
- Scans extracted archive for known malware signatures using ClamAV.
- Blocks deployment if malware is detected.

**How it works**:
1. After extracting ZIP, runs `clamscan -r` on all files.
2. Exit codes: `0` = clean, `1` = infected (fail), `2+` = error (fail).
3. Continues only if exit code is 0.

**Command to verify setup**:
```bash
# Check ClamAV installation
clamscan --version
# Update malware signatures
sudo freshclam
```

### 4. **Isolated Workspace** (Process Isolation)

**What it does**:
- Creates temporary directories unique to each pipeline run.
- Prevents cross-run contamination or credential leaks.
- Automatically cleaned up after run completes.

**How it works**:
1. Creates base directory: `mkdir -p $WORKDIR_BASE`
2. Creates unique temp dir: `mktemp -d $WORKDIR_BASE/run.XXXXXX`
3. Creates sub-directories: `extracted/` (extracted files), `gnupg/` (isolated keyring)
4. Automatic cleanup: `trap cleanup EXIT` removes all files on exit.

### 5. **Strict Error Handling** (Fail-Fast)

**What it does**:
- Immediately exits if any command fails.
- Prevents silent failures or partial deployments.

**How it works**:
- Uses `set -Eeuo pipefail`:
  - `-E`: Inherit ERR trap in functions
  - `-e`: Exit on error
  - `-u`: Error on undefined variables
  - `-o pipefail`: Pipeline fails if any command fails

---

## Setup and Configuration

### Prerequisites

**On the Update Server (Self-Hosted Runner)**:
- Ubuntu Linux or similar
- GitHub Actions self-hosted runner configured and running
- Tools installed:
  - `gpg` (GPG command-line tool)
  - `unzip` (ZIP extraction)
  - `clamscan` (ClamAV malware scanner)
  - `scp` (OpenSSH for file transfer)
  - `bash` (shell)

**On the Signing Machine** (where you create GPG keys):
- `gpg` (GnuPG)
- Access to the update repository

**On the Web Server** (deployment target):
- SSH server running
- User account with write permissions to deployment path
- Adequate disk space for updates

### Step-by-Step Setup

#### **Step 1: Generate GPG Key (One-time)**

On your signing machine:

```bash
# Generate interactive key
gpg --full-generate-key
# Follow prompts: RSA, 3072 bits, no expiration, name + email

# List your keys
gpg --list-keys

# Export public key (safe to share)
gpg --armor --export your-email@example.com > public.key

# Get fingerprint (40-char hex string)
gpg --with-colons --list-keys your-email@example.com | grep fpr | cut -d: -f10
# Copy this fingerprint — you'll need it for pipeline configuration
```

#### **Step 2: Place Public Key on Runner**

On the update server:

```bash
# Copy public.key to the path referenced in pipeline
# Default: /home/github-runner/public.key
sudo cp public.key /home/github-runner/public.key
sudo chmod 644 /home/github-runner/public.key
```

Or provide it as a workflow secret and write it during the pipeline run.

#### **Step 3: Sign Your Update Files**

On your signing machine, before committing to the repository:

```bash
# Sign the ZIP file (creates detached signature)
gpg --armor --output update.zip.sig --detach-sign update.zip

# Commit both to repository
git add update.zip update.zip.sig latest.txt
git commit -m "Release v1.0.0 update packages"
git push
```

#### **Step 4: Capture SSH Host Key**

From any trusted machine:

```bash
# Capture the web server's SSH host key
ssh-keyscan -H 172.16.1.10 2>/dev/null
# Example output:
# 172.16.1.10 ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQD...

# Copy this entire line — you'll need it for pipeline configuration
```

#### **Step 5: Configure Pipeline**

Edit `.github/workflows/automatic_checker.yaml`:

```yaml
with:
  web_server: 172.16.1.10           # Your web server IP
  web_path: /var/www/html           # Deployment directory
  deploy_user: student              # SSH user
  public_key_path: /home/github-runner/public.key  # GPG key location
  workdir_base: /home/github-runner/update-workdir # Temp directory
  gpg_fingerprint: "3F4B7D2E..."    # Paste full 40-char fingerprint
  ssh_known_hosts: "172.16.1.10 ssh-rsa AAAAB3..." # Paste host key line
  enable_verification: false         # Enable verification if needed
```

#### **Step 6: Ensure SSH Auth on Runner**

The runner must be able to authenticate to the web server as `deploy_user`:

```bash
# Option A: SSH key-based auth (recommended)
# Generate SSH key on runner (no passphrase for CI)
ssh-keygen -t rsa -N "" -f ~/.ssh/github_runner_deploy_key

# Copy public key to web server
ssh-copy-id -i ~/.ssh/github_runner_deploy_key student@172.16.1.10

# Test
ssh -i ~/.ssh/github_runner_deploy_key student@172.16.1.10 "echo OK"

# Option B: Use GitHub Secrets
# Store SSH private key as repository secret
# Pipeline extracts it and writes to ~/.ssh/
```

---

## How It Works (Step-by-Step)

### Execution Flow

```
1. Manual Trigger
   ├─ Go to GitHub → Actions tab
   ├─ Select "Run update pipeline"
   └─ Click "Run workflow" button
           ↓
2. automatic_checker.yaml runs
   ├─ Reads configuration (web server, paths, credentials)
   └─ Calls update_pipeline_template.yml with inputs
           ↓
3. update_pipeline_template.yml runs on self-hosted runner
   ├─ STEP 1: Validate required tools
   │  └─ Ensure gpg, unzip, clamscan, scp exist
   │
   ├─ STEP 2: Initialize isolated runtime workspace
   │  └─ Create temp directory structure
   │
   ├─ STEP 3: Resolve latest update version
   │  └─ Read latest.txt → determines version name
   │
   ├─ STEP 4: Copy local update package and signature
   │  └─ Copy .zip and .sig from repository to temp directory
   │
   ├─ STEP 5: Verify package signature
   │  ├─ Import GPG public key
   │  ├─ Validate fingerprint (ZTN)
   │  └─ Verify .zip is cryptographically signed correctly
   │
   ├─ STEP 6: Extract update archive
   │  └─ Unzip contents to isolated directory
   │
   ├─ STEP 7: Scan extracted content
   │  └─ Run ClamAV malware scan
   │
   ├─ STEP 8: Deploy to target web server
   │  ├─ Pin SSH host key (ZTN)
   │  ├─ Copy files via SCP to web server
   │  └─ Update web server content
   │
   ├─ STEP 9: Post-deployment verification
   │  └─ Run optional health checks
   │
   └─ STEP 10: Cleanup
      └─ Remove temporary directories and files
```

### What Gets Checked

| Check | Purpose | Fail Condition |
|-------|---------|----------------|
| **GPG Fingerprint** | Verifies key identity (ZTN) | Fingerprint mismatch |
| **GPG Signature** | Verifies package authenticity | Signature invalid |
| **Malware Scan** | Detects compromised files | ClamAV returns exit code 1 |
| **SSH Host Key** | Prevents MITM (ZTN) | Server key doesn't match pinned key |
| **File Existence** | Ensures files are present | Missing .zip or .sig |
| **Prerequisites** | Ensures tools are installed | Required tool not found |

### Example Success Output

```
==============================
 AUTO SECURE UPDATE PIPELINE 
 (Zero Trust Network Ready)   
==============================
[INFO] Configuration summary
[INFO] REPO_DIR=/home/runner/work/web-server-updates/web-server-updates
[INFO] WEB_SERVER=172.16.1.10
[INFO] WEB_PATH=/var/www/html
[INFO] DEPLOY_USER=student
[INFO] GPG_FINGERPRINT=3F4B7D2E9A1C6F8E4D5B7A9F2E3C1A5D
[INFO] SSH_KNOWN_HOSTS=172.16.1.10 ssh-rsa AAAAB3...

========== STEP 1: Validate required tools ==========
[INFO] All required tools are available

========== STEP 2: Initialize isolated runtime workspace ==========
[INFO] Runtime directory: /home/github-runner/update-workdir/run.abc123xyz

========== STEP 3: Resolve latest update version ==========
[INFO] Latest version: v1.0.0

========== STEP 4: Copy local update package and signature ==========
[INFO] Copied package: v1.0.0.zip
[INFO] Copied signature: v1.0.0.sig

========== STEP 5: Verify package signature ==========
[INFO] GPG fingerprint validated: 3F4B7D2E9A1C6F8E4D5B7A9F2E3C1A5D
[INFO] Signature verification passed

... (steps 6-9)

========== PIPELINE COMPLETE ==========
[INFO] Deployment successful (ZTN compliant)
```

---

## Troubleshooting

### Common Issues

#### **"latest.txt not found in repository"**
- **Cause**: File missing from repository root.
- **Fix**: Create `latest.txt` with version identifier (e.g., `v1.0.0`).

#### **"Package not found: v1.0.0.zip"**
- **Cause**: ZIP file not in repository or version mismatch.
- **Fix**: Ensure `v1.0.0.zip` exists in repository root matching version in `latest.txt`.

#### **"Signature verification failed"**
- **Cause**: 
  - Signature file is corrupt.
  - ZIP file was modified after signing.
  - Wrong public key.
- **Fix**: Re-sign files: `gpg --detach-sign update.zip`.

#### **"GPG fingerprint mismatch"**
- **Cause**: Wrong public key provided, or key has changed.
- **Fix**: 
  1. Verify correct `public.key` is on runner.
  2. Get correct fingerprint: `gpg --with-colons --list-keys | grep fpr | cut -d: -f10`
  3. Update `gpg_fingerprint` in `automatic_checker.yaml`.

#### **"Malware detected"**
- **Cause**: ClamAV detected malware signature in extracted files.
- **Fix**: 
  - Verify files are legitimate (antivirus may have false positives).
  - Update ClamAV signatures: `sudo freshclam`.
  - Investigate file source if genuine concern.

#### **"SSH host key pinning enabled but scp fails"**
- **Cause**: 
  - Host key changed on web server.
  - `SSH_KNOWN_HOSTS` value is incorrect.
- **Fix**: 
  1. Recapture host key: `ssh-keyscan -H 172.16.1.10 2>/dev/null`
  2. Update `ssh_known_hosts` in `automatic_checker.yaml`.

#### **"Required command not found: gpg/unzip/clamscan/scp"**
- **Cause**: Tool not installed on runner.
- **Fix**: Install on update server:
  ```bash
  sudo apt-get update
  sudo apt-get install -y gnupg unzip clamav clamav-daemon openssh-client
  sudo freshclam  # Update ClamAV signatures
  ```

#### **"Deployment failed" (SCP error)**
- **Cause**: 
  - Authentication issue (SSH key not set up).
  - Network unreachable.
  - Permission denied on web server.
- **Fix**:
  1. Test SSH manually from runner: `ssh student@172.16.1.10 "echo OK"`
  2. Verify permissions on web server: `ls -ld /var/www/html`
  3. Check network connectivity: `ping 172.16.1.10`

---

## Summary

| Concept | Location | Purpose |
|---------|----------|---------|
| **automatic_checker.yaml** | `.github/workflows/` | Entry point; caller; configuration management |
| **update_pipeline_template.yml** | `.github/workflows/` | Reusable template; contains all pipeline logic |
| **GPG Fingerprint** | `automatic_checker.yaml` input | Verifies GPG public key identity (ZTN) |
| **SSH Host Key** | `automatic_checker.yaml` input | Verifies web server identity (ZTN) |
| **Isolated Workspace** | `update_pipeline_template.yml` | Temporary directory for each run; auto-cleanup |
| **Public Key Path** | `automatic_checker.yaml` input | Location of GPG public key on runner |
| **Deployment Target** | `automatic_checker.yaml` inputs | Web server IP, path, user for SCP |

---

## Next Steps

1. **Verify all prerequisites** are installed on update server.
2. **Generate and configure GPG key** (sign your packages).
3. **Set up SSH authentication** (runner → web server).
4. **Capture and pin SSH host key** (MITM prevention).
5. **Populate `automatic_checker.yaml`** with fingerprint and host key.
6. **Test pipeline manually** via GitHub Actions UI (Actions tab → "Run update pipeline").
7. **Monitor logs** for any errors and resolve per troubleshooting guide.

---

## Additional Resources

- [GitHub Actions Reusable Workflows](https://docs.github.com/en/actions/using-workflows/reusing-workflows)
- [GPG Manual](https://www.gnupg.org/gph/en/manual.html)
- [SSH known_hosts Format](https://man.openbsd.org/sshd#SSH_KNOWN_HOSTS_FILE_FORMAT)
- [ClamAV Documentation](https://docs.clamav.net/)
- [Zero Trust Network Principles](https://www.nist.gov/publications/zero-trust-architecture)
