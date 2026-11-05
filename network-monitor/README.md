# 家庭原始网络质量监控说明

这套配置的目标不是“测网页打开快不快”，而是先把最底层的原始网络质量看清楚：从你的 Windows 常开机出发，定期对路由器、光猫、运营商接入层和公网目标做 `ICMP ping`，把结果写进 `InfluxDB`，再由 `Grafana` 展示。

当前采用的是“展示和存储走 Docker，探测走 Windows 主机原生”的结构：

- `Grafana`：展示图表和状态面板
- `InfluxDB`：保存时序数据
- `Telegraf`：负责真正发 `ping`

这样拆开的原因很实际：

- `Grafana` 和 `InfluxDB` 放进 Docker 里维护方便
- `Telegraf` 放在 Windows 主机原生运行，更接近真实网络路径
- 可以尽量少受 `Docker Desktop` 虚拟网络和 `Clash Verge` 的额外影响

---

## 当前监控目标

当前版本已经写入这 7 个目标（按“由内到外”的链路顺序排列）：

- `192.168.31.1`：小米 `Redmi AX1800` 路由 LAN，内网第一跳
- `192.168.1.1`：光猫管理地址，内网第二跳
- `100.69.56.1`：运营商 `CGNAT` 接入网关（`100.64.0.0/10` 为运营商级 NAT 段），运营商侧首跳
  - 旧值 `100.84.36.1`（2026-09-29 部署时有效）已不在当前路径上，仅在 `telegraf.conf` 中注释保留备查
  - 这一行带 `@cgnat-hop` 标记，由 `update-cgnat-hop.ps1` 每天自动核对并更新，细节见下文「CGNAT 网关自动维护」
- `223.5.5.5`：阿里公共 DNS
- `119.29.29.29`：腾讯 DNSPod 公共 DNS
- `8.8.8.8`：Google 公共 DNS
- `1.1.1.1`：Cloudflare 公共 DNS

这里后 4 个虽然是 DNS 服务器的 IP，但当前做的并不是“DNS 查询性能监控”，而只是把这些稳定的公网地址当作 `ping` 目标，用来观察不同方向的公网质量。

### 为什么不再监控运营商骨干跳点

早期配置里还包含过运营商侧的骨干跳点，如 `222.72.237.93`、`222.72.236.233`（电信公网骨干）。现在已从 `ping` 目标中移除，只在 `telegraf.conf` 里以注释形式保留备查，原因：

1. **它们不是“出口 IP”**：`traceroute` 里的每一跳都是沿途路由器的接口地址，属于“过路节点”。你真正的流量走的是这些设备的转发面，与它们管理面的 ICMP 响应没有关系。
2. **ECMP 漂移**：同一条链路上有多台设备做负载分担，每次探测落到的 IP 都不同。实测同一目标连续 10 次 trace，跳点出现过 `222.72.236.233`、`222.72.236.229`、`222.72.237.85`，换一个目标还会变成 `61.152.x`、`61.172.x`。
3. **ICMP 限速**：核心路由器普遍对 ICMP 限速，实测 10 次探测只有 3 次有响应，其余全部超时。数据断断续续，既不能反映真实质量，也无法作为告警依据。

结论：运营商侧只保留稳定的 `CGNAT` 接入网关作为锚点，更外侧的公网质量由稳定的 DNS 目标代表。**骨干路径如果需要观察，应该用 `tracert`、`PingPlotter`、`Best Trace` 这类路由追踪工具，而不是 `ping` 监控。**

---

## 目录说明

本目录下各文件和子目录的作用如下：

- `docker-compose.yml`
  - 用来启动 `InfluxDB` 和 `Grafana`
- `.env`
  - 集中保存 `InfluxDB` 和 `Grafana` 的初始化参数、账号、密码、token
- `telegraf/telegraf.conf`
  - `Telegraf` 的核心采集配置
  - 定义采样间隔、写入目标、被 `ping` 的 IP 列表
- `grafana/provisioning/datasources/influxdb.yml`
  - `Grafana` 自动创建 `InfluxDB` 数据源的配置
- `grafana/provisioning/dashboards/default.yml`
  - `Grafana` 自动扫描 dashboard JSON 文件的配置
- `grafana/dashboards/raw-network-overview.json`
  - 总览页 dashboard
  - 适合同时看多目标的平均延迟、丢包、最大延迟、状态和异常次数
- `grafana/dashboards/raw-network-single-target.json`
  - 单目标详情页 dashboard
  - 顶部有 IP 选择器，适合只看某一个目标
- `grafana/dashboards/raw-network-topology.json`
  - 路径拓扑 dashboard
  - 用表格展示到 4 个公网目标各自的完整路径（跳数 / 设备地址 / 平均延迟）
- `telegraf/topology-probe.ps1`
  - 拓扑采集脚本
  - 由 `Telegraf` 的 `inputs.exec` 每 5 分钟调用一次，跑 `tracert` 并输出 InfluxDB line protocol
- `scripts/test-telegraf.ps1`
  - 测试 `Telegraf` 配置能不能正常加载和采集
- `scripts/install-telegraf-service.ps1`
  - 把 `Telegraf` 注册成 Windows 服务
  - 也负责已有服务时的重启
- `scripts/find-first-hop.ps1`
  - 用 `tracert -d` 辅助找运营商第一跳
- `scripts/update-cgnat-hop.ps1`
  - 自动检测当前 `CGNAT` 接入网关（`100.64.0.0/10` 段）
  - 发现和 `telegraf.conf` 里的值不一致时，原地改写带 `@cgnat-hop` 标记的那一行
  - 由计划任务每天调用一次，日志写在 `scripts/logs/cgnat-hop.log`
- `scripts/setup-cgnat-automation.ps1`
  - 一次性部署脚本（需要管理员权限，会自动提权）
  - 给 `Telegraf` 服务加上 `--watch-config poll`
  - 注册每天执行 `update-cgnat-hop.ps1` 的计划任务

---

## 整体架构

数据流如下：

1. `Telegraf` 每隔 `5s` 对一组 IP 做 `ping`
2. `Telegraf` 每隔 `5m` 调用一次 `topology-probe.ps1`，对 4 个公网目标各跑一次 `tracert`
3. `Telegraf` 把这两类结果都写入 `InfluxDB`
4. `Grafana` 用 Flux 查询 `InfluxDB`
5. Dashboard 把数据画成曲线、状态时间线和路径拓扑表
6. 计划任务每天调用一次 `update-cgnat-hop.ps1`，核对 `CGNAT` 网关是否变化；一旦变化就改写 `telegraf.conf`，`Telegraf` 靠 `--watch-config poll` 自动重载，无需人工重启服务

用一句话概括就是：

`Windows 主机发 ping / tracert -> InfluxDB 存数据 -> Grafana 读数据`

---

## 部署顺序

建议按下面顺序来，不要跳步。

### 1. 启动 Docker Desktop

