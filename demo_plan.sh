#!/usr/bin/env bash
# 施工预案演示：失败预演 → 成功预演 → 过期拒绝 → 重新预演 → 一次确认。
#
# 场景：支承点 S9/S10、在位构件 C9、替换件 R9。
#       预案清单（自动从末条回执后连续编号）：
#         1 搭设临时支撑 T9 → 2 拆卸连接 J94 → 3 安装 R9（带 J92/J93）
#         → 4 试载 C9 → 5 试载 R9 → 6 卸撑 T9
#       预演只模拟不落库；凭据绑定清单、当前登记与工序状态；
#       预演后发生登记/工序变化时确认被拒（plan_stale）；
#       重新预演后一次确认，整单在一个写事务中执行并返回按序回执。
#
# 用法：BASE=http://localhost:8080 ./demo_plan.sh
# 注意：请在空库上运行（如 docker compose 首次启动，或另设 APP_DB 的实例）。
set -euo pipefail
BASE="${BASE:-http://localhost:8080}"

api() {  # api METHOD PATH [JSON] -> 原样打印响应（末行 HTTP 状态码）
  local method="$1" path="$2" data="${3:-}"
  echo "==> $method $path ${data}"
  if [ -n "$data" ]; then
    curl -sS -w '\nHTTP %{http_code}\n' -X "$method" "$BASE$path" \
      -H 'Content-Type: application/json' -d "$data"
  else
    curl -sS -w '\nHTTP %{http_code}\n' -X "$method" "$BASE$path"
  fi
  echo
}

expect() {  # expect FILE 状态码 描述
  local file="$1" want="$2"; shift 2
  local code
  code="$(grep -E '^HTTP [0-9]+$' "$file" | tail -n 1)"
  if [ "$code" != "HTTP $want" ]; then
    echo "断言失败（$*）：期望 $want，实际 '$code'，完整响应见 $file" >&2
    cat "$file" >&2
    exit 1
  fi
  echo "✔ $* → $want"
}

field() {  # field FILE KEY -> 提取 JSON 顶层字符串字段值（容忍冒号后空白）
  grep -o "\"$2\": *\"[^\"]*\"" "$1" | head -n 1 | sed "s/\"$2\": *\"//;s/\"$//"
}

echo "---- 1. 登记：S9/S10、在位 C9、替换件 R9、连接与临时支撑 ----"
api POST /supports      '{"id":"S9","name":"西柱础"}'
api POST /supports      '{"id":"S10","name":"东台基"}'
api POST /components    '{"id":"C9","name":"西金柱","min_load":5}'
api POST /replacements  '{"id":"R9","name":"替换西金柱","min_load":5}'
api POST /connections   '{"id":"J91","a":"S9","b":"C9"}'
api POST /connections   '{"id":"J94","a":"S10","b":"C9"}'
api POST /connections   '{"id":"J92","a":"C9","b":"R9","in_place":false}'
api POST /connections   '{"id":"J93","a":"S10","b":"R9","in_place":false}'
api POST /temp-supports '{"id":"T9","a":"S10","b":"C9"}'

echo "---- 2. 失败预演：卸撑早于合格试载，指出出错工序且不留改动 ----"
api POST /plan/preview '{"steps":[
  {"action":"install","target":"temp_support","id":"T9"},
  {"action":"remove_support","id":"T9"}
]}' | tee /tmp/plan_bad.txt
expect /tmp/plan_bad.txt 409 "预演第 2 步（卸撑）失败"
grep -q '"test_load_missing"' /tmp/plan_bad.txt && echo "✔ 原有错误 test_load_missing"
grep -q '"failed_step": {"index": 2, "seq": 2, "action": "remove_support"}' /tmp/plan_bad.txt \
  && echo "✔ 指出出错工序 failed_step seq=2"
api GET /state | tee /tmp/plan_state0.txt
grep -q '"last_seq": 0' /tmp/plan_state0.txt && echo "✔ 预演不留改动：last_seq 仍为 0"
grep -q '"version": 0' /tmp/plan_state0.txt && echo "✔ 预演不留改动：连接版本仍为 v0"

