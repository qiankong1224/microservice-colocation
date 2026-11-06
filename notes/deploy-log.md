# Online Boutique 部署记录

## 阶段 0：环境检查（2026-11-04）

### 主机
| 项 | 值 |
|---|---|
| OS | Ubuntu 26.04 LTS，内核 7.0.0-38-generic，amd64 |
| CPU | 32 核 |
| 内存 | 14 GiB（检查时可用约 6.2 GiB），swap 4 GiB |
| 磁盘 | `/` 剩余 269 GB（Docker 数据同分区） |
| 8080 端口 | 空闲 |

### 软件
| 软件 | 版本 / 状态 |
|---|---|
| Docker Engine | 29.1.3（containerd 2.2.2，runc 1.4.0），用户在 docker 组，免 sudo |
| docker compose | 未安装（apt 候选 docker-compose-v2 2.40.3） |
| kubectl / kind / minikube / k3s / helm / skaffold | 均未安装，无现成集群 |

主机上已有非本项目容器（open-webui、natfrp-service、mysql-exporter 等），不触碰。

### 官方仓库
- 位置：`~/Projects/colocation/microservices-demo/`（检查时已存在，未重新 clone；remote 为官方地址，工作区无修改）
- commit：`c7cb6d5b` "Change cleanup workflow to be scheduled and hourly"
- 仓库内无 compose 文件（`find . -iname "*compose*"` 为空）
- 镜像版本（`release/kubernetes-manifests.yaml`）：`us-central1-docker.pkg.dev/online-boutique-ci/microservices-demo/*:v0.10.7`，`redis:alpine`，loadgenerator init 容器 `busybox:1.38.0@sha256:dc2d74b2…`

## 工具安装（用户已确认）
```bash
# kubectl / kind：方案 B，装到 ~/.local/bin，sha256 校验通过，无需 sudo
KV=$(curl -Ls https://dl.k8s.io/release/stable.txt)        # v1.37.2
curl -Lo ~/.local/bin/kubectl https://dl.k8s.io/release/$KV/bin/linux/amd64/kubectl
curl -Lo ~/.local/bin/kind https://kind.sigs.k8s.io/dl/v0.33.0/kind-linux-amd64
chmod +x ~/.local/bin/{kubectl,kind}
```
- kubectl v1.37.2（Kustomize v5.8.1），kind v0.33.0
- `sudo apt install -y docker-compose-v2`：sudo 要交互输密码，代理无法执行，由用户在自己的终端里安装完成 → Docker Compose 2.40.3+ds1-0ubuntu1

项目仓库：`git init ~/Projects/colocation`，`.gitignore` 含 `microservices-demo/`、`results/`。

## 阶段 1：Docker 部署（完成，已清理）

### compose 文件的生成方式
官方仓库没有 compose 文件，所以 `docker/docker-compose.yml` 是由 `docker/gen-compose.py`
**从 `release/kubernetes-manifests.yaml` 解析生成的**，不是手写：
- 镜像、全部 env、资源 limits（→ `cpus`/`mem_limit`）、securityContext（→ `user: 1000:1000`、`read_only`、`cap_drop: ALL`、`no-new-privileges`）都照搬 manifest
- compose 服务名和 K8s Deployment/Service 名一致。K8s Service 端口和容器端口不同的地址，改写成容器端口：
  - `emailservice:5000` → `emailservice:8080`（checkoutservice 的 EMAIL_SERVICE_ADDR）
  - `frontend:80` → `frontend:8080`（loadgenerator 的 FRONTEND_ADDR）
- redis-cart 的 emptyDir `/data` → tmpfs（uid/gid 1000）
- loadgenerator 及其 init 容器（busybox frontend-check）放在 `profiles: ["load"]` 里；init 容器用 `service_completed_successfully` 依赖
- 只映射 frontend 到宿主机 `8080:8080`
- `SHOPPING_ASSISTANT_SERVICE_ADDR=shoppingassistantservice:80`：manifest 里有这个变量，但没有对应的服务（K8s 里同样不存在），按原样保留