如果这台机器需要代理才能顺利拉镜像或启动 Docker Desktop，可以临时开启 `Clash Verge` 的系统代理。

建议：

- 仅在启动 Docker Desktop 和拉镜像时临时打开
- 做原始网络采集时尽量不要同时开启 `TUN`
- 如果你平时长期开 `TUN`，最好把监控目标走 `DIRECT`

### 2. 启动 InfluxDB 和 Grafana

在当前目录执行：

```powershell
docker compose up -d
```

这条命令逐段解释如下：

- `docker`
  - 调用 Docker CLI
- `compose`
  - 使用 `docker-compose.yml` 描述的多容器编排
- `up`
  - 创建并启动服务
- `-d`
  - 后台运行，不阻塞当前终端

执行后可访问：

- Grafana：`http://127.0.0.1:3000`
- InfluxDB：`http://127.0.0.1:8086`

可以再执行：

```powershell
docker compose ps
```

解释如下：

- `ps`
  - 查看 compose 项目下所有容器状态

如果需要重启 `Grafana` 重新加载 provisioning，可以执行：

```powershell
docker compose restart grafana
```

解释如下：

- `restart`
  - 重启指定服务
- `grafana`
  - 这里指定只重启 `Grafana`

### 3. 准备 Telegraf

把 `Telegraf` 解压到你习惯的位置即可，当前脚本默认使用的是：

```text
d:\githubProductPack\telegraf-1.40.1\telegraf.exe
```

如果你以后更换了路径，可以在运行脚本时显式传参。

### 4. 测试 Telegraf 配置

执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\test-telegraf.ps1
```

逐段解释：

- `powershell`
  - 启动一个新的 Windows PowerShell 进程
- `-ExecutionPolicy Bypass`
  - 临时绕过本次执行的脚本策略限制
  - 不改系统全局策略，只对当前命令生效
- `-File .\scripts\test-telegraf.ps1`
  - 运行这个脚本文件

这个脚本内部最终会执行：

```powershell
& 'd:\githubProductPack\telegraf-1.40.1\telegraf.exe' --config 'd:\trae_works\20260926\network-monitor\telegraf\telegraf.conf' --test
```

逐段解释：

- `&`
  - PowerShell 的调用运算符
  - 用来执行变量或字符串形式的可执行文件路径
- `telegraf.exe`
  - `Telegraf` 主程序
- `--config`
  - 指定配置文件
- `--test`
  - 不进入常驻采集模式，只做一次配置加载和采样输出

这一步主要验证三件事：

- 配置文件能否被 `Telegraf` 正常读取
- `ping` 插件是否正常
- 当前被监控的 IP 是否可以采到数据

如果想单独验证拓扑采集（`tracert`）这一路，可以加上 `--input-filter`：

```powershell
& 'd:\githubProductPack\telegraf-1.40.1\telegraf.exe' --config 'd:\trae_works\20260926\network-monitor\telegraf\telegraf.conf' --test --input-filter exec
```

逐段解释：

- `--input-filter exec`
  - 只运行 `inputs.exec` 这一个插件
  - 用来快速确认 `topology-probe.ps1` 能不能被调起来、能不能吐出合法的 line protocol

注意：

- `--test` 模式不会真的把数据写进 `InfluxDB`
- 日志里出现 `Outputs are not used in testing mode!` 是正常的
- 拓扑采集脚本内部对 4 个目标并行跑 `tracert`，一次大约需要 20 秒，所以这里等待时间正常会明显比 `ping` 长

### 5. 把 Telegraf 装成 Windows 服务

执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-telegraf-service.ps1
```

这个脚本会自动做两件事：

- 如果当前不是管理员，它会自我提权
- 如果服务不存在就安装，存在就直接重启

安装成功后可以查看：

```powershell
Get-Service telegraf
```

逐段解释：

- `Get-Service`
  - 查询 Windows 服务
- `telegraf`
  - 指定服务名

如果配置改过，比如新增 IP 或修改采样间隔，可以执行：

```powershell
Restart-Service telegraf
```

逐段解释：

- `Restart-Service`
  - 重启已有服务
- `telegraf`
  - 指定要重启的服务名

### 6. 部署 CGNAT 网关自动维护（方案 B）

运营商侧的 `CGNAT` 接入网关 IP 会随时间变化。如果一直 `ping` 一个已经失效的旧 IP，那一层的数据就没有意义。

这一步把“发现变化 → 更新配置 → 重载服务”整套做成自动的：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\setup-cgnat-automation.ps1
```

它会自动提权（需要管理员权限），然后做两件事：

1. 给 `telegraf` 服务的启动参数加上 `--watch-config poll`
   - 这样 `telegraf.conf` 一被改动，`Telegraf` 就会自动重新加载，不用手动 `Restart-Service`
   - Windows 上只支持 `poll` 模式，`notify` 模式不支持 Windows
2. 注册一个名为 `NetworkMonitor-UpdateCgnatHop` 的计划任务
   - 每天 `04:00` 执行一次 `update-cgnat-hop.ps1`
   - 以 `SYSTEM` 身份、最高权限运行

可以用下面两条命令确认结果：

```powershell
sc.exe qc telegraf
```

```powershell
schtasks /query /tn "NetworkMonitor-UpdateCgnatHop" /v /fo LIST
```

- 第一条看 `BINARY_PATH_NAME` 末尾有没有 `--watch-config poll`
- 第二条看任务状态和下次运行时间
- 注意：这个计划任务是以 `SYSTEM` 身份注册的，在普通（非管理员）终端里查它会报“拒绝访问”，需要在管理员终端里查看

也可以随时手动跑一次检测脚本，看看当前 `CGNAT` 网关有没有变：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\update-cgnat-hop.ps1
```

- 没变化时输出 `OK no change (...)`
- 有变化时输出 `CHANGED ... -> ...`，并同时改写 `telegraf.conf`

### 7. 打开 Grafana 看图

如果 provisioning 正常加载，应该能看到三个 dashboard：

- `Raw Network Overview`：总览页，多目标曲线与状态
- `Raw Network Single Target`：单目标详情页
- `Raw Network Topology`：路径拓扑页

如果 dashboard 没自动出现，常见处理方式有两种：

1. 重启 `Grafana`
2. 手动导入 JSON 文件

补充一个实测结论：

- Grafana 的 file provisioning 会跟随**已存在文件**的修改自动重新加载
- 但**新放进 `grafana/dashboards/` 的 JSON 文件**，实测不会立刻被发现，需要执行一次 `docker compose restart grafana` 才会加载进来

---

## `docker-compose.yml` 逐段解析

当前文件内容用于启动两个服务：`InfluxDB` 和 `Grafana`。

### `influxdb` 段

```yaml
influxdb:
  image: influxdb:2.7
```

解释：

- `influxdb`
  - compose 中的服务名
- `image: influxdb:2.7`
  - 使用 `InfluxDB 2.7` 镜像

```yaml
container_name: network-monitor-influxdb
restart: unless-stopped
```

解释：

