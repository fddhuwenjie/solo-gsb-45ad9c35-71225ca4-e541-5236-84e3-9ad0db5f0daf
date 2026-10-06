# 木构件修复验收 API

仅用 **Python 标准库**（`http.server` + `sqlite3`）实现的木构件修复验收服务。
登记固定支承点、承重构件（含最低试载值）、榫卯连接、临时支撑与替换件；
按递增工序号提交拆卸 / 安装 / 试载 / 卸撑回执；每个工序重建当前连接图并做结构校验；
卸撑完成后可固化不可改写的验收快照。
修复工序也可先整份核对再执行：`POST /plan/preview` 对整份工序清单逐步预演并签发
确认凭据，`POST /plan/confirm` 携带原清单与凭据在一次写事务中复核执行整单。

## 启动

```bash
docker compose up --build
```

服务端口：**8080**（宿主机）→ 容器 8080。SQLite 数据持久化在命名卷 `timber-data`（容器内 `/data/app.db`）。

本地无 Docker 时也可直接运行：`python3 app.py`（监听 8080，数据在 `./data/app.db`；
可用环境变量 `APP_PORT`、`APP_DB` 覆盖）。

## 验收规则

- **工序递增**：`POST /steps` 的 `seq` 必须等于上一条已接受回执 +1，跳号整步拒绝。
- **连接在位判定**：榫卯连接/临时支撑只有**自身在位且两端构件均实际在位**
  （固定支承点恒在位）才参与施工与永久连通性判断。为尚未安装的替换件预登记的
  默认在位榫卯只是"允许端点组合"，在替换件实际安装前沿路不生效；该规则在重建
  连接图时实时计算，数据库中已登记的同类记录同样遵循，无需迁移。
- **施工中可达性**：每个改变连接图的工序提交后、以及试载时重建连接图——每个在位
  承重构件必须能经**在位连接或临时支撑**抵达某个固定支承点，否则整步回滚。
- **卸撑**：卸除临时支撑后，每个在位承重构件必须**仅凭永久连接**抵达支承点，且每个构件
  都有在**当前连接状态版本**下通过、载荷不低于其 `min_load` 的试载记录。
- **连接状态版本**：永久连接图每次变化（装/拆连接、拆/装构件）版本 +1；试载记录当时版本，
  图一变旧试载即失效。临时支撑的搭设/卸除不影响版本。
- **改接限制**：安装连接只允许使用事先登记的端点组合（`POST /connections` 登记的 id）。
- **整步拒绝**：跳号、端点不在位、可达性或卸撑条件不满足时返回 409，
  响应含 `first_affected_component`（首个受影响构件），已有回执与状态不变。
- **快照**：所有临时支撑卸除且校验通过后可 `POST /snapshots` 固化；快照只增不改，
  后续修复工序不会改写旧快照。
- **施工预案（预演）**：`POST /plan/preview` 按现有单步字段提交工序清单
  （`seq` 可省略，自动从末条回执后连续编号），在同一事务内逐步套用同一套传力路径
  与试载规则——后一步能看到前一步带来的支撑、连接版本和试载变化。成功返回每步
  预计结果与确认凭据（凭据绑定清单、当前登记与工序状态）；失败指出出错工序及原有
  错误。预演整体回滚，不留下任何改动。
- **预案确认（一次执行）**：`POST /plan/confirm` 携带原清单与凭据；预演后登记或
  工序状态有变化即拒绝（`plan_stale`）。否则在一次写事务中复核整单，全部成功才
  保存并返回按序回执；任一步失败指出该步并回滚整单新增的工序、连接版本、临时支撑
  状态及试载，旧回执与验收快照不变。