重新生成：`python3 docker/gen-compose.py`

### 执行的关键命令
```bash
cd ~/Projects/colocation/docker
python3 gen-compose.py          # 生成 docker-compose.yml
docker compose config -q        # 校验通过
./up.sh                         # 拉镜像(带重试) + up -d --pull never + 等首页 200
./up.sh --load                  # 额外启动 load profile（busybox init 检查 → loadgenerator）
./down.sh                       # down --remove-orphans（含 load profile），保留镜像
```

### 遇到的问题和解决方法
1. **拉镜像超时**：`docker compose pull` 报
   `Head "https://us-central1-docker.pkg.dev/...adservice/manifests/v0.10.7": dial tcp 198.18.0.97:443: i/o timeout`。
   原因：本机有 FlClash 代理（TUN 接口 `FlClash` 198.18.0.1/30，fake-IP DNS），访问 GCP Artifact Registry 和 Docker Hub 镜像源（`docker.1ms.run`）偶尔超时；`curl https://us-central1-docker.pkg.dev/v2/` 本身是通的（401，约 1.1 秒）。
   而 `compose pull` 只要有一个镜像失败，就会中断其他正在拉的镜像。
   解决：`up.sh` 改成逐个 `docker pull`，只拉缺的镜像，每个最多重试 5 次，再 `up -d --pull never`。实际结果：adservice 第 2 次、busybox 第 3 次成功，其余一次成功。
2. **第一轮验证时购物车看起来是空的**：原因是测试脚本把加购、查看购物车、下单放在同一个 session 里连着跑了，下单会清空购物车。cartservice 日志能看到 `AddItemAsync ... quantity=2` → `EmptyCartAsync`，属于正常行为，不是 bug。换新 session 只加购后查看，`/cart` 里能看到 Sunglasses。
3. **启动瞬间 frontend 日志有 `failed to retrieve ads: DeadlineExceeded`**：adservice 是 JVM 服务，启动比 frontend 慢，所以最早的 1–2 个请求超时；adservice 起来之后就不再出现。
4. frontend 日志有 1 条 `Failed to fetch the name of the cluster in which the pod is running`：frontend 会去查 GCP metadata server，非 GKE 环境下必然失败，不影响功能。

### 验证结果
- `docker compose ps`：11 个服务全部 `Up`，RestartCount 都是 0（compose 文件里没有定义 healthcheck，所以只显示 Up，没有 healthy）
- `curl http://localhost:8080/` → 200（首页有 9 个商品链接）
- `GET /product/OLJCESPC7Z` → 200，页面里有 Sunglasses、推荐和广告
- `POST /cart`（`product_id=OLJCESPC7Z&quantity=2`）→ 302 跳到 `/cart`；`GET /cart` 里有 Sunglasses
- `POST /setCurrency currency_code=EUR` → 302，首页价格变成 €
- `POST /cart/checkout`（frontend handlers.go 里的表单字段）→ 200，frontend 日志 `order placed`，覆盖 checkout→payment/shipping/email/currency/cart
- loadgenerator（USERS=10, RATE=1）跑 2 分钟：**289 个请求，0 失败**，平均 17 ms，中位数 7 ms；loadgenerator 运行期间所有后端服务日志里都没有 error
- 清理：`./down.sh` 之后，boutique 项目剩余容器数为 0，其他已有容器没受影响

## 阶段 2：Kubernetes 部署（完成，集群保留运行）

### 版本
| 组件 | 版本 |
|---|---|
| kind | v0.33.0 |
| kubectl (client) | v1.37.2 |
| K8s server | v1.37.0（`kindest/node:v1.37.0@sha256:a1ed56cf…`） |
| 节点 OS / runtime | Debian GNU/Linux 13 (trixie) / containerd 2.3.4，内核与宿主机共用 7.0.0-38-generic |
| 应用镜像 | v0.10.7（与 Docker 阶段相同） |

