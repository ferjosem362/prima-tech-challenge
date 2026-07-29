#!/usr/bin/env bash
# Checks that every tool the project needs is present, and prints the exact
# install command for whatever is missing — adapted to the detected distro.
# It never installs anything by itself: a script that silently mutates your
# machine is a bad neighbour.
set -uo pipefail

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'; RESET=$'\033[0m'
missing=0

# --- Environment detection -------------------------------------------------
if command -v dnf >/dev/null 2>&1; then
  FAMILY="fedora"
  # Fedora 41+ ships dnf5, where `config-manager --add-repo` was replaced by
  # `config-manager addrepo --from-repofile=`. Emitting the wrong one fails.
  if command -v dnf5 >/dev/null 2>&1 || dnf --version 2>/dev/null | grep -qi '^dnf5'; then
    DNF_MAJOR=5
  else
    DNF_MAJOR=4
  fi
elif command -v apt-get >/dev/null 2>&1; then
  FAMILY="debian"
else
  FAMILY="unknown"
fi
DNF_MAJOR="${DNF_MAJOR:-0}"

# Emit the right "add this repo" invocation for the detected dnf generation.
addrepo() {
  if [ "$DNF_MAJOR" -ge 5 ]; then
    echo "sudo dnf config-manager addrepo --from-repofile=$1"
  else
    echo "sudo dnf install -y dnf-plugins-core && sudo dnf config-manager --add-repo $1"
  fi
}

IS_WSL=0
grep -qiE "microsoft|wsl" /proc/version 2>/dev/null && IS_WSL=1

printf '%s==> Environment%s\n' "$CYAN" "$RESET"
printf '  distro family : %s%s\n' "$FAMILY" "$([ "$DNF_MAJOR" -gt 0 ] && echo " (dnf${DNF_MAJOR})" || echo '')"
printf '  WSL           : %s\n' "$([ "$IS_WSL" -eq 1 ] && echo yes || echo no)"
echo

# --- Install recipes -------------------------------------------------------
# Each entry returns the command appropriate to the detected package manager.
recipe() {
  case "$1" in
    python3)
      [ "$FAMILY" = fedora ] && echo "sudo dnf install -y python3 python3-pip" \
                             || echo "sudo apt install -y python3 python3-venv python3-pip" ;;
    git)
      [ "$FAMILY" = fedora ] && echo "sudo dnf install -y git" \
                             || echo "sudo apt install -y git" ;;
    unzip)
      [ "$FAMILY" = fedora ] && echo "sudo dnf install -y unzip" \
                             || echo "sudo apt install -y unzip" ;;
    docker)
      if [ "$FAMILY" = fedora ]; then
        echo "$(addrepo https://download.docker.com/linux/fedora/docker-ce.repo) && sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin && sudo systemctl enable --now docker && sudo usermod -aG docker \$USER"
      else
        echo "curl -fsSL https://get.docker.com | sudo sh && sudo usermod -aG docker \$USER"
      fi ;;
    terraform)
      if [ "$FAMILY" = fedora ]; then
        # Official binary rather than the HashiCorp repo: it does not depend on
        # a repo being published for this exact Fedora release, which lags.
        echo "TF_VER=\$(curl -fsSL https://api.releases.hashicorp.com/v1/releases/terraform/latest | grep -oP '\"version\":\s*\"\\K[^\"]+' | head -1) && curl -fsSLo /tmp/terraform.zip \"https://releases.hashicorp.com/terraform/\${TF_VER}/terraform_\${TF_VER}_linux_amd64.zip\" && sudo unzip -o -d /usr/local/bin /tmp/terraform.zip"
      else
        echo "wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp.gpg && echo \"deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com \$(lsb_release -cs) main\" | sudo tee /etc/apt/sources.list.d/hashicorp.list && sudo apt update && sudo apt install -y terraform"
      fi ;;
    aws)
      # Distro-independent: the bundled installer is the supported path.
      echo "curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscli.zip && unzip -q -o /tmp/awscli.zip -d /tmp && sudo /tmp/aws/install --update" ;;
    kubectl)
      echo "curl -fsSLO \"https://dl.k8s.io/release/\$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl\" && sudo install -m 0755 kubectl /usr/local/bin/kubectl && rm kubectl" ;;
    helm)
      echo "curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash" ;;
    minikube)
      if [ "$FAMILY" = fedora ]; then
        echo "sudo dnf install -y https://storage.googleapis.com/minikube/releases/latest/minikube-latest.x86_64.rpm"
      else
        echo "curl -fsSLo /tmp/minikube https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64 && sudo install /tmp/minikube /usr/local/bin/minikube"
      fi ;;
    gh)
      [ "$FAMILY" = fedora ] && echo "sudo dnf install -y gh" \
                             || echo "sudo apt install -y gh   # or https://cli.github.com" ;;
    jq)
      [ "$FAMILY" = fedora ] && echo "sudo dnf install -y jq" \
                             || echo "sudo apt install -y jq" ;;
    trivy)
      echo "curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sudo sh -s -- -b /usr/local/bin" ;;
    *) echo "see the project README" ;;
  esac
}

