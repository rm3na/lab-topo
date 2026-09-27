#!/usr/bin/env bash
# =============================================================================
#  c845a-poc-setup.sh — Avatar/RAG POC platform on the Cisco UCS C845A (no BCM)
#
#  Target : Ubuntu 24.04 LTS installed on the C845A (RAID 5 root), static IP set
#           during install on X710 port 0 (enp175s0f0np0), 10.3.50.0/24 (VLAN 50).
#  Builds : host prep -> containerd -> Kubernetes (kubeadm, single node) ->
#           Calico -> MetalLB -> Traefik -> local-path storage -> monitoring ->
#           NVIDIA GPU Operator -> MinIO -> (Milvus) -> POC namespaces -> tests
#
#  Run    : sudo bash c845a-poc-setup.sh
#  Re-run : safe. Finished stages are skipped or upgraded in place. Turn stages
#           off/on with the RUN_* flags below.
#  Log    : /var/log/c845a-poc-setup.log
# =============================================================================

# ============================ SETTINGS — EDIT ME =============================
# --- Node identity / network (must match DNS on dns01) ---
NODE_HOSTNAME="c845a01"
DOMAIN="ik.lab"
NODE_IP="10.3.50.68"
DNS_NTP_SERVER="10.3.50.70"
K8S_API_NAME="k8s-api.ik.lab"            # A record -> NODE_IP

# --- Outbound proxy (leave empty for direct internet) ---
HTTP_PROXY_URL=""                         # e.g. http://proxy.ikusi.local:3128

# --- Kubernetes ---
K8S_MINOR="v1.36"                         # pkgs.k8s.io channel; GPU Operator 26.3.x supports 1.36
POD_CIDR="10.244.0.0/16"                  # must not overlap 10.3.50.0/24 or Calico's 192.168.0.0/16 default
SVC_CIDR="10.96.0.0/12"

# --- MetalLB pool and fixed service IPs (10.3.50.0/24) ---
METALLB_RANGE="10.3.50.71-10.3.50.84"
INGRESS_IP="10.3.50.71"               # Traefik  -> avatar / rag-api / grafana / *.apps
S3_IP="10.3.50.72"                    # MinIO S3 API

# --- NVIDIA ---
GPU_OPERATOR_VERSION="v26.3.2"            # empty = latest chart
GPU_DRIVER_VERSION=""                     # empty = operator default (RTX PRO 6000 needs >= 575.57.08)
ENABLE_TIME_SLICING=false                 # true = each GPU advertised as TS_REPLICAS shared GPUs
TS_REPLICAS=2
NGC_API_KEY=""                            # optional now; needed for NIM / Riva images from nvcr.io

# --- Object storage (MinIO community is archived upstream; last release pinned for POC) ---
MINIO_IMAGE="quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z"

# --- Stages ---
RUN_PREFLIGHT=true
RUN_HOST_PREP=true
RUN_CONTAINERD=true
RUN_KUBERNETES=true
RUN_CNI=true
RUN_METALLB=true
RUN_INGRESS=true
RUN_STORAGE=true
RUN_MONITORING=true
RUN_GPU_OPERATOR=true
RUN_MINIO=true
RUN_MILVUS=false                          # enable once Milvus vs Qdrant is decided
RUN_NAMESPACES=true
RUN_TESTS=true
# =============================================================================

set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)."; exit 1; }

LOG=/var/log/c845a-poc-setup.log
exec > >(tee -a "$LOG") 2>&1
CRED_FILE=/root/poc-credentials.txt
export KUBECONFIG=/etc/kubernetes/admin.conf
export DEBIAN_FRONTEND=noninteractive

log()  { echo -e "\n\033[1;32m==> $*\033[0m"; }
warn() { echo -e "\033[1;33m[WARN] $*\033[0m"; }
die()  { echo -e "\033[1;31m[FAIL] $*\033[0m"; exit 1; }
gh_latest() { curl -fsSL "https://api.github.com/repos/$1/releases/latest" | jq -r .tag_name; }
save_cred() { touch "$CRED_FILE"; chmod 600 "$CRED_FILE"; grep -q "^$1=" "$CRED_FILE" || echo "$1=$2" >> "$CRED_FILE"; }
get_cred()  { grep "^$1=" "$CRED_FILE" 2>/dev/null | cut -d= -f2-; }
wait_rollout() { kubectl -n "$1" rollout status "$2" --timeout="${3:-300s}"; }