- `container_name`
  - 指定固定容器名，方便排查
- `restart: unless-stopped`
  - 容器异常退出后自动重启
  - 手工停止时不自动拉起

```yaml
ports:
  - "8086:8086"
```

解释：

- 左边的 `8086`
  - Windows 主机端口
- 右边的 `8086`
  - 容器内部端口

所以访问 `http://127.0.0.1:8086` 时，实际上是访问到了容器里的 `InfluxDB`。

```yaml
environment:
  DOCKER_INFLUXDB_INIT_MODE: setup
  DOCKER_INFLUXDB_INIT_USERNAME: ${INFLUXDB_USERNAME}
  DOCKER_INFLUXDB_INIT_PASSWORD: ${INFLUXDB_PASSWORD}
  DOCKER_INFLUXDB_INIT_ORG: ${INFLUXDB_ORG}
  DOCKER_INFLUXDB_INIT_BUCKET: ${INFLUXDB_BUCKET}
  DOCKER_INFLUXDB_INIT_RETENTION: ${INFLUXDB_RETENTION}
  DOCKER_INFLUXDB_INIT_ADMIN_TOKEN: ${INFLUXDB_ADMIN_TOKEN}
```

解释：

- 这一组变量只在初始化时使用
- `${...}` 表示从 `.env` 读取对应变量

各字段含义：

- `INIT_MODE: setup`
  - 告诉容器第一次启动时做初始化
- `INIT_USERNAME`
  - 初始用户名
- `INIT_PASSWORD`
  - 初始密码
- `INIT_ORG`
  - 组织名
- `INIT_BUCKET`
  - 默认 bucket 名称
- `INIT_RETENTION`
  - 数据保留时间
- `INIT_ADMIN_TOKEN`
  - API token，`Telegraf` 和 `Grafana` 都会用到

重要提醒：

- 这些初始化变量只在第一次初始化空数据目录时生效
- 如果你只是删了容器，但保留了数据目录或 volume，后来改 `.env` 不一定会生效

```yaml
volumes:
  - influxdb-data:/var/lib/influxdb2:/var/lib/influxdb2
```

这行原本的写法比较怪。通常标准 compose 写法应为：

```yaml
- influxdb-data:/var/lib/influxdb2
```

但当前既然已经在用并正常跑着，先不动它更稳。后续如果要大整理，可再规范。

### `grafana` 段

```yaml
grafana:
  image: grafana/grafana:latest
```

解释：

- `grafana`
  - compose 中的服务名
- `grafana/grafana:latest`
  - 使用最新版 Grafana 镜像

```yaml
depends_on:
  - influxdb
```

解释：

- 启动 `Grafana` 前，先确保 `InfluxDB` 容器已启动
- 这里只保证启动顺序，不保证应用层一定完全就绪

```yaml
ports:
  - "3000:3000"
```

解释：

- 让主机可以通过 `http://127.0.0.1:3000` 打开 Grafana

```yaml
environment:
  GF_SECURITY_ADMIN_USER: ${GRAFANA_ADMIN_USER}
  GF_SECURITY_ADMIN_PASSWORD: ${GRAFANA_ADMIN_PASSWORD}
  INFLUXDB_ORG: ${INFLUXDB_ORG}
  INFLUXDB_BUCKET: ${INFLUXDB_BUCKET}
  INFLUXDB_ADMIN_TOKEN: ${INFLUXDB_ADMIN_TOKEN}
```

解释：

- 前两项是 Grafana 管理员用户名和密码
- 后三项是给 provisioning 文件做变量替换用的

```yaml
volumes:
  - ./grafana/data:/var/lib/grafana
  - ./grafana/provisioning:/etc/grafana/provisioning
  - ./grafana/dashboards:/var/lib/grafana/dashboards
```

解释：

- `./grafana/data`
  - 保存 Grafana 本地数据库和运行时状态
- `./grafana/provisioning`
  - 保存数据源和 dashboard provider 的自动加载配置
- `./grafana/dashboards`
  - 保存 dashboard JSON

这里也是这次排障中最关键的一组目录：

- 如果你把 `grafana/data` 删了，Grafana 会像新装一样重建状态
- 如果你把 `grafana/provisioning` 或 `grafana/dashboards` 删了，Grafana 就不会自动加载数据源和 dashboard

---

## `.env` 逐项解析

当前内容如下：

```env
INFLUXDB_USERNAME=admin
INFLUXDB_PASSWORD=12345678
INFLUXDB_ORG=home
INFLUXDB_BUCKET=network
INFLUXDB_RETENTION=30d
INFLUXDB_ADMIN_TOKEN=...

GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=12345678
```

各字段含义：

- `INFLUXDB_USERNAME`
  - InfluxDB 初始管理员用户名
- `INFLUXDB_PASSWORD`
  - InfluxDB 初始管理员密码
- `INFLUXDB_ORG`
  - 组织名，当前是 `home`
- `INFLUXDB_BUCKET`
  - bucket 名，当前是 `network`
- `INFLUXDB_RETENTION`
  - 数据保留期
- `INFLUXDB_ADMIN_TOKEN`
  - 给 `Grafana` 和 `Telegraf` 使用的 token
- `GRAFANA_ADMIN_USER`
  - Grafana 管理员用户名
- `GRAFANA_ADMIN_PASSWORD`
  - Grafana 管理员密码

注意：

- `telegraf/telegraf.conf` 里的 token 必须和 `.env` 保持一致
- 如果 `.env` 改了，但 InfluxDB 数据目录没清空，旧初始化状态可能仍然生效

---

## `telegraf/telegraf.conf` 逐段解析

这是整套系统的采集核心。

### `[agent]` 段

```toml
[agent]
  interval = "5s"
```

解释：

- `interval = "5s"`
  - `Telegraf` 每隔 5 秒采集一次
  - 这里是整套采样节奏的核心参数

```toml
  round_interval = true
```

解释：

- 让采样时间尽量对齐到整点节奏
- 比如更接近 `12:00:00`、`12:00:05`、`12:00:10`

```toml
  flush_interval = "5s"
  flush_jitter = "1s"
```

解释：

- `flush_interval = "5s"`
  - 每 5 秒向输出端写一次数据
- `flush_jitter = "1s"`
  - 给 flush 加一点随机抖动，避免所有写入都严格撞在同一时刻

```toml
  metric_batch_size = 1000
  metric_buffer_limit = 10000
```

解释：

- `metric_batch_size`
  - 每批次最多写多少条指标
- `metric_buffer_limit`
  - 输出暂时不可用时，本地最多缓存多少条

```toml
  precision = ""
```

解释：

- 让 `Telegraf` 自动决定时间精度

```toml
  debug = false
  quiet = false
  logfile = ""
```

解释：

- `debug = false`
  - 不开调试日志
- `quiet = false`
  - 保持正常日志输出
- `logfile = ""`
  - 不单独写文件，默认走服务或控制台输出

```toml
  hostname = "windows-raw-probe"
  omit_hostname = true
```