### 集群
- 1 control-plane + 3 worker，集群名 `colocation`，kubectl context `kind-colocation`
- **4 个节点都是同一台物理机上的 Docker 容器**（kind），共享 32 核 CPU、14 GiB 内存和同一个内核；节点间网络是宿主机上的 docker bridge（节点 IP 172.21.0.2–5）
- worker 打了标签 `colocation/worker=w1|w2|w3`（kind-config.yaml 里配置），方便下一阶段使用；目前没有任何调度规则引用这些标签

### 执行的关键命令
```bash
free -h                                       # 建集群前 available 7.0 GiB（≥ 6 GiB）
kind create cluster --config k8s/kind-config.yaml \
  --image kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5
kubectl wait --for=condition=Ready node --all; kubectl get nodes -o wide   # 4 个节点都 Ready
# 只把 12 个镜像（11 个 v0.10.7 + redis:alpine）导入 3 个 worker
kind load docker-image --name colocation \
  --nodes colocation-worker,colocation-worker2,colocation-worker3 <12 个镜像>
k8s/deploy.sh                                 # = create namespace boutique + apply release manifest + wait
kubectl -n boutique port-forward svc/frontend 8080:80
```
脚本：`k8s/deploy.sh [ns]`、`k8s/teardown.sh [ns]`（只删 namespace）、`k8s/delete-cluster.sh`（只删 `colocation`，执行前要确认）。

### 遇到的问题
1. **loadgenerator 的 init 容器 `frontend-check` 一直 `Init:ImagePullBackOff`**（按要求没有手动重试，先汇报）：
   `kubectl get events` 报
   `failed to resolve reference "docker.io/library/busybox@sha256:dc2d74b2…": Head "https://registry-1.docker.io/v2/...": dial tcp 104.244.43.128:443: i/o timeout`，
   后面又有一次 `dial tcp 157.240.21.9:443: connect: connection refused`。
   **原因**：kind 节点里的 containerd 没有配镜像源，是**直连 Docker Hub**（registry-1.docker.io）拉镜像的，**遇到了 DNS 污染**（解析到 104.244.43.128、157.240.21.9 这类不可用的地址），所以超时或被拒绝。宿主机 dockerd 配了镜像源（`docker.1ms.run`、`docker.m.daocloud.io`），所以 Docker 阶段没遇到这个问题。
   **解决方法（用户操作）**：
   1. 把 FlClash 改成 **Rule 模式 + TUN**，让 kind 节点容器的流量和 DNS 也走代理（验证：节点内 `crictl pull alpine:3.20` 成功；节点内解析 `registry-1.docker.io` 得到 fake-IP 198.18.0.4）
   2. 在 3 个 worker 上按 digest 拉取：`crictl pull busybox@sha256:dc2d74b28e4cf8984fa52af1f39bc7c3d9c73760b41a74d629f5d11b1ab28616`
   3. 删除旧 Pod `loadgenerator-9878487f4-8xqcw`（在 colocation-worker 上），Deployment 重建出新 Pod `loadgenerator-9878487f4-kkt97`，被调度到 **colocation-worker3**，1/1 Running
   
   最终没有用 `kind load` 导入 busybox，也没有修改 manifest。

   > ⚠️ **以后凡是需要联网的步骤（拉镜像、建集群、clone、kind load 之前的 docker pull 等），都要先确认 FlClash 的 TUN 是开着的**（`ip -br addr | grep FlClash` 能看到 198.18.0.1/30，并且节点内 `getent hosts registry-1.docker.io` 解析到 198.18.x.x）。