# Proxy for this shell (apt, curl, helm)
if [[ -n "$HTTP_PROXY_URL" ]]; then
  NO_PROXY_LIST="localhost,127.0.0.1,${NODE_IP},${DOMAIN},.${DOMAIN},${POD_CIDR},${SVC_CIDR},10.3.50.0/24,.svc,.cluster.local"
  export http_proxy="$HTTP_PROXY_URL" https_proxy="$HTTP_PROXY_URL" no_proxy="$NO_PROXY_LIST"
  export HTTP_PROXY="$HTTP_PROXY_URL" HTTPS_PROXY="$HTTP_PROXY_URL" NO_PROXY="$NO_PROXY_LIST"
fi

# =============================================================================
# 0. PREFLIGHT
# =============================================================================
if [[ "$RUN_PREFLIGHT" == "true" ]]; then
  log "Preflight"
  . /etc/os-release
  [[ "$VERSION_ID" == "24.04" ]] || die "Ubuntu 24.04 expected, found $VERSION_ID"
  ip -4 addr | grep -q "inet ${NODE_IP}/" || die "NODE_IP ${NODE_IP} is not configured on this host"
  gpus=$(lspci -nn | grep -Eci '\[03(00|02)\].*nvidia' || true)
  echo "NVIDIA GPUs on PCI bus: $gpus"; [[ "$gpus" -ge 1 ]] || die "No NVIDIA GPU visible"
  swapon --show | grep -q . && warn "Swap is on — it will be disabled"
  echo "RAID status:"; cat /proc/mdstat || true
  for u in https://pkgs.k8s.io https://registry.k8s.io https://nvcr.io https://helm.ngc.nvidia.com \
           https://github.com https://quay.io https://ghcr.io https://archive.ubuntu.com; do
    if curl -s -o /dev/null --max-time 10 "$u"; then echo "  egress OK   $u"; else warn "egress FAIL $u"; fi
  done
  curl -s -o /dev/null --max-time 10 https://pkgs.k8s.io || die "No internet egress — set HTTP_PROXY_URL or open the firewall"
fi

# =============================================================================
# 1. HOST PREP
# =============================================================================
if [[ "$RUN_HOST_PREP" == "true" ]]; then
  log "Host prep: hostname, DNS/NTP, swap, kernel modules, sysctl, packages"
  hostnamectl set-hostname "${NODE_HOSTNAME}.${DOMAIN}"
  grep -q "${K8S_API_NAME}" /etc/hosts || \
    echo "${NODE_IP} ${NODE_HOSTNAME}.${DOMAIN} ${NODE_HOSTNAME} ${K8S_API_NAME}" >> /etc/hosts

  if [[ -n "$HTTP_PROXY_URL" ]]; then
    printf 'Acquire::http::Proxy "%s";\nAcquire::https::Proxy "%s";\n' "$HTTP_PROXY_URL" "$HTTP_PROXY_URL" \
      > /etc/apt/apt.conf.d/95proxy
  fi

  apt-get update -y
  apt-get install -y curl gpg jq ca-certificates apt-transport-https chrony nfs-common \
                     socat conntrack ipset ebtables pciutils mdadm linux-headers-"$(uname -r)"

  # DNS + NTP -> dns01
  mkdir -p /etc/systemd/resolved.conf.d
  printf '[Resolve]\nDNS=%s\nDomains=%s\n' "$DNS_NTP_SERVER" "$DOMAIN" > /etc/systemd/resolved.conf.d/poc.conf
  systemctl restart systemd-resolved
  printf 'server %s iburst prefer\npool ntp.ubuntu.com iburst\ndriftfile /var/lib/chrony/chrony.drift\nmakestep 1.0 3\nrtcsync\n' \
    "$DNS_NTP_SERVER" > /etc/chrony/chrony.conf
  systemctl restart chrony

  # Swap off
  swapoff -a
  sed -ri '/\sswap\s/s/^#?/#/' /etc/fstab

  # Kernel modules + sysctl for Kubernetes
  printf 'overlay\nbr_netfilter\n' > /etc/modules-load.d/k8s.conf
  modprobe overlay; modprobe br_netfilter
  cat > /etc/sysctl.d/99-k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