解释：

- `hostname` 虽然还写着，但因为 `omit_hostname = true`
- 所以最终不会把 `host` 标签写进数据
- 这是为了减少无意义标签

### `[[outputs.influxdb_v2]]` 段

```toml
[[outputs.influxdb_v2]]
  urls = ["http://127.0.0.1:8086"]
```

解释：

- 指定输出到本机映射出来的 `InfluxDB`
- 因为 `Telegraf` 跑在 Windows 主机，不在容器里，所以这里用 `127.0.0.1`

```toml
  token = "..."
  organization = "home"
  bucket = "network"
```

解释：

- `token`
  - 写入认证凭证
- `organization`
  - InfluxDB 组织名
- `bucket`
  - 写入的 bucket 名

### `[[inputs.ping]]` 段

```toml
[[inputs.ping]]
  # 分层探测目标，按“由内到外”的链路顺序排列
  urls = [
    "192.168.31.1",    # 小米 Redmi AX1800 路由 LAN，内网第一跳
    "192.168.1.1",     # 光猫管理地址，内网第二跳
    # "100.84.36.1",   # 旧运营商首跳（2026-09-29 部署时有效，现已不在路径上，保留备查）
    "100.69.56.1",     # @cgnat-hop 运营商 CGNAT 接入网关，当前运营商侧首跳（2026-10-31 实测生效；此行由 update-cgnat-hop.ps1 自动维护）
    # 运营商骨干跳点已不再纳入 ping 监测，原因见本节末尾说明
    # "222.72.237.93",  # 旧电信公网跳点（2026-09-29 部署时有效，现已无响应，保留备查）
    # "222.72.236.233", # 电信公网骨干跳点（2026-10-31 实测可响应，但 ECMP 漂移 + ICMP 限速，不适合监测）
    "223.5.5.5",       # 阿里公共 DNS
    "119.29.29.29",    # 腾讯 DNSPod 公共 DNS
    "8.8.8.8",         # Google 公共 DNS
    "1.1.1.1",         # Cloudflare 公共 DNS
  ]
```

解释：

- `urls`
  - 虽然字段名叫 `urls`，但这里也可以直接填 IP
- 这些就是被 `ping` 的目标列表，按“由内到外”的链路顺序排列，每个目标的含义：
  - `192.168.31.1`：小米 `Redmi AX1800` 路由 LAN 口，内网第一跳，用来判断“本机 → 路由”这一段是否正常
  - `192.168.1.1`：光猫管理地址，内网第二跳，用来判断“路由 → 光猫”这一段是否正常
  - `100.69.56.1`：运营商 `CGNAT` 接入网关（`100.64.0.0/10` 为运营商级 NAT 段），运营商侧第一跳，用来判断“光猫 → 运营商接入”这一段
  - `223.5.5.5`：阿里公共 DNS，公网目标（仅借用其稳定地址做 `ping`，不做 DNS 查询）
  - `119.29.29.29`：腾讯 DNSPod 公共 DNS，公网目标
  - `8.8.8.8`：Google 公共 DNS，公网目标
  - `1.1.1.1`：Cloudflare 公共 DNS，公网目标
- 说明：运营商侧的 `100.69.56.1` 会随运营商接入调整而变化。这一行带 `@cgnat-hop` 标记，由计划任务每天调用的 `update-cgnat-hop.ps1` 自动核对更新，不再需要人工替换；旧值会被改写成 `@cgnat-hop-old` 注释保留一行备查
- 骨干跳点为什么被移出：见上文「当前监控目标」里的「为什么不再监控运营商骨干跳点」一节

```toml
  count = 3
```

解释：

- 每轮采样对每个目标发送 3 个 ping
- 这样生成出来的平均值、最大值更稳定

```toml
  ping_interval = 1.0
```

解释：

- 一轮内部的 3 个 ping 包之间间隔 1 秒

```toml
  timeout = 1.0
```

解释：

- 每个 ping 等待单次响应的超时时间是 1 秒

```toml
  deadline = 5
```

解释：

- 一轮 ping 的总等待上限是 5 秒

```toml
  method = "exec"
  binary = "ping"
```

解释：

- `method = "exec"`
  - 使用系统自带的 `ping` 程序
- `binary = "ping"`
  - 指定调用的程序名就是 `ping`

在 Windows 上这通常比一些原始 socket 方案更省事。

```toml
  interface = ""
```

解释：

- 不强制指定网卡接口
- 由系统路由自行决定从哪个接口发包

```toml
  percentiles = [50, 95, 99]
```

解释：

- 额外计算 `p50`、`p95`、`p99`
- 当前 dashboard 里暂时没用上，但以后做更细的抖动分析有用

```toml
  name_override = "ping"
```

解释：

- 强制这组数据的 measurement 名字写成 `ping`
- 所以在 `InfluxDB` 查询里你会频繁看到：

```flux
r._measurement == "ping"
```

### `[[inputs.exec]]` 段

这一段是后来新增的，专门用来采集“路径拓扑”。

```toml
[[inputs.exec]]
  commands = [['powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', 'd:\trae_works\20260926\network-monitor\telegraf\topology-probe.ps1']]
  interval = "5m"
  timeout = "120s"
  data_format = "influx"
```

逐段解释：

- `commands`
  - 要执行的命令，写成“数组套数组”的形式
  - 外层数组 = 可以配多条命令
  - 内层数组 = 一条命令的参数列表（命令名 + 每个参数各占一项）
  - 这种写法是 `Telegraf 1.39` 之后推荐的形式；老的“一整行字符串”写法已被标记为 deprecated
  - 这里调用 `powershell.exe` 去跑 `topology-probe.ps1`
  - `-NoProfile`
    - 不加载用户的 PowerShell 配置文件，避免外部脚本干扰
  - `-NonInteractive`
    - 不进入交互模式
  - `-ExecutionPolicy Bypass`
    - 只对本次执行临时绕过脚本策略
  - `-File`
    - 后面跟要执行的脚本路径
- `interval = "5m"`
  - 这个插件每 5 分钟跑一次
  - 注意：`tracert` 一次要 20 秒左右，跑太频繁没意义，路径也不会 5 秒就变
- `timeout = "120s"`
  - 单次执行的最长等待时间
  - 默认只有 5 秒，对 `tracert` 完全不够，必须放大
- `data_format = "influx"`
  - 告诉 `Telegraf`：脚本输出的是 InfluxDB line protocol 文本
  - 这样 `Telegraf` 就会直接解析，而不是当成别的格式

它写入的数据 measurement 是 `traceroute`，和 `ping` 分开存，互不干扰。

顺便记一个“明确不想做的事”：

- 不再用 `ping` 去监控运营商骨干跳点（`222.72.x` / `61.152.x` / `61.172.x` 这类）
- 原因见上文「为什么不再监控运营商骨干跳点」
- 如果只是想看路径，用本节的 `tracert` 拓扑采集就够了；做质量监控，用稳定的 DNS 目标和 CGNAT 网关