2. 启动时各服务有几条 `Readiness probe failed ... within 1s`：容器刚启动、gRPC 服务还没开始监听，几秒后就都 READY 了，RESTARTS 全是 0。
3. `deploy.sh` 第一次运行时，我外面套的 `timeout 280` 比脚本里的 `kubectl wait --timeout=600s` 短，所以在 wait 中途被中断（exit 124）；由于 loadgenerator 一直不 available，wait 本来也会等满 600 秒。已经把 deploy.sh 改成：先等除 loadgenerator 以外的所有 Deployment，loadgenerator 单独等并提示原因。
4. `frontend-external` 的 EXTERNAL-IP 一直是 `<pending>`：kind 没有 LoadBalancer 实现，这是正常的，没有去修。

### 验证结果
- 12 个 Pod（含 loadgenerator）全部 `1/1 Running`，RESTARTS 都是 0
- port-forward 8080 后：首页 200（9 个商品链接），`/product/OLJCESPC7Z` 200，`POST /cart` 302，`/cart` 里有 Sunglasses，`setCurrency EUR` 302（首页价格变成 €17.68），`/cart/checkout` 200
- loadgenerator 压测：从 05:46:31Z 跑到 05:48:36Z（约 2 分 05 秒），读取的是 Locust 的累计统计；同一时间段 11 个后端服务日志里的 error/exception 都是 0，loadgenerator 日志里也没有报错

### Docker 和 K8s 压测对比（Locust 2.43.0，USERS=10，RATE=1，约 2 分钟）

Locust 以 headless 模式运行，每 2 秒打印一次**从启动开始累计**的统计。下表各列都是某一时刻的累计快照，"t" 是距 Locust 启动的秒数。

| 指标 | Docker（t≈126 s） | K8s，之前报告的（t≈122 s） | K8s，时间对齐（t≈126 s） |
|---|---|---|---|
| 快照时间 (UTC) | 2026-11-04 约 15:05:31 | 2026-11-06 05:48:35 | 2026-11-06 05:48:39 |
| 请求数 | 289 | 289 | 299 |
| 失败数 | 0 (0.00%) | 0 (0.00%) | 0 (0.00%) |
| Aggregated 平均 | 17 ms | 6 ms | 6 ms |
| Aggregated 中位数 | 7 ms | 6 ms | 6 ms |
| Aggregated 最小 / 最大 | 3 / 212 ms | 3 / 17 ms | 3 / 21 ms |
| Aggregated p95 | 无（见下） | 无 | 无 |
| GET / 中位数（请求数） | 51 ms (20) | 8 ms (23) | 8 ms (23) |
| POST /setCurrency 中位数（请求数） | 50 ms (29) | 8 ms (26) | 8 ms (28) |

**为什么两边都是 289：巧合，两份数据是各自独立的。** 证据如下：
- 两次运行的 Locust 实例不同：Docker 的是容器 `dd4c4f766bfc`，2026-11-04 15:03:25 UTC 启动；K8s 的是 Pod `loadgenerator-9878487f4-kkt97`（在 colocation-worker3 上），2026-11-06 05:46:33 UTC 启动。两次相隔约 38.7 小时。
- 两边的分接口请求数不同：GET / 是 20 对 23，GET /cart 是 28 对 43，POST /cart 是 28 对 34，POST /cart/checkout 是 12 对 10；延迟分布也完全不同（最大值 212 ms 对 17 ms）。
- 两边达到 289 的时间点也不同：Docker 在 t≈126 s，K8s 在 t≈122 s。以 t≈126 s 对齐比较时，K8s 是 299。之前汇报 289，是因为我当时在 05:48:36 读日志，读到的最后一个快照恰好是 289。
- Locust 的请求数主要由虚拟用户的随机等待时间决定：`src/loadgenerator/locustfile.py` 里是 `wait_time = between(1, 10)`，每个任务之间等 1–10 秒（平均 5.5 秒），10 个用户算下来约 2 req/s，和服务快慢基本无关。所以两边在差不多同样时长内的总数都落在 280–300 附近，并不奇怪。