# Not every tool understands `--version`; kubectl and helm need their own flags.
version_of() {
  case "$1" in
    kubectl) kubectl version --client 2>/dev/null | head -n1 ;;
    minikube) minikube version --short 2>/dev/null ;;
    helm)    helm version --short 2>/dev/null ;;
    aws)     aws --version 2>&1 ;;
    *)       "$1" --version 2>&1 | head -n1 ;;
  esac
}

check() {
  local cmd="$1" purpose="$2" required="${3:-yes}"
  if command -v "$cmd" >/dev/null 2>&1; then
    printf '  %s✓%s %-12s %s\n' "$GREEN" "$RESET" "$cmd" \
      "$(version_of "$cmd" | head -n1 | cut -c1-48)"
  else
    printf '  %s✗%s %-12s missing — %s\n' "$RED" "$RESET" "$cmd" "$purpose"
    printf '      %s%s%s\n' "$YELLOW" "$(recipe "$cmd")" "$RESET"
    [ "$required" = yes ] && missing=$((missing + 1))
  fi
}

printf '%s==> Required (API + tests)%s\n' "$CYAN" "$RESET"
check python3 "run the API and the test-suite"
check docker  "build and run containers"
check git     "version control"

printf '\n%s==> Required (infrastructure)%s\n' "$CYAN" "$RESET"
check terraform "provision DynamoDB/S3/IAM"
check aws       "talk to LocalStack and AWS"

printf '\n%s==> Required (Kubernetes)%s\n' "$CYAN" "$RESET"
check kubectl  "talk to the cluster"
check helm     "deploy the chart"
check minikube "local cluster"

printf '\n%s==> Optional%s\n' "$CYAN" "$RESET"
check gh    "create the GitHub repository" no
check jq    "pretty-print JSON"            no
check trivy "scan images locally"          no

# --- Runtime sanity checks -------------------------------------------------
echo
if command -v docker >/dev/null 2>&1 && ! docker info >/dev/null 2>&1; then
  printf '%s!%s docker is installed but the daemon is not reachable.\n' "$YELLOW" "$RESET"
  if [ "$IS_WSL" -eq 1 ]; then
    cat <<'HINT'
    On WSL you have two options:
      a) Docker Desktop for Windows -> Settings -> Resources -> WSL integration
         (enable it for this distro), or
      b) run the daemon inside the distro, which needs systemd:
           printf '[boot]\nsystemd=true\n' | sudo tee -a /etc/wsl.conf
           # then, from PowerShell:  wsl --shutdown   and reopen the terminal
           sudo systemctl enable --now docker
    Either way, add yourself to the group:  sudo usermod -aG docker $USER
    and open a new shell (or run: newgrp docker).
HINT
  else
    echo "    sudo systemctl enable --now docker && newgrp docker"
  fi
fi

if [ "$IS_WSL" -eq 1 ]; then
  printf '%s!%s WSL notes:\n' "$YELLOW" "$RESET"
  echo "    - minikube needs the docker driver:  minikube start --driver=docker"
  echo "    - give WSL enough memory for the cluster (~4 GB) in %USERPROFILE%\\.wslconfig"
  echo "    - ports published on localhost are reachable from Windows automatically"
fi

echo
if [ "$missing" -eq 0 ]; then
  printf '%sAll required tools present — you can run: make up%s\n' "$GREEN" "$RESET"
else
  printf '%s%d required tool(s) missing.%s Install them and re-run this script.\n' \
    "$RED" "$missing" "$RESET"
  exit 1
fi