---

## PowerShell 脚本逐段解析

### `scripts/test-telegraf.ps1`

脚本结构很简单，目的是测试配置，而不是安装服务。

关键内容：

```powershell
param(
    [string]$TelegrafExe = "...",
    [string]$ConfigPath = "..."
)
```

解释：

- 允许你在调用脚本时传入：
  - `TelegrafExe`
  - `ConfigPath`
- 不传时就使用默认路径

```powershell
$ErrorActionPreference = "Stop"
```

解释：

- 遇到错误就直接中断
- 避免脚本带着错误继续往后跑

```powershell
if (-not (Test-Path $TelegrafExe)) { ... }
if (-not (Test-Path $ConfigPath)) { ... }
```

解释：

- 在执行前先检查文件是否存在
- 不存在就明确报错

```powershell
Write-Host "Testing Telegraf config..."
Write-Host "& '$TelegrafExe' --config '$ConfigPath' --test"
```

解释：

- 第一行告诉你脚本正在做什么
- 第二行把即将执行的真实命令打印出来，方便排查

```powershell
& $TelegrafExe --config $ConfigPath --test
```

解释：

- 真正执行测试命令

### `scripts/install-telegraf-service.ps1`

这个脚本比测试脚本多了“自我提权”和“安装服务”逻辑。

#### 自我提权段

```powershell
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal   = New-Object Security.Principal.WindowsPrincipal($currentUser)
$isAdmin     = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
```

解释：

- 取当前用户
- 包装成 WindowsPrincipal
- 判断当前会话是不是管理员

```powershell
if (-not $isAdmin) {
    ...
    Start-Process -FilePath "powershell.exe" `
                  -ArgumentList $argList `
                  -Verb RunAs `
                  -Wait
    exit
}
```

解释：

- 如果当前不是管理员
- 就重新启动一个管理员权限的 PowerShell 来再次运行自己
- `-Verb RunAs` 会触发 UAC 提权
- `-Wait` 会等待提权后的进程跑完

#### 安装服务段

```powershell
$service = Get-Service -Name telegraf -ErrorAction SilentlyContinue
```

解释：

- 尝试读取名为 `telegraf` 的服务
- 如果没有，不要把错误打爆终端

```powershell
if ($null -eq $service) {
    & $TelegrafExe --service install --config $ConfigPath
}
```

解释：

- 服务不存在时，执行 `Telegraf` 自带的安装服务命令

```powershell
Restart-Service -Name telegraf -ErrorAction SilentlyContinue
Start-Service -Name telegraf
Get-Service -Name telegraf
```

解释：

- 尝试先重启
- 再确保启动
- 最后把当前服务状态打印出来

### `scripts/find-first-hop.ps1`

这个脚本的目标不是自动帮你决定最终结论，而是把 `tracert` 结果结构化，方便你判断哪一跳最像运营商第一跳。

关键逻辑如下：

```powershell
$lines = tracert -d $Target
```

解释：

- 执行 `tracert -d`
- `-d` 表示不做 DNS 反查，只显示 IP，更适合排网络层问题

```powershell
$ipv4Pattern = '\b(?:\d{1,3}\.){3}\d{1,3}\b'
```

解释：

- 这是一个匹配 IPv4 的正则表达式

```powershell
if ($line -match '^\s*(\d+)\s+') {
```

解释：

- 只处理看起来像“第 N 跳”的行

```powershell
$ipMatch = [regex]::Match($line, $ipv4Pattern)
```

解释：

- 从这一行里提取 IP

```powershell
$hops += [pscustomobject]@{
    Hop = $hopNumber
    IP  = $ipMatch.Value
}
```

解释：

- 把结果组织成结构化对象，而不是纯文本

最后它会打印一张表，并给出简单解读提示。

### `scripts/update-cgnat-hop.ps1`

这个脚本负责“发现 `CGNAT` 网关变化并改配置”，不需要管理员权限。

它做的事情：

1. 对 `223.5.5.5` 跑一次 `tracert -d -4`
2. 从每一跳里找第一个落在 `100.64.0.0/10` 段的地址，就是当前 `CGNAT` 网关
3. 找到 `telegraf.conf` 里带 `@cgnat-hop` 标记、且没有被注释掉的那一行，读出它当前的 IP
4. 两者不一致时原地改写这一行：
   - 原值那一行变成 `@cgnat-hop-old` 注释（只保留最近一条，滚动替换）
   - 新值写进带 `@cgnat-hop` 标记的活动行，原来的中文注释原样保留

关键正则：

```powershell
$cgnatRe = '^100\.(?:6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.'
```

- 匹配 `100.64.x.x` 到 `100.127.x.x`
- 也就是 `100.64.0.0/10` 这一段
- 这段是运营商级 NAT（`CGNAT`）保留地址，用户侧出口网关基本都落在这里

几个细节：

- 脚本刻意保持纯 ASCII
  - 它不自己拼中文注释，而是“读出原行 → 只替换引号里的 IP → 把剩下的部分原样接回去”
  - 所以配置里的中文注释既不会丢，也不受控制台代码页影响
- 读文件时先检测有没有 UTF-8 BOM，写回时保持一致，避免把编码改坏
- 没找到 `@cgnat-hop` 标记行、或 `tracert` 没找到 `CGNAT` 段地址时，脚本只写日志、不改配置，绝不写坏文件
- 每次运行都会往 `scripts/logs/cgnat-hop.log` 追加一行带时间戳的日志

### `scripts/setup-cgnat-automation.ps1`

这是“方案 B”的一次性部署脚本，需要管理员权限，会先自我提权（和 `install-telegraf-service.ps1` 同一套逻辑）。

它做两件事。

第一件，给服务加上配置自动重载：

```powershell
$newPath = $currentPath.Trim() + ' --watch-config poll'
& sc.exe config $ServiceName 'binPath=' $newPath
```

- 读出 `telegraf` 服务当前的启动命令行
- 在末尾补上 `--watch-config poll`
- 写回去并重启服务
- 幂等：如果已经带 `--watch-config`，就跳过这一步

第二件，注册每日检测的计划任务：

```powershell
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $UpdateScript)
$trigger = New-ScheduledTaskTrigger -Daily -At $DailyAt
$taskPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $taskPrincipal -Settings $settings -Force | Out-Null
```

- 建一个每天固定时间触发的任务
- 以 `SYSTEM` 最高权限运行，不需要保存用户密码
- `-Force` 让重复执行变成“覆盖更新”，不会报“任务已存在”

实测验证过的行为：

- 手动把 `telegraf.conf` 里的 `@cgnat-hop` 行改成错误 IP 后，不用重启服务，`Telegraf` 会在几秒内自动重载，`InfluxDB` 里随即出现对新 IP 的 `ping` 数据
- 再运行 `update-cgnat-hop.ps1` 把 IP 改回正确值，同样是几秒内自动生效，旧 IP 的数据随即停止

也就是说整条链路“改配置 → 自动重载 → 数据跟着变”是通的。

### `telegraf/topology-probe.ps1`

这是路径拓扑的采集脚本，和上面几个“给人看”的脚本不同，它的输出是**给机器读**的。

它的定位：

- 输入：无（目标列表写死在脚本里）
- 输出：一堆 InfluxDB line protocol 文本，直接打到标准输出
- 调用方：`Telegraf` 的 `inputs.exec`

脚本里定义的目标就是那 4 个公网地址：

```powershell
$targets = @('223.5.5.5', '119.29.29.29', '8.8.8.8', '1.1.1.1')
```

核心逻辑解释：

```powershell
$lines = & tracert -d -4 -h $MaxHops -w $WaitMs $Target
```

- `tracert`
  - Windows 自带的路由追踪命令
- `-d`
  - 不做 DNS 反查，只显示 IP，避免被 DNS 拖慢、也更干净
- `-4`
  - 强制走 IPv4
- `-h $MaxHops`
  - 最多追踪多少跳，默认 16
- `-w $WaitMs`
  - 每一跳的等待毫秒数，默认 800

```powershell
$hopLine = '^\s*(\d+)\s+(.*)$'
```

- 用来识别“第 N 跳”这种行
- 第一个捕获组是跳数

```powershell
$ipRe = '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'
```

- 用来从行里抠出 IPv4 地址
- 抠不到就说明这一跳没响应，地址记为 `*`

```powershell
$msRe = '(\d+)\s*(?:ms|\u6BEB\u79D2)'
```

- 用来提取延迟数值
- 大部分情况 `tracert` 显示 `ms`
- 但“小于 1 毫秒”在中文 Windows 上显示成 `<1 毫秒`
- 所以这里同时匹配 `ms` 和 `毫秒`（`\u6BEB\u79D2` 就是“毫秒”的 Unicode 转义）
- 这是一个实测踩过的坑：只匹配 `ms` 的话，所有“小于 1 毫秒”的跳点延迟都会被错记成无响应
- 脚本刻意保持纯 ASCII，中文一律用 `\uXXXX` 转义写，避免 Windows 控制台代码页导致的 PowerShell 解析问题

输出格式：

```text
traceroute,target=8.8.8.8,hop=3,addr=100.69.56.1 rtt_ms=4.33
```

对应含义：

- measurement：`traceroute`
- tags：`target`（目标）、`hop`（第几跳）、`addr`（该跳的 IP，无响应时为 `*`）
- field：`rtt_ms`（该跳三次探测的平均延迟；无响应时为 `-1`）

为什么 `addr` 用 tag 而不是 field：

- 拓扑表要做的是“每个目标的每一跳取最新一条”
- 用 `group(columns: ["target", "hop"]) |> last()` 就能一跳一行
- 如果 `addr` 是 field，在 Flux 里 `pivot` 会因为 `_value` 同时是字符串和浮点数而报类型冲突

脚本还会并行跑 4 个目标：

```powershell
$jobs = foreach ($t in $targets) {
    Start-Job -ScriptBlock $worker -ArgumentList $t, $MaxHops, $WaitMs
}
```

- 每个目标起一个后台 Job，4 条 `tracert` 同时跑
- 否则串行跑 4 条会明显更慢
- 外面还有一个总超时（默认 90 秒）兜底，避免某个 Job 卡死拖垮整次采集

---

## Grafana provisioning 文件解析

### `grafana/provisioning/datasources/influxdb.yml`

这个文件负责让 `Grafana` 自动创建 `InfluxDB` 数据源。

关键字段：

```yaml
datasources:
  - name: InfluxDB-Network
    uid: influxdb-network