**为什么没有 p95：** loadgenerator 镜像以 `locust --headless -u 10 -r 1` 运行，没有设置 `--run-time`。Locust 只会在压测**结束**时打印 percentile 表，运行中的周期快照只有 Avg/Min/Max/Med。两次压测都没有结束（Docker 是被 `down.sh` 直接删掉的，K8s 的还在运行），所以日志里找不到 p95（`grep -ciE 'percentile|95%'` 两个文件都返回 0）。下一阶段如果需要 p95/p99，建议用 `--run-time` 或 `--csv` 运行一个单独的 Locust 来做对比。

**数据来源和复现命令：**
```bash
# K8s：Locust 启动时间和累计快照
kubectl -n boutique get pod loadgenerator-9878487f4-kkt97 \
  -o jsonpath='{.status.containerStatuses[0].state.running.startedAt}'      # 2026-11-06T05:46:31Z（容器）
kubectl -n boutique logs loadgenerator-9878487f4-kkt97 -c main --timestamps \
  | grep -m1 'Starting Locust'                                               # 05:46:33.216Z
kubectl -n boutique logs loadgenerator-9878487f4-kkt97 -c main --timestamps \
  | grep Aggregated | awk '$1>="2026-11-06T05:48:29" && $1<="2026-11-06T05:48:40"'
#   05:48:35.306Z  289  0(0.00%) | 6 3 17 6
#   05:48:37.308Z  298  0(0.00%) | 6 3 21 6
#   05:48:39.310Z  299  0(0.00%) | 6 3 21 6

# Docker（容器已在阶段 1 用 down.sh 删除，日志是当时保存的）
docker compose --profile load logs --no-log-prefix loadgenerator > /tmp/lg.log   # 2026-11-04 15:05:32 +08 保存
# 压测开始：up.sh --load 在 2026-11-04T15:03:21Z 执行，Locust 在 15:03:25 UTC 启动
```
两份原始日志已归档到 `results/task1/`。按 `.gitignore` 的约定这个目录不进 git，所以这里只记录 sha256：
- `docker-loadgenerator.log`：`c441415500fe711f0b0d2c8b68796c8c2056a04eec3b20394d8f50743391b967`
- `k8s-loadgenerator-kkt97.log`（带 `--timestamps`，截至 06:05:48Z）：`3f06030befe71aab1797e7653402bb74155c9a064ee8429b7225589f4b86619c`

说明：Docker 那一轮是在刚启动后不久跑的，GET / 和 /setCurrency 明显偏慢，平均值也被拉高了；最可能的原因是 JVM 的 adservice、Python 服务和 Go 服务都还在预热，这一点**没有专门验证**。K8s 这一轮跑之前，服务已经运行了约 17 分钟。两轮的负载很低（约 2 req/s），运行条件也不一样，**这张表不能当作网络延迟的对比结论**，只能说明两种部署都能正常承载负载。

### 资源占用（压测后，`docker stats --no-stream`）
| 节点容器 | 内存 | 内存 % | CPU % |
|---|---|---|---|
| colocation-control-plane | 702.2 MiB | 4.80% | 27.95% |
| colocation-worker | 389.8 MiB | 2.66% | 4.22% |
| colocation-worker2 | 353.8 MiB | 2.42% | 10.81% |
| colocation-worker3 | 446.9 MiB | 3.05% | 6.98% |
| **4 个节点合计** | **约 1.85 GiB** | | |

宿主机 `free -h`：total 14 GiB，used 8.5 GiB，available **5.8 GiB**；swap 已用 2.8 / 4.0 GiB。
（刚部署完、还没跑 loadgenerator 时：4 个节点分别是 696/469/337/433 MiB，available 6.2 GiB。）

### 默认调度结果（`notes/placement-default.txt`）
| 节点 | 服务 |
|---|---|
| colocation-control-plane | （无业务 Pod，有 control-plane taint） |
| colocation-worker | adservice、emailservice |
| colocation-worker2 | frontend、productcatalogservice、currencyservice、checkoutservice、redis-cart |
| colocation-worker3 | cartservice、paymentservice、recommendationservice、shippingservice、loadgenerator |
