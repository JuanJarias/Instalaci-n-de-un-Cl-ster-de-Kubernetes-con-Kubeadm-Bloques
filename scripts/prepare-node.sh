#!/usr/bin/env bash
set -Eeuo pipefail

NODE_HOSTNAME="${1:?Uso: sudo bash prepare-node.sh <k8s-master|k8s-worker>}"

BASTION_IP="192.168.56.10"
MASTER_IP="192.168.56.110"
WORKER_IP="192.168.56.120"
DOMAIN="lab.local"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Ejecuta este script con sudo."
  exit 1
fi

if [[ "${NODE_HOSTNAME}" != "k8s-master" && "${NODE_HOSTNAME}" != "k8s-worker" ]]; then
  echo "Hostname inválido. Usa k8s-master o k8s-worker."
  exit 1
fi

echo "[1/7] Configurando hostname..."
hostnamectl set-hostname "${NODE_HOSTNAME}"

echo "[2/7] Configurando resolución local de nombres..."
cat >/etc/hosts <<EOF
127.0.0.1   localhost localhost.localdomain
${BASTION_IP} dns-dhcp01 dns-dhcp01.${DOMAIN}
${MASTER_IP} k8s-master k8s-master.${DOMAIN}
${WORKER_IP} k8s-worker k8s-worker.${DOMAIN}
EOF

echo "[3/7] Desactivando Swap de forma temporal y persistente..."
swapoff -a
sed -ri '/\sswap\s/s/^#?/#/' /etc/fstab

echo "[4/7] Configurando SELinux en modo permisivo..."
setenforce 0 || true
sed -ri 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config

echo "[5/7] Habilitando módulos de kernel requeridos..."
cat >/etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

echo "[6/7] Aplicando parámetros sysctl requeridos por Kubernetes..."
cat >/etc/sysctl.d/99-kubernetes-cri.conf <<EOF
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF

sysctl --system

echo "[7/7] Validando ajustes..."
echo
echo "Hostname:"
hostnamectl --static

echo
echo "Swap (debe no mostrar nada):"
swapon --show

echo
echo "SELinux (debe decir Permissive):"
getenforce

echo
echo "Módulos:"
lsmod | egrep 'overlay|br_netfilter'

echo
echo "Parámetros de red:"
sysctl net.ipv4.ip_forward
sysctl net.bridge.bridge-nf-call-iptables
sysctl net.bridge.bridge-nf-call-ip6tables

echo
echo "Preparación terminada correctamente."
echo "Reinicia el nodo antes de continuar: sudo reboot"