```

解释：

- `name`
  - Grafana 页面上显示的数据源名字
- `uid`
  - dashboard JSON 会通过这个 UID 引用数据源

```yaml
type: influxdb
access: proxy
url: http://influxdb:8086
```

解释：

- `type: influxdb`
  - 表示数据源类型
- `access: proxy`
  - 由 Grafana 服务端代理访问数据源
- `url: http://influxdb:8086`
  - 这里用的是容器网络里的服务名 `influxdb`
  - 因为 Grafana 自己也在 Docker 里

```yaml
jsonData:
  version: Flux
```

解释：

- 使用 Flux 作为查询语言

```yaml
organization: ${INFLUXDB_ORG}
defaultBucket: ${INFLUXDB_BUCKET}
```

解释：

- 这些值从 `docker-compose.yml` 注入的环境变量中替换

```yaml
secureJsonData:
  token: ${INFLUXDB_ADMIN_TOKEN}
```

解释：

- 认证 token
- 放在 `secureJsonData` 是因为这是敏感字段

### `grafana/provisioning/dashboards/default.yml`

这个文件负责让 `Grafana` 自动扫描 dashboard JSON。

关键字段：

```yaml
providers:
  - name: Raw Network
    folder: Raw Network
    type: file
```

解释：

- `name`
  - provider 名称
- `folder`
  - 在 Grafana 页面中展示成 `Raw Network` 文件夹
- `type: file`
  - 表示从文件系统加载 dashboard

```yaml
options:
  path: /var/lib/grafana/dashboards
```

解释：

- 这个路径就是 compose 里挂进去的 `./grafana/dashboards`

---

## Dashboard 内容说明

### `Raw Network Overview`

这是总览页，适合一眼看多个目标。

当前包含：

- `平均延迟：整体是否变慢`
  - 看整体响应时间是否抬高
- `丢包率：是否出现瞬断`
  - 看是否有短时丢包
- `最大延迟：是否有尖刺抖动`
  - 看是否有卡顿尖刺
- `最近 5 分钟状态时间线`
  - 按丢包率分级着色，直观看每个目标是正常、丢包还是离线
- `最近异常次数排行`
  - 统计当前时间范围内每个目标出现丢包的样本次数

### `Raw Network Single Target`

这是单目标详情页，适合聚焦某一个 IP。

顶部有变量：

- `目标 IP`

选中某个 IP 后，下面 4 张图只看它自己的：

- 平均延迟
- 丢包率
- 最大延迟
- 最近 5 分钟状态

### `Raw Network Topology`

这是路径拓扑页，回答的问题是：

- 我的流量到 `223.5.5.5` / `119.29.29.29` / `8.8.8.8` / `1.1.1.1`，**具体经过哪些设备**

页面内容：

- 顶部变量：`目标`
  - 默认 `All`，一次看 4 个目标
  - 也可以单选某一个目标只看它
- `最近探测时间`：最近一次 `traceroute` 采集的写入时间
  - 正常应该在 5 分钟以内
  - 超过 10 分钟没更新，说明采集侧可能出问题了
- `路径拓扑`：表格
  - 列：`目标` / `跳数` / `设备地址` / `平均延迟`
  - 按 `目标 → 跳数` 排序，跳数从小到大就是“由内到外”的路径顺序
  - `设备地址` 为 `*`，表示该跳没有响应
  - `平均延迟` 为 `超时 / 无响应`，表示该跳没回包，和 `*` 一一对应