fs.inotify.max_user_instances       = 8192
fs.inotify.max_user_watches         = 1048576
vm.max_map_count                    = 262144
EOF
  sysctl --system >/dev/null

  # nouveau must not be loaded for the NVIDIA driver container
  if [[ ! -f /etc/modprobe.d/blacklist-nouveau.conf ]]; then
    printf 'blacklist nouveau\noptions nouveau modeset=0\n' > /etc/modprobe.d/blacklist-nouveau.conf
    update-initramfs -u
  fi
  if lsmod | grep -q '^nouveau'; then
    warn "nouveau is loaded. REBOOT now, then re-run this script (finished stages are skipped)."
    exit 0
  fi
fi

# =============================================================================
# 2. CONTAINERD (2.x from Docker's repo — Kubernetes 1.36 needs containerd 2)
# =============================================================================
if [[ "$RUN_CONTAINERD" == "true" ]]; then
  log "containerd"
  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  fi
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y containerd.io

  mkdir -p /etc/containerd
  if [[ ! -f /etc/containerd/.poc-configured ]]; then
    containerd config default > /etc/containerd/config.toml
    if grep -q 'SystemdCgroup' /etc/containerd/config.toml; then
      sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
    else
      sed -i "/runtimes.runc.options\]/a\            SystemdCgroup = true" /etc/containerd/config.toml
    fi
    touch /etc/containerd/.poc-configured
  fi
  if [[ -n "$HTTP_PROXY_URL" ]]; then
    mkdir -p /etc/systemd/system/containerd.service.d
    printf '[Service]\nEnvironment="HTTP_PROXY=%s" "HTTPS_PROXY=%s" "NO_PROXY=%s"\n' \
      "$HTTP_PROXY_URL" "$HTTP_PROXY_URL" "$NO_PROXY_LIST" > /etc/systemd/system/containerd.service.d/proxy.conf
  fi
  systemctl daemon-reload
  systemctl enable --now containerd
  systemctl restart containerd
  grep -q 'SystemdCgroup = true' /etc/containerd/config.toml || warn "SystemdCgroup not set — check /etc/containerd/config.toml"
fi

# =============================================================================
# 3. KUBERNETES (kubeadm, single node)
# =============================================================================
if [[ "$RUN_KUBERNETES" == "true" ]]; then
  log "Kubernetes ${K8S_MINOR}"
  if [[ ! -f /etc/apt/keyrings/kubernetes.gpg ]]; then
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" | gpg --dearmor -o /etc/apt/keyrings/kubernetes.gpg
  fi
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" \
    > /etc/apt/sources.list.d/kubernetes.list
  apt-get update -y
  apt-get install -y kubelet kubeadm kubectl
  apt-mark hold kubelet kubeadm kubectl
  systemctl enable kubelet

  if [[ ! -f /etc/kubernetes/admin.conf ]]; then
    cat > /root/kubeadm-config.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${NODE_IP}
nodeRegistration:
  name: ${NODE_HOSTNAME}
  criSocket: unix:///run/containerd/containerd.sock
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
clusterName: avatar-rag-poc
controlPlaneEndpoint: ${K8S_API_NAME}:6443
apiServer:
  certSANs: ["${K8S_API_NAME}", "${NODE_IP}", "${NODE_HOSTNAME}", "${NODE_HOSTNAME}.${DOMAIN}"]
networking:
  podSubnet: ${POD_CIDR}
  serviceSubnet: ${SVC_CIDR}
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
maxPods: 250
EOF
    kubeadm init --config /root/kubeadm-config.yaml --upload-certs
  else
    echo "Cluster already initialised — skipping kubeadm init"
  fi

  mkdir -p /root/.kube && cp -f /etc/kubernetes/admin.conf /root/.kube/config
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    uhome=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    mkdir -p "$uhome/.kube" && cp -f /etc/kubernetes/admin.conf "$uhome/.kube/config"
    chown -R "$SUDO_USER:" "$uhome/.kube"
  fi
  # Single node: allow workloads on the control plane
  kubectl taint nodes "${NODE_HOSTNAME}" node-role.kubernetes.io/control-plane:NoSchedule- 2>/dev/null || true

  # Helm
  command -v helm >/dev/null || curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# =============================================================================