echo "---- 3. 成功预演：逐步套用规则，返回每步预计结果与确认凭据 ----"
STEPS='[
  {"action":"install","target":"temp_support","id":"T9"},
  {"action":"disassemble","target":"connection","id":"J94"},
  {"action":"install","target":"replacement","id":"R9","connections":["J92","J93"]},
  {"action":"test_load","component":"C9","load":6},
  {"action":"test_load","component":"R9","load":5},
  {"action":"remove_support","id":"T9"}
]'
api POST /plan/preview "{\"steps\":$STEPS}" | tee /tmp/plan_preview1.txt
expect /tmp/plan_preview1.txt 200 "预演成功"
CRED1="$(field /tmp/plan_preview1.txt credential)"
[ -n "$CRED1" ] || { echo "断言失败：预演响应缺少 credential" >&2; exit 1; }
echo "✔ 获得确认凭据：${CRED1:0:40}..."
grep -q '"seq": 6, "action": "remove_support"' /tmp/plan_preview1.txt \
  && echo "✔ 每步预计结果按序返回（末步 seq=6）"
api GET /state | tee /tmp/plan_state1.txt
grep -q '"last_seq": 0' /tmp/plan_state1.txt && echo "✔ 预演后状态不变：last_seq 仍为 0"

echo "---- 4. 过期拒绝：预演后发生登记变化，旧凭据确认被拒 ----"
api POST /supports '{"id":"S11","name":"后补支承点"}'
api POST /plan/confirm "{\"steps\":$STEPS,\"credential\":\"$CRED1\"}" \
  | tee /tmp/plan_confirm_stale.txt
expect /tmp/plan_confirm_stale.txt 409 "凭据过期拒绝"
grep -q '"plan_stale"' /tmp/plan_confirm_stale.txt && echo "✔ 错误码 plan_stale"
grep -q '"changed": \["registry"\]' /tmp/plan_confirm_stale.txt && echo "✔ 变化来源 registry"

echo "---- 5. 清单与凭据不符：改动清单后确认被拒 ----"
api POST /plan/confirm "{\"steps\":[{\"action\":\"install\",\"target\":\"temp_support\",\"id\":\"T9\"}],\"credential\":\"$CRED1\"}" \
  | tee /tmp/plan_confirm_mismatch.txt
expect /tmp/plan_confirm_mismatch.txt 409 "清单被改动拒绝"
grep -q '"plan_mismatch"' /tmp/plan_confirm_mismatch.txt && echo "✔ 错误码 plan_mismatch"

echo "---- 6. 重新预演取新凭据，一次确认：整单在一个写事务中执行 ----"
api POST /plan/preview "{\"steps\":$STEPS}" | tee /tmp/plan_preview2.txt
expect /tmp/plan_preview2.txt 200 "重新预演成功"
CRED2="$(field /tmp/plan_preview2.txt credential)"
api POST /plan/confirm "{\"steps\":$STEPS,\"credential\":\"$CRED2\"}" \
  | tee /tmp/plan_confirm2.txt
expect /tmp/plan_confirm2.txt 201 "整单确认成功"
grep -q '"seq": 1, "action": "install"' /tmp/plan_confirm2.txt \
  && grep -q '"seq": 6, "action": "remove_support"' /tmp/plan_confirm2.txt \
  && echo "✔ 返回按序回执 seq 1..6"

echo "---- 7. 确认后查询：回执落库，连接版本与构件状态符合预期 ----"
api GET /steps
api GET /state | tee /tmp/plan_state2.txt
grep -q '"last_seq": 6' /tmp/plan_state2.txt && echo "✔ last_seq=6"
grep -q '"version": 2' /tmp/plan_state2.txt && echo "✔ 连接版本 v2（拆 J94、装 R9 各 +1）"
echo "✔ 施工预案流程完成：预演核对 → 过期拒绝 → 一次确认整单。"