使用提醒：

- `*` 不代表链路坏了
  - 骨干路由器普遍对 `ICMP` 限速甚至不回，这是正常现象
- 这张表取的是**所选时间范围内最后一次**采集的结果
  - 想看历史上某次快照，把右上角时间范围调到那个时刻附近即可

---

## InfluxDB 中的数据长什么样

当前主要使用的是 `Telegraf ping` 插件写入的数据。

measurement 名称是：

```text
ping
```

常见字段包括：

- `average_response_ms`
  - 平均延迟
- `maximum_response_ms`
  - 最大延迟
- `minimum_response_ms`
  - 最小延迟
- `percent_packet_loss`
  - 丢包率
- `result_code`
  - 返回码，`0` 表示成功，非 `0` 表示失败

重要提醒：

- `result_code` 只在 `Telegraf` 调用系统 `ping` 程序本身报错时才会非 `0`
- 目标完全不通（丢包 `100%`）时，`result_code` 依然是 `0`
- 所以判断是否卡顿或离线必须依赖 `percent_packet_loss`，不能只看 `result_code`

常见标签包括：

- `url`
  - 被探测的目标 IP

当前已经把 `host` 等冗余标签去掉了，所以数据会更干净。

### `traceroute`：路径拓扑数据

这是拓扑采集脚本写入的第二类数据。

measurement 名称是：

```text
traceroute
```

标签（tags）：

- `target`
  - 这次追踪的目标 IP（`223.5.5.5` / `119.29.29.29` / `8.8.8.8` / `1.1.1.1`）
- `hop`
  - 第几跳，从 `1` 开始
- `addr`
  - 这一跳响应回来的 IP
  - 没有响应时是 `*`

字段（field）：

- `rtt_ms`
  - 该跳三次探测的平均延迟，单位毫秒
  - 没有响应时是 `-1`

一行数据的例子：

```text
traceroute,target=8.8.8.8,hop=3,addr=100.69.56.1 rtt_ms=4.33
```

读法：

- 到 `8.8.8.8` 的第 `3` 跳，设备地址 `100.69.56.1`，平均延迟 `4.33 ms`

---

## Flux 查询语法说明

Grafana 现在是通过 Flux 来查询 `InfluxDB`。

下面按常用语法解释。

### 1. `from(bucket: "network")`

含义：

- 从 `network` 这个 bucket 开始查询数据

### 2. `|> range(start: ..., stop: ...)`

含义：

- 限制时间范围

例如：

```flux
|> range(start: v.timeRangeStart, stop: v.timeRangeStop)
```

表示：

- 使用 Grafana 当前页面时间选择器里的起止时间

### 3. `|> filter(fn: (r) => ...)`

含义：

- 过滤行

例如：

```flux
|> filter(fn: (r) => r._measurement == "ping" and r._field == "average_response_ms")
```

表示：

- 只要 measurement 为 `ping`
- 且字段名为 `average_response_ms` 的记录

### 4. `|> group(columns: ["url"])`

含义：

- 按 `url` 分组

这样做的效果是：

- 每个目标 IP 分成一条单独的 series
- 不会全部揉成一条 `A-series`

### 5. `|> aggregateWindow(every: ..., fn: ..., createEmpty: false)`

含义：

- 按固定时间窗口聚合

例如：

```flux
|> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
```

解释：

- `every: v.windowPeriod`
  - 让 Grafana 根据时间范围和图宽自动决定窗口大小
- `fn: mean`
  - 窗口内取平均值
- `createEmpty: false`
  - 没数据的窗口不强行补空点

### 6. `|> map(fn: (r) => ...)`

含义：

- 对每一行做转换

比如状态图里我们把原始丢包率转成中文分级：

```flux
|> map(fn: (r) => ({ _time: r._time, url: r.url, _value: if r._value >= 100.0 then "离线" else if r._value > 80.0 then "严重丢包" else if r._value > 50.0 then "重度丢包" else if r._value > 30.0 then "中度丢包" else if r._value > 0.0 then "轻微丢包" else "正常" }))
```

解释：

- 保留时间 `_time`
- 把丢包率按区间转成中文分级状态
- 保留 `url`

### 7. `|> keep(columns: [...])`

含义：

- 只保留指定列

这个操作常用来减少多余列，避免 Grafana 渲染时碰到奇怪的数据结构问题。

### 8. `|> sort(columns: [...], desc: true)`

含义：

- 按指定列排序

例如异常次数排行表里，会按 `_value` 降序排序。

### 9. `|> sum()`

含义：

- 把每个分组内的值求和

异常次数排行里的逻辑就是：

- 先把正常映射成 `0`
- 异常映射成 `1`
- 再按 `url` 分组求和
- 最终得到“这个时间范围里一共异常了多少次”

### 10. `|> last()`

含义：

- 每个分组只保留时间上最新的一条

拓扑表靠它实现“每个目标的每一跳只取最近一次”：

```flux
|> group(columns: ["target", "hop"])
|> last()
```

- 先按 `目标 + 跳数` 分组
- 再取每组最新一条
- 结果就是“一跳一行”，且是该跳最新的地址和延迟

### 11. `|> rename(columns: {...})`

含义：

- 给列改名

例如把 InfluxDB 固定的 `_value` 列改成更直观的名字：

```flux
|> rename(columns: {_value: "rtt_ms"})
```

- 这样表格里显示的列名就是 `rtt_ms`，而不是 `_value`

---

## 本项目当前使用的几类查询

### 平均延迟

```flux
from(bucket: "network")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "ping" and r._field == "average_response_ms")
  |> group(columns: ["url"])
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
  |> yield(name: "mean")
```

解释：

- 查 `ping`
- 取平均延迟字段
- 每个 `url` 单独成线
- 每个窗口再做一次平均

### 丢包率

```flux
from(bucket: "network")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "ping" and r._field == "percent_packet_loss")
  |> group(columns: ["url"])
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
  |> yield(name: "mean")
```

解释：

- 和平均延迟类似
- 只是字段换成 `percent_packet_loss`

### 最大延迟

```flux
from(bucket: "network")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "ping" and r._field == "maximum_response_ms")
  |> map(fn: (r) => ({ _time: r._time, _value: float(v: r._value), url: r.url }))
  |> group(columns: ["url"])
  |> aggregateWindow(every: v.windowPeriod, fn: max, createEmpty: false)
  |> yield(name: "max")
```

解释：

- 这里额外做了 `float(v: r._value)`
- 这是为了让 Grafana 拿到更统一的数值类型
- 之前总览页在多目标展示时遇到过 `arrow/array: index out of range`
- 现在这版是为绕开该问题做过清理后的写法

### 状态时间线