# 4. CNI — Calico (tigera-operator)
# =============================================================================
if [[ "$RUN_CNI" == "true" ]]; then
  log "Calico CNI"
  CALICO_VER=$(gh_latest projectcalico/calico)
  echo "Calico ${CALICO_VER}"
  kubectl create -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VER}/manifests/tigera-operator.yaml" 2>/dev/null \
    || kubectl apply --server-side -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VER}/manifests/tigera-operator.yaml"
  kubectl -n tigera-operator rollout status deploy/tigera-operator --timeout=300s
  cat <<EOF | kubectl apply -f -
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
    - name: default-ipv4-ippool
      cidr: ${POD_CIDR}
      blockSize: 26
      encapsulation: VXLANCrossSubnet
      natOutgoing: Enabled
      nodeSelector: all()
---
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
EOF
  echo "Waiting for Calico..."
  for _ in $(seq 1 60); do
    kubectl get tigerastatus calico >/dev/null 2>&1 && break; sleep 5
  done
  kubectl wait --for=condition=Available tigerastatus/calico --timeout=600s
  kubectl wait --for=condition=Ready node/"${NODE_HOSTNAME}" --timeout=300s
fi

# =============================================================================
# 5. METALLB (L2 mode on 10.3.50.0/24)
# =============================================================================
if [[ "$RUN_METALLB" == "true" ]]; then
  log "MetalLB (${METALLB_RANGE})"
  helm repo add metallb https://metallb.github.io/metallb >/dev/null 2>&1 || true
  helm repo update metallb >/dev/null
  helm upgrade --install metallb metallb/metallb -n metallb-system --create-namespace --wait --timeout 10m
  cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: poc-pool
  namespace: metallb-system
spec:
  addresses: ["${METALLB_RANGE}"]
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: poc-l2
  namespace: metallb-system
spec:
  ipAddressPools: ["poc-pool"]
EOF
fi

# =============================================================================
# 6. INGRESS — Traefik (ingress-nginx is retired upstream)
# =============================================================================
if [[ "$RUN_INGRESS" == "true" ]]; then
  log "Traefik ingress on ${INGRESS_IP}"
  helm repo add traefik https://traefik.github.io/charts >/dev/null 2>&1 || true
  helm repo update traefik >/dev/null
  helm upgrade --install traefik traefik/traefik -n traefik --create-namespace --wait --timeout 10m \
    --set service.type=LoadBalancer \
    --set "service.annotations.metallb\.io/loadBalancerIPs=${INGRESS_IP}" \
    --set ingressClass.enabled=true \
    --set ingressClass.isDefaultClass=true \
    --set providers.kubernetesIngress.enabled=true
fi

# =============================================================================
# 7. STORAGE — local-path on the RAID 5 root
# =============================================================================
if [[ "$RUN_STORAGE" == "true" ]]; then
  log "local-path storage class (default)"
  LPP_VER=$(gh_latest rancher/local-path-provisioner)
  kubectl apply -f "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LPP_VER}/deploy/local-path-storage.yaml"
  kubectl patch storageclass local-path \
    -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
  wait_rollout local-path-storage deploy/local-path-provisioner
fi

# =============================================================================
# 8. MONITORING — kube-prometheus-stack (before GPU Operator, for ServiceMonitor CRDs)
# =============================================================================
if [[ "$RUN_MONITORING" == "true" ]]; then
  log "Prometheus + Grafana (grafana.${DOMAIN})"
  save_cred GRAFANA_ADMIN_PASSWORD "$(openssl rand -base64 18)"
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo update prometheus-community >/dev/null
  helm upgrade --install kps prometheus-community/kube-prometheus-stack -n monitoring --create-namespace \
    --wait --timeout 15m \
    --set grafana.adminPassword="$(get_cred GRAFANA_ADMIN_PASSWORD)" \
    --set grafana.ingress.enabled=true \
    --set grafana.ingress.ingressClassName=traefik \
    --set "grafana.ingress.hosts[0]=grafana.${DOMAIN}" \
    --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
    --set prometheus.prometheusSpec.retention=15d \
    --set "prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=100Gi"
fi