## API 一览

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/supports` | 登记固定支承点 `{id, name}` |
| POST | `/components` | 登记承重构件 `{id, name, min_load}`（初始在位） |
| POST | `/replacements` | 登记替换件 `{id, name, min_load}`（初始不在位） |
| POST | `/connections` | 登记榫卯连接 `{id, a, b, in_place?}`（默认 true；改接预留组合传 false） |
| POST | `/temp-supports` | 登记临时支撑 `{id, a, b, in_place?}`（默认 false） |
| POST | `/steps` | 提交工序回执（见下） |
| POST | `/plan/preview` | 施工预案预演：整单模拟，返回每步预计结果与确认凭据（不留改动） |
| POST | `/plan/confirm` | 施工预案确认：凭据有效且状态未变时一次写事务执行整单，返回按序回执 |
| GET | `/steps`、`/steps/{seq}` | 查询各工序回执与结果 |
| GET | `/state` | 当前连接图、各构件可达性与最近试载 |
| POST | `/snapshots` | 卸撑完成后固化验收快照 |
| GET | `/snapshots`、`/snapshots/{id}` | 查询快照 |
| GET | `/supports` `/components` `/replacements` `/connections` `/temp-supports` | 登记簿查询 |
| GET | `/health` | 健康检查 |

### 工序回执格式（`POST /steps`）

```jsonc
// 搭设临时支撑
{"seq": 1, "action": "install", "target": "temp_support", "id": "T1"}
// 拆卸构件（联动卸下依附的在位连接与临时支撑）
{"seq": 2, "action": "disassemble", "target": "component", "id": "C2"}
// 拆卸单条连接
{"seq": 2, "action": "disassemble", "target": "connection", "id": "J2"}
// 安装替换件，并同步安装其已登记连接（端点组合须事先登记）
{"seq": 3, "action": "install", "target": "replacement", "id": "R2", "connections": ["J3", "J4"]}
// 试载：记录载荷，是否通过 = load >= 构件 min_load
{"seq": 4, "action": "test_load", "component": "C1", "load": 12}
// 卸撑
{"seq": 6, "action": "remove_support", "id": "T1"}
```

### 施工预案格式（`POST /plan/preview` → `POST /plan/confirm`）

```jsonc
// 预演：steps 为工序清单，字段与单步相同；seq 可省略，
// 自动从末条回执后连续编号（如末条回执为 6，则清单依次为 7、8、…）
{"steps": [
  {"action": "install", "target": "temp_support", "id": "T1"},
  {"action": "disassemble", "target": "component", "id": "C2"},
  {"action": "install", "target": "replacement", "id": "R2", "connections": ["J3", "J4"]},
  {"action": "test_load", "component": "C1", "load": 12},
  {"action": "test_load", "component": "R2", "load": 9.5},
  {"action": "remove_support", "id": "T1"}
]}
//   → 200 {"ok": true, "base_seq": 6, "base_version": 2,
//          "steps": [每步预计结果], "credential": "v1.<凭据>"}
//   预演整体回滚：工序、连接版本、临时支撑、试载均不落库

// 确认：携带原清单与凭据，一次写事务复核执行整单
{"steps": [与预演完全相同的清单], "credential": "v1.<凭据>"}
//   → 201 {"ok": true, "receipts": [seq 7..12 按序回执]}
//   预演后登记或工序有变化 → 409 plan_stale；清单被改动 → 409 plan_mismatch
```

## 可执行调用示例

启动服务后执行完整演示（登记 → 三类拒绝 → 正常工序 → 卸撑 → 快照 → 查询）：

```bash
./demo.sh
```

或逐条手动执行：

```bash
B=http://localhost:8080

# 1) 登记
curl -X POST $B/supports      -d '{"id":"S1","name":"北柱础"}'
curl -X POST $B/supports      -d '{"id":"S2","name":"南台基"}'
curl -X POST $B/components    -d '{"id":"C1","name":"前金柱","min_load":10}'
curl -X POST $B/components    -d '{"id":"C2","name":"后金柱","min_load":8}'
curl -X POST $B/replacements  -d '{"id":"R2","name":"替换后金柱","min_load":8}'
curl -X POST $B/connections   -d '{"id":"J1","a":"S1","b":"C1"}'
curl -X POST $B/connections   -d '{"id":"J2","a":"C1","b":"C2"}'
curl -X POST $B/connections   -d '{"id":"J3","a":"C1","b":"R2","in_place":false}'
curl -X POST $B/connections   -d '{"id":"J4","a":"S2","b":"R2","in_place":false}'
curl -X POST $B/temp-supports -d '{"id":"T1","a":"S2","b":"C1"}'