```flux
from(bucket: "network")
  |> range(start: -5m)
  |> filter(fn: (r) => r._measurement == "ping" and r._field == "percent_packet_loss")
  |> map(fn: (r) => ({ _time: r._time, url: r.url, _value: if r._value >= 100.0 then "离线" else if r._value > 80.0 then "严重丢包" else if r._value > 50.0 then "重度丢包" else if r._value > 30.0 then "中度丢包" else if r._value > 0.0 then "轻微丢包" else "正常" }))
  |> group(columns: ["url"])
  |> aggregateWindow(every: 5s, fn: last, createEmpty: false)
  |> yield(name: "状态")
```

解释：

- 查最近 5 分钟
- 取 `percent_packet_loss` 丢包率
- 按区间转成中文分级状态
- 每个 `url` 单独成一行
- 每 5 秒窗口取最后一个状态

### 异常次数排行

```flux
from(bucket: "network")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "ping" and r._field == "percent_packet_loss")
  |> map(fn: (r) => ({ r with _value: if r._value > 0.0 then 1 else 0 }))
  |> group(columns: ["url"])
  |> sum()
  |> keep(columns: ["url", "_value"])
  |> sort(columns: ["_value"], desc: true)
```

解释：

- 没有丢包记成 `0`
- 出现丢包记成 `1`
- 按目标分组后求和
- 和越大，代表这段时间内出现丢包的样本越多

### 路径拓扑

```flux
from(bucket: "network")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "traceroute" and r._field == "rtt_ms")
  |> filter(fn: (r) => r.target =~ /^${target:regex}$/)
  |> group(columns: ["target", "hop"])
  |> last()
  |> keep(columns: ["target", "hop", "addr", "_value"])
  |> rename(columns: {_value: "rtt_ms"})
  |> sort(columns: ["target", "hop"])
```

逐段解释：

- `r._measurement == "traceroute"`
  - 只看路径拓扑这份数据
- `r.target =~ /^${target:regex}$/`
  - 用 Grafana 顶部的 `目标` 变量过滤
  - `${target:regex}` 会把变量值拼成正则
  - 变量选 `All` 时等价于 `^.*$`，即不过滤
- `group(columns: ["target", "hop"]) |> last()`
  - 每个目标的每一跳只取最新一条
- `keep(columns: [...])`
  - 只留下表格要显示的 4 列
  - 顺便把 `_time` 等无关列丢掉
- `rename(columns: {_value: "rtt_ms"})`
  - 把值列改名为 `rtt_ms`
- `sort(columns: ["target", "hop"])`
  - 先按目标、再按跳数排序

---

## 这套图应该怎么看

### 平均延迟

看整体是否变慢。

如果：

- 路由器和光猫正常
- 外网目标整体升高

通常更像运营商或更远端链路问题。

### 丢包率

最适合解释“为什么游戏突然卡断”。

如果某层突然丢包，即使平均延迟不高，游戏也可能瞬断。

### 最大延迟

最适合看尖刺。

如果平均值不高，但最大延迟经常冲高，就说明网络有抖动尖刺。

### 最近 5 分钟状态时间线

只回答一个问题：

- 这个 IP 在这段时间里到底通不通、卡不卡

颜色按丢包率分级：

- `正常`（绿色）：丢包 `0%`
- `轻微丢包`（黄色）：丢包 `0-30%`
- `中度丢包`（橙色）：丢包 `30-50%`
- `重度丢包`（深橙）：丢包 `50-80%`
- `严重丢包`（红色）：丢包 `>80%`
- `离线`（深红）：丢包 `100%`
- `无数据`（灰色）：该时间片没有采到数据

### 最近异常次数排行

快速告诉你：

- 当前时间范围里谁最不稳定

这个表不是严格的“网络事件统计”，而是“丢包采样点统计”（丢包率大于 `0` 的样本数）。

### 路径拓扑

用来回答“我的包到底走了哪条路”。

看的时候注意几点：

- 跳数从小到大，就是由内到外的顺序
- 前几跳应该稳定是：`路由 → 光猫 → CGNAT 网关`
- 中间大量的 `*` 是正常现象，不代表断了
- 真正有意义的是：**同一跳在不同时间的地址有没有变化**
  - 稳定不变：路径稳定
  - 频繁变化：说明有 `ECMP` 负载分担，路径本来就在轮换

---

## 常见问题

### 1. `docker compose up -d` 之后改了 `.env`，为什么账号或 token 没变

因为初始化参数通常只在第一次空数据目录启动时生效。

如果你：

- 删了容器
- 但没删 `InfluxDB` 或 `Grafana` 的数据目录

那么旧状态可能还在。

### 2. Grafana 左侧能进来，但 `Dashboards` 里没有内容

先检查：

- `grafana/provisioning` 目录是否还在
- `grafana/dashboards` 目录是否还在

这两类静态配置如果被删掉，自动加载就会失效。

### 3. 状态图里为什么以前会出现 `<1`、`result_code`、`host`

这些都属于历史版本里偏底层的显示方式。

当前版本已经做过精简：

- `host` 等冗余标签不再继续写入
- 状态图不再依赖 `result_code`，改成按丢包率分级：
  - `正常`
  - `轻微丢包 / 中度丢包 / 重度丢包 / 严重丢包`
  - `离线`
  - `无数据`

### 4. 总览页“最大延迟”为什么之前会偶发 `arrow/array index out of range`

这是 `Grafana + Flux` 在处理返回数据结构时的兼容问题，不是 `Telegraf` 没采到数据。

当前已经通过更干净的 Flux 返回结构做过规避。

---

## 后续可以继续扩展什么

当前只做了“原始网络质量”第一阶段，故意保持简单：

- 质量监控：只做 `ICMP ping`
- 路径观测：只做 `tracert`（每 5 分钟一次）
- 不做 HTTP 探测
- 不做 DNS 查询耗时
- 不做 TCP 端口探测
- 不做 Clash 代理链路体验监控

后面如果要做第二阶段，可以继续加：

- 游戏服务器探测
- `Clash` 节点体验监控
- HTTP 可达性
- DNS 解析耗时
- 路由器 SNMP
- 路由器 CPU、内存、接口流量、重拨记录

---

## 最后建议

在长期运行前，至少确认以下几件事：

- `.env` 里的密码和 token 已改成自己的值
- `telegraf/telegraf.conf` 里的 token 和 `.env` 一致
- `Telegraf` 服务已启动
- Grafana 里总览页和单目标页都能正常出图

如果后面继续改配置，最常用的操作就是这几个：

```powershell
docker compose up -d
docker compose restart grafana
powershell -ExecutionPolicy Bypass -File .\scripts\test-telegraf.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\update-cgnat-hop.ps1
Get-Service telegraf
```

注意：

- 因为服务已经开了 `--watch-config poll`，改完 `telegraf.conf` **不需要**再手动 `Restart-Service telegraf`，`Telegraf` 会自己重载
- 只有在改服务的启动参数、或者换 `telegraf.exe` 路径这类情况，才需要重启服务
- `update-cgnat-hop.ps1` 平时由计划任务每天自动跑，这里列出来只是为了需要时手动执行

把它们记住，后续维护会轻松很多。
