# Evidencias de la implementación

Este documento organiza las capturas de pantalla utilizadas como evidencia de la implementación del clúster Kubernetes con kubeadm sobre Rocky Linux 9.7.


## 1. Infraestructura virtual

 VirtualBox Manager mostrando `dns-dhcp01`, `k8s-master` y `k8s-worker`.

**Comentario:**  
En esta imagen se observa la infraestructura del laboratorio. El servidor bastión ya existía y actúa como servidor DHCP, DNS y punto central de administración. Se crearon dos VMs adicionales: `k8s-master`, que funciona como control plane, y `k8s-worker`, encargado de ejecutar las cargas de trabajo.

<!-- Insertar imagen aquí -->

## 2. Interfaces de red

 Configuración de red del master en VirtualBox.

**Comentario:**  
El nodo master cuenta con cuatro adaptadores de red: NAT para salida a Internet, Bridge para acceso SSH desde la red física, Host-Only para administración desde el host y una interfaz privada conectada a la red `192.168.56.0/24`, donde se comunica con el bastión y el worker.

<!-- Insertar imagen aquí -->

## 3. Configuración DHCP

 Salida de `sudo cat /etc/dhcp/dhcpd.conf` en el bastión.

**Comentario:**  
El servidor DHCP del bastión entrega el dominio `lab.local` y el DNS `192.168.56.10`. Además, se configuraron reservas basadas en MAC para que `k8s-master` obtenga la IP `192.168.56.110` y `k8s-worker` la IP `192.168.56.120`.

<!-- Insertar imagen aquí -->

## 4. Resolución DNS

 `getent hosts k8s-master.lab.local` y `getent hosts k8s-worker.lab.local`.

**Comentario:**  
La resolución de nombres confirma que el servicio BIND del bastión conoce los registros de ambos nodos Kubernetes y permite usar nombres en lugar de direcciones IP durante la administración.

<!-- Insertar imagen aquí -->

## 5. Preparación de nodos



```bash
hostnamectl --static
swapon --show
getenforce
lsmod | egrep 'overlay|br_netfilter'
sysctl net.ipv4.ip_forward
```

**Comentario:**  
Los prerrequisitos del sistema fueron aplicados en master y worker. Swap quedó desactivada, SELinux se configuró en modo permisivo, se habilitaron los módulos `overlay` y `br_netfilter`, y se activó el reenvío IPv4 requerido para la red de Kubernetes.

<!-- Insertar imagen aquí -->

## 6. Runtime de contenedores


```bash
systemctl is-active containerd
grep SystemdCgroup /etc/containerd/config.toml
```

**Comentario:**  
Containerd fue instalado como runtime de contenedores. La configuración `SystemdCgroup = true` permite que containerd use el mismo controlador de cgroups que kubelet.

<!-- Insertar imagen aquí -->

## 7. Inicialización del control plane

Final de `sudo kubeadm init`.

**Comentario:**  
El comando `kubeadm init` inicializó el control plane en `k8s-master` usando la dirección `192.168.56.110` y la red de Pods `10.244.0.0/16`. El token de unión generado fue ocultado porque es una credencial temporal.

<!-- Insertar imagen aquí -->

## 8. Red de Pods con Flannel


```bash
kubectl get pods -n kube-flannel -o wide
```

**Comentario:**  
Flannel fue instalado como plugin CNI. Sus Pods se ejecutan en los nodos del clúster y habilitan la comunicación entre las redes de Pods.

<!-- Insertar imagen aquí -->

## 9. Nodos Ready


```bash
kubectl get nodes -o wide
```

**Comentario:**  
La imagen valida que `k8s-master` y `k8s-worker` están en estado `Ready`. Este comando se ejecutó desde el servidor bastión, cumpliendo el requisito de administración remota.

<!-- Insertar imagen aquí -->

## 10. Pods del sistema



```bash
kubectl get pods -A -o wide
```

**Comentario:**  
Los componentes principales del clúster, como CoreDNS, kube-proxy y Flannel, se encuentran en ejecución. Esto confirma que el control plane y la red del clúster funcionan correctamente.

<!-- Insertar imagen aquí -->

## 11. Deployment en worker


```bash
kubectl get pods -l app=nginx-demo -o wide
```

**Comentario:**  
El Deployment de Nginx creó dos réplicas y, mediante `nodeSelector`, ambas se programaron en `k8s-worker`. La columna `NODE` permite evidenciar dónde se ejecutan los Pods.

<!-- Insertar imagen aquí -->

## 12. Servicio NodePort


```bash
kubectl get svc nginx-demo
```

**Comentario:**  
El servicio de tipo NodePort expone la aplicación Nginx en el puerto `30080`. Kubernetes redirige las solicitudes que llegan a ese puerto hacia los Pods seleccionados por la etiqueta `app=nginx-demo`.

<!-- Insertar imagen aquí -->

## 13. Prueba de acceso desde bastión


```bash
curl -I http://192.168.56.120:30080
```

**Comentario:**  
El bastión consumió la aplicación mediante la IP del worker y el NodePort asignado. La respuesta HTTP 200 demuestra que la publicación del servicio funciona desde fuera del clúster.

<!-- Insertar imagen aquí -->

## 14. Prueba CoreDNS


```bash
kubectl exec -it dns-test -- nslookup kubernetes.default.svc.cluster.local
kubectl exec -it dns-test -- nslookup nginx-demo.default.svc.cluster.local
```

**Comentario:**  
La prueba se ejecutó desde un Pod temporal. La respuesta de los nombres `kubernetes.default.svc.cluster.local` y `nginx-demo.default.svc.cluster.local` demuestra que CoreDNS resuelve los nombres internos del clúster.