# 2) 拒绝示例
curl -X POST $B/steps -d '{"seq":5,"action":"install","target":"temp_support","id":"T1"}'
#   → 409 sequence_gap（工序跳号，期望 1）
curl -X POST $B/steps -d '{"seq":1,"action":"install","target":"connection","id":"J3"}'
#   → 409 endpoint_not_in_place，first_affected_component=R2（端点不在位）
curl -X POST $B/steps -d '{"seq":1,"action":"disassemble","target":"connection","id":"J1"}'
#   → 409 unreachable，first_affected_component=C1（拆后 C1 失去支承路径）

# 3) 正常工序
curl -X POST $B/steps -d '{"seq":1,"action":"install","target":"temp_support","id":"T1"}'
curl -X POST $B/steps -d '{"seq":2,"action":"disassemble","target":"component","id":"C2"}'
curl -X POST $B/steps -d '{"seq":3,"action":"install","target":"replacement","id":"R2","connections":["J3","J4"]}'

# 4) 卸撑条件不满足
curl -X POST $B/steps -d '{"seq":4,"action":"remove_support","id":"T1"}'
#   → 409 test_load_missing，first_affected_component=C1（当前连接状态下无合格试载）

# 5) 试载并卸撑
curl -X POST $B/steps -d '{"seq":4,"action":"test_load","component":"C1","load":12}'
curl -X POST $B/steps -d '{"seq":5,"action":"test_load","component":"R2","load":9.5}'
curl -X POST $B/steps -d '{"seq":6,"action":"remove_support","id":"T1"}'

# 6) 固化验收快照（此后继续修复不会改写快照 1）
curl -X POST $B/snapshots -d '{}'

# 7) 查询
curl $B/steps        # 各工序回执与结果
curl $B/steps/4      # 单条工序
curl $B/state        # 当前连接图与各构件状态
curl $B/snapshots/1  # 验收快照
```

## 施工预案示例：预演 → 过期拒绝 → 一次确认

场景：支承点 `S9`/`S10`、在位构件 `C9`、替换件 `R9`；预案清单 = 搭设临时支撑
`T9` → 拆卸连接 `J94` → 安装 `R9`（带 `J92`/`J93`）→ 试载 `C9`、`R9` → 卸撑 `T9`。
预演只模拟不落库；凭据绑定清单、登记与工序状态；预演后发生登记/工序变化时确认
被拒；重新预演后一次确认整单。

一键执行（含断言，请在空库上跑，例如 `docker compose up --build` 后的全新卷）：

```bash
./demo_plan.sh
```

逐条手动执行：

```bash
B=http://localhost:8080

# 1) 登记
curl -X POST $B/supports      -d '{"id":"S9","name":"西柱础"}'
curl -X POST $B/supports      -d '{"id":"S10","name":"东台基"}'
curl -X POST $B/components    -d '{"id":"C9","name":"西金柱","min_load":5}'
curl -X POST $B/replacements  -d '{"id":"R9","name":"替换西金柱","min_load":5}'
curl -X POST $B/connections   -d '{"id":"J91","a":"S9","b":"C9"}'
curl -X POST $B/connections   -d '{"id":"J94","a":"S10","b":"C9"}'
curl -X POST $B/connections   -d '{"id":"J92","a":"C9","b":"R9","in_place":false}'
curl -X POST $B/connections   -d '{"id":"J93","a":"S10","b":"R9","in_place":false}'
curl -X POST $B/temp-supports -d '{"id":"T9","a":"S10","b":"C9"}'

# 2) 失败预演：卸撑早于合格试载 → 409 指出出错工序及原有错误，且不留改动
curl -X POST $B/plan/preview -d '{"steps":[
  {"action":"install","target":"temp_support","id":"T9"},
  {"action":"remove_support","id":"T9"}]}'