# =============================================================================
# 9. NVIDIA GPU OPERATOR
# =============================================================================
if [[ "$RUN_GPU_OPERATOR" == "true" ]]; then
  log "NVIDIA GPU Operator ${GPU_OPERATOR_VERSION:-latest}"
  helm repo add nvidia https://helm.ngc.nvidia.com/nvidia >/dev/null 2>&1 || true
  helm repo update nvidia >/dev/null
  kubectl create namespace gpu-operator --dry-run=client -o yaml | kubectl apply -f -
  kubectl label --overwrite ns gpu-operator pod-security.kubernetes.io/enforce=privileged

  GPU_ARGS=()
  [[ -n "$GPU_OPERATOR_VERSION" ]] && GPU_ARGS+=(--version "$GPU_OPERATOR_VERSION")
  # Host driver already present? then don't let the operator install one
  if command -v nvidia-smi >/dev/null && nvidia-smi >/dev/null 2>&1; then
    warn "Host NVIDIA driver detected — operator driver disabled"
    GPU_ARGS+=(--set driver.enabled=false)
  elif [[ -n "$GPU_DRIVER_VERSION" ]]; then
    GPU_ARGS+=(--set driver.version="$GPU_DRIVER_VERSION")
  fi
  [[ "$RUN_MONITORING" == "true" ]] && GPU_ARGS+=(--set dcgmExporter.serviceMonitor.enabled=true)

  if [[ "$ENABLE_TIME_SLICING" == "true" ]]; then
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: time-slicing-config
  namespace: gpu-operator
data:
  any: |-
    version: v1
    flags:
      migStrategy: none
    sharing:
      timeSlicing:
        resources:
        - name: nvidia.com/gpu
          replicas: ${TS_REPLICAS}
EOF
    GPU_ARGS+=(--set devicePlugin.config.name=time-slicing-config --set devicePlugin.config.default=any)
  fi

  helm upgrade --install gpu-operator nvidia/gpu-operator -n gpu-operator "${GPU_ARGS[@]}" --timeout 20m

  echo "Waiting for GPUs to be advertised (driver build can take 10-15 min)..."
  for i in $(seq 1 120); do
    n=$(kubectl get node "${NODE_HOSTNAME}" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null || true)
    [[ -n "$n" && "$n" != "0" ]] && { echo "nvidia.com/gpu allocatable: $n"; break; }
    (( i % 6 == 0 )) && kubectl -n gpu-operator get pods --no-headers | awk '{print "  " $1, $3}'
    sleep 15
  done
  [[ -n "${n:-}" && "${n:-0}" != "0" ]] || die "GPUs not advertised — check: kubectl -n gpu-operator get pods; logs of nvidia-driver-daemonset"
fi

# =============================================================================
# 10. MINIO (S3 on ${S3_IP}, console at minio-console.${DOMAIN})
# =============================================================================
if [[ "$RUN_MINIO" == "true" ]]; then
  log "MinIO (S3 ${S3_IP})"
  save_cred MINIO_ROOT_USER "pocadmin"
  save_cred MINIO_ROOT_PASSWORD "$(openssl rand -hex 16)"
  kubectl create namespace data --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n data create secret generic minio-root \
    --from-literal=MINIO_ROOT_USER="$(get_cred MINIO_ROOT_USER)" \
    --from-literal=MINIO_ROOT_PASSWORD="$(get_cred MINIO_ROOT_PASSWORD)" \
    --dry-run=client -o yaml | kubectl apply -f -
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: minio-data, namespace: data}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources: {requests: {storage: 2Ti}}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: minio, namespace: data}
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector: {matchLabels: {app: minio}}
  template:
    metadata: {labels: {app: minio}}
    spec:
      containers:
      - name: minio
        image: ${MINIO_IMAGE}
        args: ["server", "/data", "--console-address", ":9001"]
        envFrom: [{secretRef: {name: minio-root}}]
        ports: [{containerPort: 9000, name: s3}, {containerPort: 9001, name: console}]
        readinessProbe: {httpGet: {path: /minio/health/ready, port: 9000}, periodSeconds: 10}
        resources: {requests: {cpu: "2", memory: 8Gi}, limits: {cpu: "4", memory: 16Gi}}
        volumeMounts: [{name: data, mountPath: /data}]
      volumes: [{name: data, persistentVolumeClaim: {claimName: minio-data}}]
---
apiVersion: v1
kind: Service
metadata:
  name: minio
  namespace: data
  annotations: {metallb.io/loadBalancerIPs: "${S3_IP}"}
spec:
  type: LoadBalancer
  selector: {app: minio}
  ports: [{name: s3, port: 9000, targetPort: 9000}, {name: console, port: 9001, targetPort: 9001}]
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata: {name: minio-console, namespace: data}
spec:
  ingressClassName: traefik
  rules:
  - host: minio-console.${DOMAIN}
    http:
      paths: [{path: /, pathType: Prefix, backend: {service: {name: minio, port: {number: 9001}}}}]
