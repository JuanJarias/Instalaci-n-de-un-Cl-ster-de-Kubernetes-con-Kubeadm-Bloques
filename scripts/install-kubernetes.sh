#!/usr/bin/env bash
set -Eeuo pipefail

K8S_MINOR="${K8S_MINOR:-v1.34}"
NODE_ROLE="${1:?Uso: sudo bash install-kubernetes.sh <master|worker>}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Ejecuta este script con sudo."
  exit 1
fi

if [[ "${NODE_ROLE}" != "master" && "${NODE_ROLE}" != "worker" ]]; then
  echo "Rol inválido. Usa master o worker."
  exit 1
fi

echo "[1/7] Actualizando paquetes del sistema..."
dnf update -y

echo "[2/7] Instalando containerd..."
dnf install -y dnf-plugins-core containerd

echo "[3/7] Generando configuración de containerd..."
mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml

echo "[4/7] Configurando SystemdCgroup = true..."
sed -ri 's/SystemdCgroup = false/SystemdCgroup = true/' \
  /etc/containerd/config.toml

systemctl daemon-reload
systemctl enable --now containerd

echo "[5/7] Configurando repositorio oficial de Kubernetes..."
cat >/etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF

echo "[6/7] Instalando kubelet, kubeadm y kubectl..."
dnf clean all
dnf makecache
dnf install -y kubelet kubeadm kubectl --disableexcludes=kubernetes

systemctl enable --now kubelet

echo "[7/7] Abriendo puertos en firewalld..."
systemctl enable --now firewalld

# Puertos requeridos en todos los nodos.
firewall-cmd --permanent --add-port=10250/tcp
firewall-cmd --permanent --add-port=30000-32767/tcp
firewall-cmd --permanent --add-port=30000-32767/udp
firewall-cmd --permanent --add-port=8472/udp

# Puertos exclusivos del control plane.
if [[ "${NODE_ROLE}" == "master" ]]; then
  firewall-cmd --permanent --add-port=6443/tcp
  firewall-cmd --permanent --add-port=2379-2380/tcp
  firewall-cmd --permanent --add-port=10257/tcp
  firewall-cmd --permanent --add-port=10259/tcp
fi

firewall-cmd --reload

echo
echo "Instalación finalizada en el nodo ${NODE_ROLE}."
echo
echo "Versiones instaladas:"
kubeadm version
kubectl version --client
rpm -q kubelet kubeadm kubectl

echo
echo "Containerd:"
systemctl is-active containerd
grep -n "SystemdCgroup" /etc/containerd/config.toml

echo
echo "Puertos permitidos:"
firewall-cmd --list-ports

echo
echo "Nota: kubelet puede reiniciarse hasta que se ejecute kubeadm init o kubeadm join."