#   → 409 {"error":"test_load_missing",
#          "failed_step":{"index":2,"seq":2,"action":"remove_support"},
#          "first_affected_component":"C9", ...}
#   预演不留下改动：last_seq 仍为 0，连接版本仍为 v0，T9 仍未搭设

# 3) 成功预演：逐步套用规则，返回每步预计结果与确认凭据
curl -X POST $B/plan/preview -d '{"steps":[
  {"action":"install","target":"temp_support","id":"T9"},
  {"action":"disassemble","target":"connection","id":"J94"},
  {"action":"install","target":"replacement","id":"R9","connections":["J92","J93"]},
  {"action":"test_load","component":"C9","load":6},
  {"action":"test_load","component":"R9","load":5},
  {"action":"remove_support","id":"T9"}]}'
#   → 200 {"ok":true,"base_seq":0,"base_version":0,
#          "steps":[{"seq":1,...},...,{"seq":6,...}],
#          "credential":"v1.<凭据>"}     ← 凭据绑定清单、当前登记与工序状态

# 4) 过期拒绝：预演后发生登记变化（新增支承点），旧凭据确认被拒
curl -X POST $B/supports -d '{"id":"S11","name":"后补支承点"}'
curl -X POST $B/plan/confirm -d '{"steps":[同上清单],"credential":"v1.<第 3 步凭据>"}'
#   → 409 {"error":"plan_stale","changed":["registry"],
#          "message":"预演后登记或工序状态已变化，凭据过期，请重新预演"}
#   （预演后若发生的是工序变化，如插入一条单步 /steps，则 changed=["steps"]）

# 5) 清单与凭据不符：改动清单后确认被拒
curl -X POST $B/plan/confirm -d '{"steps":[{"action":"install","target":"temp_support","id":"T9"}],"credential":"v1.<第 3 步凭据>"}'
#   → 409 {"error":"plan_mismatch", ...}

# 6) 重新预演取新凭据，一次确认：整单在一个写事务中复核执行
curl -X POST $B/plan/preview -d '{"steps":[同上 6 步清单]}'   # → 200 新凭据
curl -X POST $B/plan/confirm  -d '{"steps":[同上 6 步清单],"credential":"v1.<新凭据>"}'
#   → 201 {"ok":true,"receipts":[seq 1..6 按序回执]}
#   任一步失败将指出该步并回滚整单新增的工序、连接版本、临时支撑状态及试载，
#   旧回执与验收快照不变

# 7) 查询
curl $B/steps        # 确认写入的 6 条回执
curl $B/state        # last_seq=6、连接版本 v2
```

## 故障与修复示例：未安装替换件不得充当传力路径

登记固定支承点 `S`、在位承重梁 `C`、**未安装**替换件 `R`，以及 `S—R`、`R—C`
两条默认在位榫卯（只是预留端点组合）。再搭设 `S—C` 临时支撑并完成 `C` 的
合格试载：此时 `C` 唯一的"永久路径"穿过未安装的 `R`，卸撑和快照都必须拒绝；
待 `R` 按原工序安装接入、重新试载合格后，才允许卸撑与验收。

一键执行（含 409 断言，请在空库上跑，例如 `docker compose up --build` 后的全新卷）：

```bash
./demo_uninstalled_replacement.sh
```

逐条手动执行：

```bash
B=http://localhost:8080

# 1) 登记：S、C 在位；R 未安装；S—R、R—C 为默认在位榫卯
curl -X POST $B/supports     -d '{"id":"S","name":"柱础"}'
curl -X POST $B/components   -d '{"id":"C","name":"承重梁","min_load":10}'
curl -X POST $B/replacements -d '{"id":"R","name":"替换件","min_load":10}'
curl -X POST $B/connections  -d '{"id":"JSR","a":"S","b":"R"}'
curl -X POST $B/connections  -d '{"id":"JRC","a":"R","b":"C"}'

# 2) /state：两条榫卯搭在未安装的 R 上而沿路失效
#    C 的 reachable=false、permanent_reachable=false（R 行 in_place=false，可达性为 null）
curl $B/state

