# Despliegue de un Clúster Kubernetes con kubeadm

> **Laboratorio:** Rocky Linux 9.7 + VirtualBox + Vagrant (solo creación de VMs) + kubeadm + containerd + Flannel
>
> **Administración:** se realiza desde el servidor bastión `dns-dhcp01.lab.local`.

## 1. Objetivo

Implementar un clúster Kubernetes de un control plane y un worker con `kubeadm`. El bastión existente entrega DHCP y DNS; los nuevos nodos se preparan manualmente. Finalmente se despliega Nginx, se publica mediante `NodePort` y se prueba el DNS interno de Kubernetes.

## 2. Topología adoptada

| Equipo | Hostname | Rol | Red privada | MAC privada propuesta |
|---|---|---|---:|---|
| Bastión existente | `dns-dhcp01.lab.local` | DHCP, DNS, administración con kubectl | `192.168.56.10/24` | Existente |
| Control plane | `k8s-master.lab.local` | Kubernetes API, etcd, scheduler y controller manager | `192.168.56.110/24` | `08:00:27:56:00:10` |
| Worker | `k8s-worker.lab.local` | Ejecución de cargas de trabajo | `192.168.56.120/24` | `08:00:27:56:00:20` |

Valores de red:

| Concepto | Valor |
|---|---|
| Dominio DNS | `lab.local` |
| DNS y DHCP | `192.168.56.10` |
| Red privada | `192.168.56.0/24` |
| Rango DHCP existente | `192.168.56.100` a `192.168.56.200` |
| Gateway DHCP anunciado | `192.168.56.1` |
| Red de Pods (Flannel) | `10.244.0.0/16` |
| Red de Services | `10.96.0.0/12` |
| API Server | `192.168.56.110:6443` |
| NodePort de Nginx | `30080/TCP` |

Cada VM tiene cuatro interfaces: NAT para Internet, Bridge para SSH desde la red física, Host-Only para administración desde el host y Host-Only/privada `192.168.56.0/24` para la comunicación del clúster. En este laboratorio la red privada reutiliza el segmento donde ya funciona el bastión.

## 3. Prerrequisitos

- VirtualBox y Vagrant instalados en el equipo anfitrión.
- Una box compatible de Rocky Linux 9.7 disponible para Vagrant. Antes de levantar el laboratorio, verificarla con `vagrant box list`.
- El bastión existente encendido, con IP `192.168.56.10`.
- Acceso administrativo mediante `sudo` en las tres VMs.
- Conectividad desde los nodos nuevos hacia Internet durante la instalación.

No se deben subir al repositorio `admin.conf`, certificados, tokens de `kubeadm`, contraseñas, llaves privadas ni configuraciones reales con información sensible.

## 4. Crear las VMs

1. Guardar el contenido del archivo `Vagrantfile` de este paquete en la raíz del proyecto.
2. Si tu adaptador físico no coincide con el configurado, reemplazar `BRIDGE_ADAPTER` por el nombre mostrado por `VBoxManage list bridgedifs`.
3. Ejecutar:

```bash
vagrant up k8s-master
vagrant up k8s-worker
vagrant status
```

4. Verificar las MAC de la NIC privada y las interfaces detectadas:

```bash
vagrant ssh k8s-master -c 'ip -br link; ip -br addr'
vagrant ssh k8s-worker -c 'ip -br link; ip -br addr'
```

La interfaz privada suele ser `enp0s10` cuando se crean cuatro adaptadores, pero nunca debe suponerse: usar el resultado anterior. Los scripts solicitan o permiten definir la interfaz correcta.

## 5. DHCP y DNS en el bastión

En `dns-dhcp01`, agregar las reservas dentro de `/etc/dhcp/dhcpd.conf`, fuera o dentro del bloque de subnet según el estilo de la configuración existente:

```conf
host k8s-master {
  hardware ethernet 08:00:27:56:00:10;
  fixed-address 192.168.56.110;
}

host k8s-worker {
  hardware ethernet 08:00:27:56:00:20;
  fixed-address 192.168.56.120;
}
```

Validar antes de reiniciar:

```bash
sudo dhcpd -t -cf /etc/dhcp/dhcpd.conf
sudo systemctl restart dhcpd
sudo systemctl status dhcpd --no-pager
```

Incluir los registros A de los dos nodos en la zona directa de BIND que ya administra `lab.local`. La ruta exacta depende de la configuración de tu bastión. Ejemplo de registros que debe tener la zona:

```dns
k8s-master IN A 192.168.56.110
k8s-worker IN A 192.168.56.120
```

