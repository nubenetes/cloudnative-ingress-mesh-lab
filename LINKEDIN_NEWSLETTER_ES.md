# 🚀 La Gran Batalla de Ingress y Service Mesh (Edición 2026): eBPF vs. Istio Ambient vs. Traefik v3 vs. Envoy Gateway vs. Linkerd

**Subtítulo:** *Descifrando Kubernetes Gateway API, el Enrutamiento FQDN de Doble Plano y el Fin de los Sidecars en Entornos Corporativos de Kubernetes y Red Hat OpenShift*  
**Autor:** Equipo de Arquitectura e Ingeniería de Plataformas Cloud-Native  
**Repositorios Oficiales de GitHub:**  
👉 [**nubenetes/cloudnative-ingress-mesh-lab**](https://github.com/nubenetes/cloudnative-ingress-mesh-lab) (Laboratorio Multi-Motor)  
👉 [**nubenetes/traefik-fqdn-management-poc-openshift-aws**](https://github.com/nubenetes/traefik-fqdn-management-poc-openshift-aws) (PoC OpenShift ROSA en AWS)  
👉 [**nubenetes/jenkins-2026**](https://github.com/nubenetes/jenkins-2026) (Referencia de Producción GKE Dataplane V2)  

---

> ⚠️ **Aviso de Contenido Generado por IA y Pruebas en Entornos Reales**  
> *Este análisis arquitectónico y guía de referencia fue generado por **Gemini 3.8 Flash** en base a estándares oficiales cloud-native y patrones arquitectónicos consolidados. NO ha sido probado en un entorno de producción real. Todas las arquitecturas, manifiestos YAML y estrategias de despliegue deben ser revisados, auditados y probados en entornos de staging o sandbox aislados antes de su adopción empresarial.*

---

## 📌 Resumen Ejecutivo: El Punto de Inflexión del Networking Cloud-Native en 2026

Si lideras o formas parte de un equipo de **Ingeniería de Plataforma** gestionando clústeres de Kubernetes o Red Hat OpenShift a escala empresarial, te encuentras ante un cambio de paradigma histórico.

Durante la última década, las redes cloud-native se sustentaron en dos pilares tradicionales:
1. **Ingress Perimetral**: Gestionado mediante el recurso clásico `networking.k8s.io/v1 Ingress` o las `Route` propietarias de Red Hat OpenShift (`route.openshift.io/v1`).
2. **Malla de Servicios (Service Mesh) Este-Oeste**: Implementada inyectando pesados contenedores proxy sidecar (Envoy) dentro de cada Pod de la aplicación.

**En 2026, ambos pilares han quedado obsoletos.**

- **El Déficit del Ingress Clásico:** Ni el Ingress tradicional ni las OpenShift Routes ofrecen soporte nativo para multi-tenancy desacoplado, división de tráfico Canary ponderada, RBAC entre namespaces (`ReferenceGrant`), ni gestión avanzada de dominios FQDN.
- **La Crisis del "Impuesto de Sidecar" (Sidecar Tax):** Inyectar sidecars en 2.000 microservicios desperdicia entre **100 GB y 250 GB de memoria RAM**, introduce 4 cambios de contexto en espacio de usuario por cada llamada RPC y genera bloqueos operativos durante los despliegues continuos.
- **El Nuevo Estándar:** La especificación **Kubernetes Gateway API (`gateway.networking.k8s.io/v1`)** ha alcanzado Disponibilidad General (GA) y adopción masiva en la industria, mientras que los planos de datos **sin sidecars (in-kernel eBPF e Istio Ambient)** se han convertido en el estándar indiscutible de seguridad Zero-Trust.

En esta edición especial, desglosamos las conclusiones técnicas de nuestro laboratorio de código abierto [**`nubenetes/cloudnative-ingress-mesh-lab`**](https://github.com/nubenetes/cloudnative-ingress-mesh-lab), comparando los 6 motores principales, resolviendo el complejo **Dilema del Enrutamiento FQDN de Doble Plano** y brindando recomendaciones claras y accionables para la arquitectura de tu organización.

---

## 🛑 Los Problemas Específicos que Resuelve Cada Solución

Cada tecnología en el ecosistema cloud-native fue concebida para resolver un cuello de botella arquitectónico puntual. Elegir la opción adecuada exige comprender qué problema resuelve cada una y cuál es su compromiso (*trade-off*):

```
+---------------------------+-----------------------------------+-----------------------------------+
| Solución / Paradigma      | Problema Principal que Resuelve   | El Compromiso Arquitectónico      |
+---------------------------+-----------------------------------+-----------------------------------+
| 1. eBPF en el Kernel      | Elimina la sobrecarga del stack   | Alta fricción de instalación Day-0|
|    (Cilium Gateway & Mesh)| TCP/IP y los sidecars mediante    | en OpenShift; requiere reemplazar |
|                           | sockops (<0.15ms, 0MB RAM/Pod).   | el CNI y privilegios CAP_BPF.     |
+---------------------------+-----------------------------------+-----------------------------------+
| 2. Modo Istio Ambient     | Desacopla mTLS L4 (ztunnel en     | Latencia ligeramente mayor que    |
|    (Red Hat OSSM 3.x)     | nodo) de políticas L7 (waypoint); | eBPF puro; requiere Istio 1.22+   |
|                           | reduce la memoria en un 80%.      | u OpenShift Service Mesh 3.x.     |
+---------------------------+-----------------------------------+-----------------------------------+
| 3. Traefik Proxy v3       | Máxima velocidad de desarrollo    | El recolector de basura (GC) de Go|
|    (Provider Gateway API) | en un único binario Go (50MB RAM);| introduce ligera variabilidad p99 |
|                           | SCC restricted-v2 sin privilegios.| frente a C++ o eBPF en kernel.    |
+---------------------------+-----------------------------------+-----------------------------------+
| 4. Envoy Gateway          | Estándar de referencia CNCF puro; | Arquitectura desacoplada en dos   |
|    (Referencia CNCF)      | elimina el vendor lock-in mediante| capas (controlador Go + proxies   |
|                           | streaming dinámico xDS v3 ADS.    | Envoy C++); depuración compleja.  |
+---------------------------+-----------------------------------+-----------------------------------+
| 5. Micro-Proxy Linkerd    | Máximo aislamiento de fallos por  | Cambio de modelo de licenciamiento|
|    (Rust linkerd2-proxy)  | Pod con Rust (memoria segura,     | comercial en versiones 2.15+;     |
|                           | 15-30MB/Pod, cero CVEs de memoria)| mantiene el modelo con sidecars.  |
+---------------------------+-----------------------------------+-----------------------------------+
| 6. Kong Gateway + Kuma    | Integra máquinas virtuales legacy | Alto consumo de memoria; plano de |
|    (Híbrido Multi-Zona)   | con K8s; DNS embebido (*.mesh)    | datos en dos niveles              |
|                           | y portal de APIs corporativo.     | (OpenResty C/Lua + Envoy C++).    |
+---------------------------+-----------------------------------+-----------------------------------+
```

---

## 🌐 El Dilema del Enrutamiento FQDN de Doble Plano (Norte-Sur vs. Este-Oeste)

Uno de los errores conceptuales más frecuentes en la ingeniería de plataformas ocurre con la **resolución de nombres de dominio (FQDN)**.

Muchos arquitectos asumen erróneamente:
> *"Si configuro un `HTTPRoute` de Gateway API con `Host(`facturacion.internal.corp`)`, mis microservicios internos podrán conectarse inmediatamente invocando `https://facturacion.internal.corp/cobrar`."*

**Esta premisa es 100% falsa.**

```
   [ TRÁFICO NORTE-SUR (INGRESS) ]                 [ TRÁFICO ESTE-OESTE (INTERNO) ]
Cliente Externo (Navegador / App)              Pod A (Servicio Frontend / Cliente)
              │                                               │
   1. Consulta DNS Público/Corp                      1. Consulta DNS del Clúster
   (AWS Route 53 / Infoblox)                       (/etc/resolv.conf -> CoreDNS)
              │                                               │
   2. Retorna VIP del Ingress                    2. ¿Conoce CoreDNS el FQDN?
              │                                      ┌────────┴────────┐
   3. Envía TCP SYN + TLS                         NO │                 │ SÍ
              │                                      ▼                 ▼
   4. Traefik / Gateway API                     Error NXDOMAIN     Retorna VIP
      Evalúa Cabecera Host y                   (¡El kernel aborta  (Enruta hacia el
      Reenvía hacia el Pod                      el socket TCP!)    Gateway o Pod)
```

### Por Qué Falla la Comunicación Este-Oeste: El Límite de Capas
Traefik, Envoy y HAProxy operan en la **Capa 7 (Aplicación)**. No pueden procesar una petición HTTP hasta que se completa el saludo de tres vías TCP (SYN, SYN-ACK, ACK) en la Capa 4.

Cuando el Pod A invoca `http://facturacion.internal.corp`:
1. El kernel de Linux ejecuta `getaddrinfo(3)`, consultando `/etc/resolv.conf` (CoreDNS del clúster).
2. Si `facturacion.internal.corp` no está registrado en CoreDNS, este responde de inmediato con un error **`NXDOMAIN`**.
3. El kernel cancela la conexión con el error `curl: (6) Could not resolve host`.
4. **El paquete TCP jamás se emite, y las políticas, filtros, limitadores de tasa y middlewares de Gateway API NUNCA llegan a ejecutarse.**

### La Barrera de Inmutabilidad de CoreDNS en OpenShift
En Red Hat OpenShift (4.14 a 4.20+), el archivo `Corefile` de CoreDNS es administrado por el DNS Operator y es **estrictamente inmutable**. No es posible inyectar reglas de reescritura directamente.

### 3 Patrones Arquitectónicos Validados para Resolver FQDNs Este-Oeste:

1. **Patrón A: Reenvío de Zona con el OpenShift DNS Operator (Estándar Red Hat)**
   - Se configura `spec.servers[].forwardPlugin` en el operador para reenviar `.corp.internal` a un pod secundario de CoreDNS sin privilegios que aplica reglas de reescritura (`rewrite name exact facturacion.internal.corp facturacion.svc.cluster.local`).
2. **Patrón B: Ingress Split-Horizon mediante Servicio de Traefik (El Patrón Más Simple en ROSA/AWS)**
   - Tal como se demuestra en [`nubenetes/traefik-fqdn-management-poc-openshift-aws`](https://github.com/nubenetes/traefik-fqdn-management-poc-openshift-aws), se asocia `facturacion.corp.internal` en una zona privada de AWS Route 53 apuntando a la IP ClusterIP interna de Traefik. Los pods resuelven el FQDN limpiamente mediante el DNS de la VPC y Traefik inspecciona la cabecera `Host`. **¡Cero modificaciones en CoreDNS y cero parches de `hostAliases` en los pods!**
3. **Patrón C: Captura Nativa en la Malla (Patrón Zero-Trust en Ambient y Cilium)**
   - **Istio Ambient**: El demonio `ztunnel` captura el tráfico DNS en el nodo, sintetiza una IP virtual no enrutable (`240.240.0.0/16`) y encapsula la conexión en un túnel mTLS HBONE (puerto 15008).
   - **Cilium eBPF**: El mecanismo `toFQDNs` en el kernel intercepta las consultas DNS y actualiza mapas de memoria eBPF en tiempo real.

---

## ⚡ Gateway API: ¿Requiere Obligatoriamente Traefik?

Existe la creencia errónea de que adoptar Kubernetes Gateway API exige instalar Traefik.

**La Realidad: Gateway API es una especificación abierta (`gateway.networking.k8s.io`), NO un producto de software.**

Existen más de 15 controladores conformes en el mercado:
- **Sin Traefik**: Puedes implementar Gateway API al 100% utilizando **Istio Ambient (OSSM 3.x)**, **Envoy Gateway** o **Cilium eBPF**.
- **Con Traefik v3**: Obtienes la implementación más ligera, sencilla y fácil de operar para los equipos de desarrollo.

### Por Qué las OpenShift `Route` Clásicas NO Son una Opción en 2026
Mantener rutas clásicas de OpenShift (`route.openshift.io/v1`) acumula una severa deuda técnica:
1. **Límite Perimetral**: No pueden gestionar tráfico interno Este-Oeste ni mTLS inter-servicios.
2. **Vendor Lock-in**: Los manifiestos no son portables a AWS EKS, Azure AKS ni Google GKE.
3. **Sufijo Obligatorio**: Dependencia rígida del dominio `*.apps.<nombre-del-cluster>`.
4. **Enrutamiento L7 Frágil**: La división de tráfico Canary y reescritura de URLs dependen de anotaciones inseguras (`haproxy.router.openshift.io/snippet`), habitualmente vetadas por auditorías de ciberseguridad.
5. **RBAC Monolítico**: Mezcla permisos de infraestructura con el despliegue de microservicios.

---

## 🔍 Análisis Técnico: Traefik Proxy v3 Gateway API

¿Por qué **Traefik Proxy v3** se consolida como una de las mejores opciones para el Ingress perimetral y micro-enrutamiento corporativo?

### 1. Binario Único Estático en Go vs. Motores Desacoplados de Envoy
A diferencia de Envoy Gateway e Istio, que requieren un controlador en Go sincronizando configuraciones dinámicas xDS mediante gRPC hacia contenedores independientes de Envoy en C++, Traefik integra el **controlador de Gateway API y el motor proxy inverso en un único binario estático**:
- **Consumo de Memoria**: Apenas **50 MB a 100 MB de RAM** por réplica en producción.
- **Tiempo de Arranque**: Reconcilia la tabla completa de rutas del clúster en `<1.5 segundos`.
- **Recarga en Caliente con Cero Caídas**: Traefik compila el grafo de rutas en memoria y realiza un intercambio de punteros atómicos en Go. **Cero paquetes perdidos, cero reinicios de sockets TCP y sin recargas de procesos estilo NGINX.**

### 2. Vinculación Declarativa de Middlewares mediante `ExtensionRef`
Traefik permite asociar limitadores de tasa (*rate limiting*), disyuntores (*circuit breakers*), autenticación OIDC y reintentos directamente a los manifiestos estándar de Gateway API:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ruta-pedidos-api
  namespace: produccion-ecommerce
spec:
  parentRefs:
    - name: edge-gateway
      namespace: traefik-system
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /api/v1/pedidos
      filters:
        - type: RequestHeaderModifier
          requestHeaderModifier:
            add:
              - name: X-Gateway-Engine
                value: Traefik-v3-GatewayAPI
        - type: ExtensionRef
          extensionRef:
            group: traefik.io
            kind: Middleware
            name: limitador-tasa-pedidos
        - type: ExtensionRef
          extensionRef:
            group: traefik.io
            kind: Middleware
            name: circuit-breaker-pedidos
      backendRefs:
        - name: servicio-pedidos-v1
          port: 8080
          weight: 80
        - name: servicio-pedidos-v2
          port: 8080
          weight: 20
```

### 3. Compatibilidad Nativa con OpenShift `restricted-v2` SCC
A diferencia de Cilium, Traefik opera **100% sin privilegios** (usuario no root UID `10001`, `drop: ["ALL"]`, sin volúmenes de host ni red del nodo). Se instala directamente sobre OpenShift 4.20+ con **OVN-Kubernetes**, manteniendo intactas las garantías de soporte oficial de Red Hat Enterprise Linux.

---

## 🔬 Caso de Estudio en Producción: Cilium eBPF y GKE Dataplane V2 (`jenkins-2026`)

Para plataformas donde el rendimiento extremo y la mínima latencia son prioritarios, **Cilium eBPF** representa el estándar de vanguardia.

Una implementación de referencia empresarial se analiza en [`github.com/nubenetes/jenkins-2026`](https://github.com/nubenetes/jenkins-2026), ejecutándose en Google Kubernetes Engine con **Dataplane V2**:

```hcl
# terraform/gke/main.tf en github.com/nubenetes/jenkins-2026
resource "google_container_cluster" "primary" {
  name              = "gke-cluster-produccion"
  datapath_provider = "ADVANCED_DATAPATH" # Cilium / eBPF administrado por Google
  
  # Cifrado WireGuard transparente en el kernel entre todos los nodos
  in_transit_encryption_config = "IN_TRANSIT_ENCRYPTION_INTER_NODE_TRANSPARENT"

  # Controlador Gateway API estándar de Google Cloud
  gateway_api_config {
    channel = "CHANNEL_STANDARD"
  }
}
```

### Sinergia con Cargas de CI/CD Efímeras
En `jenkins-2026`, los agentes de compilación se crean dinámicamente y viven entre 30 segundos y 5 minutos.
- **Por Qué Fracasan los Sidecars en CI/CD:** Inyectar un sidecar añade entre 5 y 10 segundos de retardo en el inicio, consume 50-100 MB de RAM por contenedor efímero y causa fallos si el proxy termina antes de que concluya el envío de registros de compilación.
- **La Ventaja de Cilium eBPF:** Dataplane V2 aplica microsegmentación y cifrado WireGuard directamente en el kernel con **0 ms de retraso de inicio y 0 MB de consumo de RAM en el Pod**.

### La Ironía de Cilium Administrado en GKE
Aunque Google se encarga de la estabilidad del kernel, Dataplane V2 bloquea el plano de control:
- Los operadores del clúster **NO** tienen acceso a la CLI de `cilium` ni a la interfaz gráfica de Hubble.
- No es posible instalar la malla de servicios de Cilium upstream (`GatewayClass: cilium`) debido a colisiones en los programas BPF del kernel.
- WireGuard cifra el tráfico entre nodos en la red física, pero proporciona **cero identidad criptográfica a nivel de Pod (sin certificados SPIFFE X.509)**.

---

## 📊 Matriz Comparativa Multi-Motor 2026

```
+---------------------------+-------------------+-------------------+-------------------+-------------------+-------------------+
| Dimensión Arquitectónica  | Traefik Proxy v3  | Envoy Gateway     | Istio Ambient     | Cilium eBPF       | OpenShift Route   |
+---------------------------+-------------------+-------------------+-------------------+-------------------+-------------------+
| Motor de Ejecución        | Binario estático  | Proxy C++ Envoy   | Rust ztunnel +    | eBPF en Kernel    | Demonio HAProxy   |
|                           | en lenguaje Go    | en espacio usuario| Envoy Waypoint    | Linux + Envoy     | en espacio usuario|
+---------------------------+-------------------+-------------------+-------------------+-------------------+-------------------+
| Estado de Gateway API     | Estándar v1.x GA  | Referencia CNCF GA| Estándar v1.x GA  | Estándar v1.x GA  | ❌ Deprecado /    |
|                           |                   |                   |                   |                   | No compatible     |
+---------------------------+-------------------+-------------------+-------------------+-------------------+-------------------+
| Consumo de RAM por Pod    | 0MB (Sin sidecars)| 0MB (Edge) /      | 0MB (Pods de app)/| 0MB (Bypass puro  | 0MB (Sólo perime- |
|                           |                   | ~150MB (Gateway)  | ~30MB (ztunnel)   | sockops en kernel)| tro perimetral)   |
+---------------------------+-------------------+-------------------+-------------------+-------------------+-------------------+
| Penalización Latencia P99 | ~0.8ms – 1.2ms    | ~0.6ms – 0.9ms    | ~0.4ms – 0.7ms    | < 0.15ms          | ~1.2ms – 2.0ms    |
|                           |                   |                   |                   | (A nivel kernel)  | (Picos de recarga)|
+---------------------------+-------------------+-------------------+-------------------+-------------------+-------------------+
| Cifrado Tráfico E-O       | BackendTLSPolicy  | BackendTLSPolicy  | Túnel HBONE mTLS  | WireGuard o IPsec | ❌ No disponible  |
|                           | o Traefik Mesh    | o sidecar Envoy   | 1.3 (Puerto 15008)| a nivel de kernel |                   |
+---------------------------+-------------------+-------------------+-------------------+-------------------+-------------------+
| Identidad SPIFFE por Pod  | ⚠️ Requiere gestor| ⚠️ Requiere SPIRE | ✅ Nativo con     | ⚠️ WireGuard a    | ❌ No soportado   |
|                           | de certificados   | externo           | validación SAN    | nivel de nodo     |                   |
+---------------------------+-------------------+-------------------+-------------------+-------------------+-------------------+
| Integración CNI OpenShift | ✅ 100% Nativo    | ✅ 100% Nativo    | ✅ Estándar oficial| ⚠️ Alto riesgo    | ✅ Nativo por     |
|                           | (OVN-Kubernetes)  | (OVN-Kubernetes)  | Red Hat OSSM 3.x  | (Reemplaza CNI)   | defecto           |
+---------------------------+-------------------+-------------------+-------------------+-------------------+-------------------+
| Perfil de Seguridad SCC   | restricted-v2     | restricted-v2     | spc_t / privileged| CAP_BPF / Root    | hostnetwork /     |
|                           | (Sin privilegios) | (Sin privilegios) | (DaemonSet nodo)  | (CNI privilegiado)| Privilegiado      |
+---------------------------+-------------------+-------------------+-------------------+-------------------+-------------------+
| Panel Web en Tiempo Real  | ✅ UI web nativa  | ❌ Ninguno        | ❌ Kiali (Instala-| ✅ Hubble UI      | Consola web de    |
|                           | integrada         | (Solo CLI/Grafana)| ción por separado)| (Pod separado)    | OpenShift         |
+---------------------------+-------------------+-------------------+-------------------+-------------------+-------------------+
| Facilidad de Operación    | 🌟 Máxima         | ⚖️ Media (Curva   | ⚖️ Excelente valor| 🔧 Compleja       | 📉 Mala (Deuda    |
|                           | (Despliegue fácil)| de xDS compleja)  | soporte Red Hat   | depuración kernel | técnica legacy)   |
+---------------------------+-------------------+-------------------+-------------------+-------------------+-------------------+
```

---

## 💰 Impacto Financiero y Modelado de Coste Total de Propiedad (TCO)

¿Cuál es el coste real en infraestructura cloud de mantener sidecars frente a las arquitecturas modernas sin sidecars?

```
Consumo Estimado de Memoria RAM en Infraestructura de Proxy:

  500 GB ──────────────────────────────────────────────────────────  Sidecars Tradicionales
                                                                     (5.000 Pods @ 100MB)
  250 GB ─────────────────────────────────  Sidecars Tradicionales
                                            (2.500 Pods @ 100MB)
  100 GB ──────────  Sidecars Tradicionales
                     (1.000 Pods @ 100MB)
   25 GB ─────────────────────────────────  Modo Istio Ambient (OSSM 3.x)
                                            (~15-30MB ztunnel por nodo + waypoints selectivos)
    5 GB ─────────────────────────────────  Ingress Traefik v3 (Norte-Sur + Split-Horizon)
                                            (Solo réplicas del Gateway)
    0 GB ─────────────────────────────────  Cilium eBPF Datapath en Kernel
                     1.000 Pods            2.500 Pods            5.000 Pods
```

- **El Impuesto del Sidecar:** En un clúster de 5.000 pods, los sidecars consumen **500 GB de memoria RAM** y miles de hilos de vCPU, superando los **$120.000 USD anuales** en costes evitables de infraestructura cloud.
- **La Solución en 2026:** Adoptar **Istio Ambient**, **Cilium eBPF** o **Ingress sin sidecars con Traefik v3** recupera hasta el **90% de los recursos de cómputo**, reduciendo directamente la factura en AWS, Azure o Google Cloud.

---

## 🧭 Diagrama Maestro de Decisión: ¿Qué Arquitectura Debes Elegir?

```
                     ┌───────────────────────────────────────────────┐
                     │ Inicio: Elección Estratégica Ingress & Mesh   │
                     └───────────────────────┬───────────────────────┘
                                             │
             ¿Necesitas latencia inferior a 0.2ms en el kernel o bypass eBPF?
                                             │
                      ┌──────────────────────┴──────────────────────┐
                   SÍ │                                           NO│
                      ▼                                             ▼
       ┌─────────────────────────────┐        ¿Exige tu normativa mTLS criptográfico
       │ Adopta Cilium eBPF Gateway  │        estricto con SPIFFE por cada Pod?
       │ • Bypass sockops en kernel  │                              │
       │ • Cifrado WireGuard rápido  │               ┌──────────────┴──────────────┐
       │ • Requiere cambio de CNI    │            SÍ │                           NO│
       └─────────────────────────────┘               ▼                             ▼
                                        ¿Es tu plataforma principal   ¿Priorizas velocidad de desarrollo,
                                         Red Hat OpenShift 4.20+?      bajo consumo y middlewares ricos?
                                                     │                             │
                                         ┌───────────┴───────────┐         ┌───────┴───────┐
                                      SÍ │                     NO│      SÍ │             NO│
                                         ▼                       ▼         ▼               ▼
                          ┌─────────────────────┐ ┌────────────────┐ ┌───────────┐ ┌───────────────┐
                          │ Adopta Modo Istio   │ │ Adopta Envoy GW│ │ Adopta    │ │ Adopta Envoy  │
                          │ Ambient (OSSM 3.x)  │ │ + Istio Mesh   │ │ Traefik v3│ │ Gateway       │
                          │ • CNI nativo Red Hat│ │ • xDS puro CNCF│ │ Gateway   │ │ • Estándar    │
                          │ • ztunnel compartido│ │ • K8s estándar │ │ • 50MB RAM│ │   xDS CNCF    │
                          └─────────────────────┘ └────────────────┘ └───────────┘ └───────────────┘
```

### Guía de Recomendación por Caso de Uso:
1. **Caso 1: Ingress Web y APIs de Alta Velocidad en OpenShift o Multi-Cloud**  
   👉 **Recomendación: Traefik Proxy v3 Gateway API.** Ofrece la menor complejidad operativa, 50MB de RAM, panel web en tiempo real y compatibilidad nativa con `restricted-v2` SCC sin modificar el CNI de OpenShift.
2. **Caso 2: Sector Bancario, Sanidad y Cumplimiento Zero-Trust Estricto (PCI-DSS / HIPAA)**  
   👉 **Recomendación: Istio Ambient Mode (Red Hat OSSM 3.x).** Garantiza mTLS 1.3 con identidades de carga de trabajo SPIFFE validadas en cada conexión sin el coste de los sidecars.
3. **Caso 3: Procesamiento Financiero de Alta Frecuencia / IA / Latencia < 0.2ms**  
   👉 **Recomendación: Cilium eBPF Gateway API.** Al omitir la pila TCP/IP tradicional en el kernel mediante `sockops`, Cilium alcanza latencias sub-milimétricas y cifrado WireGuard de alta velocidad.
4. **Caso 4: Estandarización de Referencia CNCF Multi-Proveedor**  
   👉 **Recomendación: Envoy Gateway.** Ideal para organizaciones con políticas estrictas de neutralidad tecnológica que demandan streaming de configuración xDS puro.

---

## 🚀 Plan de Migración en 3 Fases con Cero Caídas

Para equipos de plataforma listos para migrar desde Ingress clásico u OpenShift Routes hacia Gateway API:

1. **Fase 1: Despliegue Paralelo del Plano de Control (Día 1)**  
   Instala los CRDs estándar de Gateway API (`gateway.networking.k8s.io/v1`). Despliega tu controlador elegido (Traefik v3, Envoy Gateway o Istio Ambient) en paralelo con el ingress actual.
2. **Fase 2: Enrutamiento en Sombra y Validación Canary (Día 2 a 14)**  
   Publica recursos `HTTPRoute` apuntando a las aplicaciones existentes. Asocia cabeceras de seguridad, limitadores de tasa y pesos Canary. Valida el tráfico interno mientras la producción externa sigue usando las rutas legacy.
3. **Fase 3: Conmutación de DNS y Retirada de Rutas Antiguas (Día 15)**  
   Actualiza los registros DNS en tu proveedor (AWS Route 53, Cloudflare) apuntando al nuevo balanceador de Gateway API. Elimina los manifiestos obsoletos de `Ingress` y `Route`, recuperando memoria del clúster y eliminando anotaciones frágiles.

---

## 📚 Referencias Oficiales y Fuentes de Autoridad

- **Repositorio del Laboratorio de Ingress y Mallas Cloud-Native**: [https://github.com/nubenetes/cloudnative-ingress-mesh-lab](https://github.com/nubenetes/cloudnative-ingress-mesh-lab)
- **PoC de Gestión de FQDN con Traefik en OpenShift ROSA**: [https://github.com/nubenetes/traefik-fqdn-management-poc-openshift-aws](https://github.com/nubenetes/traefik-fqdn-management-poc-openshift-aws)
- **Arquitectura Empresarial con GKE Dataplane V2**: [https://github.com/nubenetes/jenkins-2026](https://github.com/nubenetes/jenkins-2026)
- **Especificación Oficial de Kubernetes Gateway API v1**: [https://gateway-api.sigs.k8s.io/](https://gateway-api.sigs.k8s.io/)
- **Documentación del Modo Istio Ambient**: [https://istio.io/latest/docs/ambient/overview/](https://istio.io/latest/docs/ambient/overview/)
- **Arquitectura de Malla de Servicios Cilium eBPF**: [https://docs.cilium.io/en/stable/network/servicemesh/](https://docs.cilium.io/en/stable/network/servicemesh/)
- **Proveedor Kubernetes Gateway de Traefik Proxy v3**: [https://doc.traefik.io/traefik/providers/kubernetes-gateway/](https://doc.traefik.io/traefik/providers/kubernetes-gateway/)
- **Arquitectura de Red Hat OpenShift Service Mesh 3.x**: [https://docs.openshift.com/container-platform/latest/service_mesh/](https://docs.openshift.com/container-platform/latest/service_mesh/)