# 3) 搭设 S—C 临时支撑并完成 C 的合格试载
curl -X POST $B/temp-supports -d '{"id":"T","a":"S","b":"C"}'
curl -X POST $B/steps -d '{"seq":1,"action":"install","target":"temp_support","id":"T"}'
curl -X POST $B/steps -d '{"seq":2,"action":"test_load","component":"C","load":12}'

# 4) 故障：卸撑后 C 的唯一永久路径穿过未安装的 R → 409，首个受影响构件 C
curl -X POST $B/steps -d '{"seq":3,"action":"remove_support","id":"T"}'
#   → 409 support_unreachable
#     {"error":"support_unreachable",
#      "message":"卸撑后构件 C 无法仅凭永久连接抵达固定支承点，整步拒绝",
#      "first_affected_component":"C"}
#   整步回滚：无 seq 3 回执，last_seq 仍为 2，临时支撑 T 仍在位

# 5) 支撑尚在位时不能固化快照
curl -X POST $B/snapshots -d '{}'
#   → 409 shoring_incomplete，temp_support=T

#    对照：若任何临时支撑都不存在（如未搭设或另一个空库），同样不得固化虚假路径
#   → 409 support_unreachable，first_affected_component=C

# 6) 修复：按原工序安装 R；默认在位的 JSR/JRC 随 R 在位自动接入，永久路径打通
curl -X POST $B/steps -d '{"seq":3,"action":"install","target":"replacement","id":"R"}'

# 7) 连接状态版本因安装变为 v1，旧试载失效；对 C、R 重新合格试载
curl -X POST $B/steps -d '{"seq":4,"action":"test_load","component":"C","load":11}'
curl -X POST $B/steps -d '{"seq":5,"action":"test_load","component":"R","load":10}'

# 8) 合格试载支持卸撑与验收
curl -X POST $B/steps      -d '{"seq":6,"action":"remove_support","id":"T"}'   # 201
curl -X POST $B/snapshots  -d '{}'                                             # 201 快照 1
curl $B/snapshots/1
#   快照中 C、R 均带 v1 合格试载，connections_in_place 含 JSR、JRC
#   此后继续修复只增不改，快照 1 保持原样
```

## 错误响应

统一 JSON：`{"error": <code>, "message": ..., ...}`。工序拒绝一律 409 且状态不变：

| code | 含义 |
|---|---|
| `sequence_gap` | 工序跳号（附 `expected`/`got`） |
| `not_registered` | 连接/支撑/构件未事先登记 |
| `endpoint_not_in_place` | 端点不在位（附 `first_affected_component`） |
| `not_in_place` / `already_in_place` | 拆卸/安装对象状态不符 |
| `unreachable` | 工序后（含试载时）构件无法经在位连接或临时支撑抵达固定支承点 |
| `support_unreachable` | 卸撑后构件无法仅凭永久连接抵达支承点 |
| `test_load_missing` | 构件缺少当前连接状态下通过的合格试载 |
| `shoring_incomplete` | 临时支撑未卸完，不能固化快照 |
| `plan_stale` | 预演后登记或工序状态已变化，凭据过期（附 `changed`：`registry`/`steps`） |
| `plan_mismatch` | 确认清单与预演清单不一致 |
| `invalid_credential` | 确认凭据无法解析或签名无效（400，需重新预演） |

预案预演/确认中某步失败时，响应沿用原有错误码与信息，并附
`failed_step`（`index` 清单序号、`seq` 工序号、`action`）指出出错工序。

## 项目结构

```
app.py              # 服务全部实现（标准库 HTTP + SQLite）
Dockerfile          # python:3.12-slim 单容器镜像
docker-compose.yml  # 单条命令启动，卷持久化
demo.sh             # 端到端演示脚本
demo_uninstalled_replacement.sh  # 未安装替换件虚假路径：故障复现与修复演示
demo_plan.sh        # 施工预案演示：预演 → 过期拒绝 → 一次确认（含断言）
README.md
```