Luego validar y recargar BIND:

```bash
sudo named-checkconf
sudo rndc reload
getent hosts k8s-master.lab.local
getent hosts k8s-worker.lab.local
```

Después de iniciar cada VM o modificar reservas, renovar su arrendamiento DHCP con la interfaz privada real:

```bash
sudo dhclient -r <INTERFAZ_PRIVADA>
sudo dhclient -v <INTERFAZ_PRIVADA>
ip -br addr show <INTERFAZ_PRIVADA>
```

Comprobar desde master y worker:

```bash
getent hosts dns-dhcp01.lab.local
getent hosts k8s-master.lab.local
getent hosts k8s-worker.lab.local
ping -c 2 192.168.56.10
```

## 6. Preparar master y worker

Copiar los scripts a ambos nodos o ejecutarlos desde la carpeta compartida de Vagrant. Primero crear las variables locales:

```bash
cp scripts/00-variables-cluster.sh.example scripts/00-variables-cluster.sh
chmod 700 scripts/00-variables-cluster.sh
```

Revisar `scripts/00-variables-cluster.sh` y asignar la interfaz privada real. El archivo está en `.gitignore` para no subir cambios locales.

En el master:

```bash
sudo bash scripts/01-preparar-nodo.sh k8s-master
sudo bash scripts/02-configurar-containerd.sh
sudo bash scripts/03-instalar-kubernetes.sh
sudo bash scripts/04-configurar-firewall.sh control-plane
```

En el worker:

```bash
sudo bash scripts/01-preparar-nodo.sh k8s-worker
sudo bash scripts/02-configurar-containerd.sh
sudo bash scripts/03-instalar-kubernetes.sh
sudo bash scripts/04-configurar-firewall.sh worker
```

El primer script desactiva swap en la sesión y en `/etc/fstab`, deja SELinux en modo permisivo, persiste los módulos `overlay` y `br_netfilter`, y aplica los parámetros `sysctl`. El segundo configura containerd con el driver de cgroups `systemd`. El tercero usa el repositorio actual `pkgs.k8s.io`; si la versión cambia en el futuro, editar una sola variable `K8S_MINOR` en el script. El cuarto configura los puertos necesarios.

Validar en ambos nodos:

```bash
swapon --show
getenforce
lsmod | egrep 'overlay|br_netfilter'
sysctl net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables
containerd config dump | grep SystemdCgroup
systemctl is-active containerd
systemctl is-active kubelet
```

Resultados esperados: `swapon --show` sin salida, SELinux `Permissive`, módulos presentes, reenvío IPv4 en `1`, `SystemdCgroup = true`, containerd activo y kubelet activo o reiniciándose a la espera de que kubeadm escriba su configuración.

## 7. Inicializar el control plane

Copiar `manifests/kubeadm-init.yaml` al master. En el master ejecutar:

```bash
sudo kubeadm config images pull --config manifests/kubeadm-init.yaml
sudo kubeadm init --config manifests/kubeadm-init.yaml --upload-certs
```

Guardar el comando `kubeadm join` que aparece al final. No lo pegues en el README ni lo subas al repositorio: incluye un token temporal.

Configurar kubectl temporalmente en el master solo para instalar el CNI:

```bash
mkdir -p "$HOME/.kube"
sudo cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
export KUBECONFIG="$HOME/.kube/config"
kubectl get nodes
```

Instalar Flannel. Se usa el manifiesto oficial compatible con el CIDR `10.244.0.0/16`:

```bash
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
kubectl get pods -n kube-flannel --watch
```

Es normal que el master todavía aparezca `NotReady` hasta que Flannel y CoreDNS estén operativos.

## 8. Unir el worker

En el worker, ejecutar el comando generado por el master. Su estructura es:

```bash
sudo kubeadm join 192.168.56.110:6443 \
  --token <TOKEN_TEMPORAL> \
  --discovery-token-ca-cert-hash sha256:<HASH>
```

Si perdiste el comando, crear uno nuevo en el master:

```bash
sudo kubeadm token create --print-join-command
```

Desde el master comprobar que el worker se registró:

```bash
kubectl get nodes -o wide
kubectl get pods -A -o wide
```

Esperado: `k8s-master` y `k8s-worker` en `Ready`; CoreDNS, Flannel y los componentes del sistema en ejecución.

## 9. Administrar desde el bastión

La administración final se debe realizar desde `dns-dhcp01`, no desde el master. Copiar `admin.conf` de forma segura mediante SSH; no se almacena en Git:

```bash
# Ejecutar en el bastión como el usuario administrador.
mkdir -p "$HOME/.kube"
scp <USUARIO_MASTER>@k8s-master.lab.local:/etc/kubernetes/admin.conf "$HOME/.kube/config"
chmod 600 "$HOME/.kube/config"
export KUBECONFIG="$HOME/.kube/config"
kubectl cluster-info
kubectl get nodes -o wide
kubectl get pods -A -o wide
```

Para persistir la variable para el usuario actual:

```bash
echo 'export KUBECONFIG=$HOME/.kube/config' >> "$HOME/.bashrc"
source "$HOME/.bashrc"
```

El archivo `admin.conf` concede privilegios administrativos. Debe tener permisos `600`, pertenecer al usuario administrador y no debe compartirse ni versionarse.

## 10. Desplegar y exponer Nginx

Desde el bastión:

```bash
kubectl apply -f manifests/nginx-deployment.yaml
kubectl apply -f manifests/nginx-nodeport.yaml
kubectl rollout status deployment/nginx-demo
kubectl get deployment,pods,service -o wide
```

El Deployment tiene un `nodeSelector` para programar Nginx en el worker. Verificar la columna `NODE`:

```bash
kubectl get pods -l app=nginx-demo -o wide
```

Consumir la aplicación desde el bastión:

```bash
curl -I http://192.168.56.120:30080
curl http://192.168.56.120:30080
```

La primera petición debe responder con `HTTP/1.1 200 OK`.

## 11. Probar CoreDNS

Desde el bastión:

```bash
kubectl apply -f manifests/dns-test-pod.yaml
kubectl wait --for=condition=Ready pod/dns-test --timeout=120s
kubectl exec -it dns-test -- nslookup kubernetes.default.svc.cluster.local
kubectl exec -it dns-test -- nslookup nginx-demo.default.svc.cluster.local
kubectl delete -f manifests/dns-test-pod.yaml
```

La resolución de `kubernetes.default.svc.cluster.local` prueba el DNS interno y debe devolver la IP de Service del API de Kubernetes. La segunda consulta valida la resolución del servicio Nginx.

## 12. Validación final

Desde el bastión ejecutar:

```bash
bash scripts/validar-cluster.sh
```

La entrega está lista si puedes demostrar:

- Ambos nodos están en estado `Ready`.
- Los Pods de `kube-system` y `kube-flannel` están ejecutándose.
- Nginx está programado en `k8s-worker`.
- El servicio NodePort `30080` responde desde el bastión hacia `192.168.56.120`.
- CoreDNS resuelve `kubernetes.default.svc.cluster.local` y el servicio de Nginx.

## 13. Evidencias para el documento

Tomar y comentar cada captura. Consulta `docs/02-evidencias-comentadas.md` para el orden, los comandos y el texto sugerido. Como mínimo incluye: adaptadores VirtualBox, reservas DHCP, registros DNS, ajustes de master y worker, `kubeadm init`, nodos Ready, Pods del sistema, Deployment en worker, Service NodePort, `curl` desde bastión y prueba CoreDNS.

## 14. Archivos del proyecto

```text
.
├── README.md
├── Vagrantfile
├── docs/
│   ├── 01-topologia-red.md
│   ├── 02-evidencias-comentadas.md
│   ├── 03-solucion-problemas.md
│   └── 04-guion-sustentacion.md
├── manifests/
│   ├── kubeadm-init.yaml
│   ├── nginx-deployment.yaml
│   ├── nginx-nodeport.yaml
│   └── dns-test-pod.yaml
└── scripts/
    ├── 00-variables-cluster.sh.example
    ├── 01-preparar-nodo.sh
    ├── 02-configurar-containerd.sh
    ├── 03-instalar-kubernetes.sh
    ├── 04-configurar-firewall.sh
    ├── 05-configurar-kubectl-bastion.sh
    └── validar-cluster.sh
```

## 15. Seguridad y limpieza

- Los tokens de unión caducan y pueden regenerarse; no deben publicarse.
- `admin.conf` equivale a una credencial administrativa de clúster.
- Al finalizar la práctica, eliminar el Pod de DNS y, si se requiere, Nginx:

```bash
kubectl delete -f manifests/dns-test-pod.yaml --ignore-not-found
kubectl delete -f manifests/nginx-nodeport.yaml --ignore-not-found
kubectl delete -f manifests/nginx-deployment.yaml --ignore-not-found
```

Para destruir solo las VMs creadas por Vagrant:

```bash
vagrant destroy -f k8s-worker
vagrant destroy -f k8s-master
```