EOF
  wait_rollout data deploy/minio 600s
fi

# =============================================================================
# 11. MILVUS (optional — standalone, using the MinIO above)
# =============================================================================
if [[ "$RUN_MILVUS" == "true" ]]; then
  log "Milvus standalone"
  helm repo add milvus https://zilliztech.github.io/milvus-helm/ >/dev/null 2>&1 || true
  helm repo update milvus >/dev/null
  helm upgrade --install milvus milvus/milvus -n data --wait --timeout 15m \
    --set cluster.enabled=false \
    --set etcd.replicaCount=1 \
    --set pulsarv3.enabled=false \
    --set minio.enabled=false \
    --set externalS3.enabled=true \
    --set externalS3.host=minio.data.svc.cluster.local \
    --set externalS3.port=9000 \
    --set externalS3.accessKey="$(get_cred MINIO_ROOT_USER)" \
    --set externalS3.secretKey="$(get_cred MINIO_ROOT_PASSWORD)" \
    --set externalS3.bucketName=milvus \
    --set externalS3.useSSL=false
fi

# =============================================================================
# 12. POC NAMESPACES (+ NGC pull secret if key provided)
# =============================================================================
if [[ "$RUN_NAMESPACES" == "true" ]]; then
  log "POC namespaces uc1-rag / uc2-avatar"
  for ns in uc1-rag uc2-avatar; do
    kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
    if [[ -n "$NGC_API_KEY" ]]; then
      kubectl -n "$ns" create secret docker-registry ngc-secret \
        --docker-server=nvcr.io --docker-username='$oauthtoken' --docker-password="$NGC_API_KEY" \
        --dry-run=client -o yaml | kubectl apply -f -
      kubectl -n "$ns" create secret generic ngc-api --from-literal=NGC_API_KEY="$NGC_API_KEY" \
        --dry-run=client -o yaml | kubectl apply -f -
    fi
  done
  [[ -n "$NGC_API_KEY" ]] || warn "NGC_API_KEY empty — add it later and re-run with only RUN_NAMESPACES=true"
fi

# =============================================================================
# 13. TESTS
# =============================================================================
if [[ "$RUN_TESTS" == "true" ]]; then
  log "Validation"
  kubectl get nodes -o wide
  echo; kubectl get svc -A --field-selector spec.type=LoadBalancer
  gpu_count=$(kubectl get node "${NODE_HOSTNAME}" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null || echo 0)
  if [[ "${gpu_count:-0}" != "0" ]]; then
    want=2; [[ "$ENABLE_TIME_SLICING" == "true" ]] && want=1
    kubectl delete pod gpu-smoke -n default --ignore-not-found >/dev/null
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata: {name: gpu-smoke, namespace: default}
spec:
  restartPolicy: Never
  containers:
  - name: smi
    image: ubuntu:24.04
    command: ["nvidia-smi"]
    env: [{name: NVIDIA_DRIVER_CAPABILITIES, value: "compute,utility"}]
    resources: {limits: {nvidia.com/gpu: ${want}}}
EOF
    kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/gpu-smoke --timeout=300s \
      && kubectl logs gpu-smoke || warn "GPU smoke pod did not succeed — kubectl describe pod gpu-smoke"
  fi
  echo; echo "HTTP via ingress (expect 404 from Traefik = working):"
  curl -s -o /dev/null -w "  http://${INGRESS_IP}/ -> %{http_code}\n" "http://${INGRESS_IP}/" || true
  curl -s -o /dev/null -w "  http://${S3_IP}:9000/minio/health/live -> %{http_code}\n" "http://${S3_IP}:9000/minio/health/live" || true
fi

log "Done"
cat <<EOF
  Kubeconfig : /root/.kube/config   (copy to jump01:  scp root@${NODE_IP}:/root/.kube/config ~/.kube/config)
  API        : https://${K8S_API_NAME}:6443
  Grafana    : http://grafana.${DOMAIN}         (admin / see ${CRED_FILE})
  MinIO S3   : http://s3.${DOMAIN}:9000  console http://minio-console.${DOMAIN}
  Credentials: ${CRED_FILE}   Log: ${LOG}
EOF
