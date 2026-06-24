#!/usr/bin/env bash
# ============================================================================
# xaster automated test suite
# ============================================================================
# Usage:
#   ./tests/run_tests.sh              # Run all tests
#   ./tests/run_tests.sh --quick      # Smoke tests only
#   ./tests/run_tests.sh --verbose    # Full output
#   ./tests/run_tests.sh module llm   # Test a specific module
#
# Exit codes:
#   0 — all tests passed
#   1 — one or more tests failed
#   2 — test environment not set up
# ============================================================================

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TIMEOUT=30
VERBOSE=false
QUICK=false
FILTER=""

# Parse arguments
for arg in "$@"; do
  case $arg in
    --quick) QUICK=true ;;
    --verbose|-v) VERBOSE=true ;;
    --filter=*) FILTER="${arg#*=}" ;;
    *) FILTER="$arg" ;;
  esac
done

PASS=0
FAIL=0
TOTAL=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ============================================================================
# Test Helpers
# ============================================================================

pass() {
  PASS=$((PASS + 1))
  TOTAL=$((TOTAL + 1))
  echo -e "  ${GREEN}PASS${NC} $1"
}

fail() {
  FAIL=$((FAIL + 1))
  TOTAL=$((TOTAL + 1))
  echo -e "  ${RED}FAIL${NC} $1 — $2"
}

section() {
  echo ""
  echo -e "${CYAN}━━━ $1 ━━━${NC}"
}

# ============================================================================
# Neovim Lua Test Runner
# ============================================================================

run_lua_test() {
  local name="$1"
  local lua_code="$2"
  local expected="$3"

  local output
  output=$(nvim --headless --noplugin -u NONE \
    --cmd "set rtp+=$PROJECT_DIR" \
    -c "lua $lua_code" \
    -c "qall!" 2>&1)
  local exit_code=$?

  if [ $exit_code -ne 0 ]; then
    fail "$name" "Neovim exited with code $exit_code: $(echo "$output" | tail -5)"
    return 1
  fi

  if [ -n "$expected" ]; then
    if echo "$output" | grep -q "$expected"; then
      pass "$name"
      return 0
    else
      fail "$name" "Expected output containing '$expected', got: $(echo "$output" | tail -3)"
      return 1
    fi
  else
    pass "$name"
    return 0
  fi
}

# ============================================================================
# Section 1: Module Loading
# ============================================================================

section "Module Loading"

MODULES=(
  "log" "errors" "compat" "memory" "lock" "history"
  "vcursor" "editor" "tools" "toolformat" "llm" "chat"
  "checkpoint" "agent" "ui" "init"
)

for mod in "${MODULES[@]}"; do
  if [ -n "$FILTER" ] && [ "$FILTER" != "module" ] && [ "$FILTER" != "$mod" ]; then
    continue
  fi
  run_lua_test "require('xaster.$mod')" \
    "local ok, err = pcall(require, 'xaster.$mod'); if not ok then error(err) end; print('loaded xaster.$mod')" \
    "loaded xaster.$mod"
done

# ============================================================================
# Section 2: Log Module
# ============================================================================

section "Log Module"

if [ -z "$FILTER" ] || [ "$FILTER" = "log" ]; then
  run_lua_test "log.for_module creates namespaced logger" \
    "local log = require('xaster.log') log.setup({level='DEBUG'}) local l = log.for_module('test') l.info('test_message_42') local dump = log.dump({n=5}) assert(dump:find('test_message_42'), 'message not found in dump: ' .. dump:sub(1,200)) print('logger_ok')" \
    "logger_ok"

  run_lua_test "log filters by level" \
    "local log = require('xaster.log') log.setup({level='ERROR', notify_enabled=false}) local l = log.for_module('test_level') l.error('visible_error') l.info('hidden_info') l.debug('hidden_debug') vim.wait(50, function() end) local d = log.dump({n=20}) assert(d:find('visible_error'), 'ERROR should be visible, dump: '..d:sub(1,300)) assert(not d:find('hidden_info'), 'INFO leaked into ERROR-level dump') assert(not d:find('hidden_debug'), 'DEBUG leaked into ERROR-level dump') print('level_filter_ok')" \
    "level_filter_ok"

  run_lua_test "log.dump returns formatted output" \
    "local log = require('xaster.log') log.setup({level='DEBUG', notify_enabled=false}) local l=log.for_module('t1') l.info('unique_msg_1') l.error('unique_msg_2') vim.wait(50, function() end) local d=log.dump({n=10}) assert(d:find('unique_msg_1'), 'info not found in: '..d:sub(1,300)) assert(d:find('unique_msg_2'), 'error not found') print('dump_ok')" \
    "dump_ok"
fi

# ============================================================================
# Section 3: Token Counting
# ============================================================================

section "Token Counting"

if [ -z "$FILTER" ] || [ "$FILTER" = "token" ]; then
  run_lua_test "estimate_tokens returns 0 for empty" \
    "local llm=require('xaster.llm') assert(llm.estimate_tokens('')==0) assert(llm.estimate_tokens(nil)==0) print('empty_ok')" \
    "empty_ok"

  run_lua_test "estimate_tokens scales with text length" \
    "local llm=require('xaster.llm') local s=llm.estimate_tokens('hello') local l=llm.estimate_tokens('hello world this is a longer sentence with quite a few more words in it') assert(l>s, string.format('long(%d) <= short(%d)', l, s)) print('scale_ok')" \
    "scale_ok"

  run_lua_test "count_message_tokens for string content" \
    "local llm=require('xaster.llm') local t=llm.count_message_tokens({role='user',content='Hello world'}) assert(t>0, 'tokens should be > 0') print('msg_tokens_ok')" \
    "msg_tokens_ok"

  run_lua_test "count_message_tokens for content block array" \
    "local llm=require('xaster.llm') local t=llm.count_message_tokens({role='assistant', content={{type='text',text='I will help'},{type='tool_use',id='x',name='bash',input={cmd='ls'}}}}) assert(t>2, 'compound message should have >2 tokens') print('block_tokens_ok')" \
    "block_tokens_ok"

  run_lua_test "get_context_limit returns positive number" \
    "local llm=require('xaster.llm') local limit=llm.get_context_limit() assert(type(limit)=='number' and limit>=64000, 'limit too small: '..tostring(limit)) print('context_limit_ok')" \
    "context_limit_ok"
fi

# ============================================================================
# Section 4: LLM Client
# ============================================================================

section "LLM Client"

if [ -z "$FILTER" ] || [ "$FILTER" = "llm" ]; then
  run_lua_test "llm.is_configured with test key" \
    "vim.env.ANTHROPIC_API_KEY='test-key' local llm=require('xaster.llm') assert(llm.is_configured()) print('configured_ok')" \
    "configured_ok"

  run_lua_test "llm provider detection" \
    "local llm=require('xaster.llm') local p=llm.get_provider() assert(p=='deepseek' or p=='anthropic' or p=='openai', 'unknown provider: '..p) print('provider: '..p)" \
    "provider:"

  run_lua_test "llm.get_model returns non-empty" \
    "local llm=require('xaster.llm') local m=llm.get_model() assert(m and #m>0, 'model is empty') print('model: '..m:sub(1,30))" \
    "model:"

  run_lua_test "llm.uses_native_tools returns boolean" \
    "local llm=require('xaster.llm') local nt=llm.uses_native_tools() assert(type(nt)=='boolean') print('native_tools: '..tostring(nt))" \
    "native_tools:"
fi

# ============================================================================
# Section 5: Error Codes
# ============================================================================

section "Error Codes"

if [ -z "$FILTER" ] || [ "$FILTER" = "errors" ]; then
  run_lua_test "all error codes defined" \
    "local e=require('xaster.errors').ErrorCode assert(e.NETWORK_ERROR==-32010) assert(e.TIMEOUT==-32011) assert(e.RATE_LIMITED==-32012) assert(e.AUTH_ERROR==-32013) assert(e.MODEL_ERROR==-32014) assert(e.PARSE_ERROR==-32015) assert(e.MAX_RETRIES==-32016) print('error_codes_ok')" \
    "error_codes_ok"
fi

# ============================================================================
# Section 6: Tool Registry
# ============================================================================

section "Tool Registry"

if [ -z "$FILTER" ] || [ "$FILTER" = "tools" ]; then
  run_lua_test "tools.list returns all registered tools" \
    "local tools=require('xaster.tools') local all=tools.list() local count=0 for _ in pairs(all) do count=count+1 end assert(count>40, 'expected >40 tools, got '..count) print('tool_count: '..count)" \
    "tool_count:"

  run_lua_test "core tools are registered" \
    "local tools=require('xaster.tools') local all=tools.list() assert(all['file.read'], 'file.read missing') assert(all['bash'], 'bash missing') assert(all['vim.edit'], 'vim.edit missing') assert(all['observe'], 'observe missing') assert(all['memory.remember'], 'memory.remember missing') print('core_tools_ok')" \
    "core_tools_ok"

  run_lua_test "new tools are registered" \
    "local tools=require('xaster.tools') local all=tools.list() assert(all['log.dump'], 'log.dump missing') assert(all['agent.observe'], 'agent.observe missing') print('new_tools_ok')" \
    "new_tools_ok"
fi

# ============================================================================
# Section 7: Tool Format
# ============================================================================

section "Tool Format"

if [ -z "$FILTER" ] || [ "$FILTER" = "toolformat" ]; then
  run_lua_test "get_anthropic_tools returns OpenAI-format tool list" \
    "local tf=require('xaster.toolformat') local tools=tf.get_anthropic_tools() assert(type(tools)=='table' and #tools>0, 'empty tool list') assert(tools[1]['function'], 'missing function wrapper') assert(tools[1]['function'].name, 'missing function name') assert(not tools[1]['function'].name:find('%.'), 'name contains dots: '..tools[1]['function'].name) print('tool_list_ok count='..#tools)" \
    "tool_list_ok"

  run_lua_test "execute_tool_call handles ping (OpenAI format)" \
    "local tf=require('xaster.toolformat') local r=tf.execute_tool_call({['function']={name='ping',arguments='{}'}}) assert(not r.is_error, 'ping should not error: ' .. tostring(r.content)) assert(r.content:find('pong'), 'ping should return pong, got: ' .. r.content:sub(1,100)) print('ping_ok')" \
    "ping_ok"

  run_lua_test "execute_tool_call handles unknown tool (OpenAI format)" \
    "local tf=require('xaster.toolformat') local r=tf.execute_tool_call({['function']={name='nonexistent_tool',arguments='{}'}}) assert(r.is_error, 'unknown tool should error') print('unknown_tool_ok')" \
    "unknown_tool_ok"
fi

# ============================================================================
# Section 8: Memory Module
# ============================================================================

section "Memory Module"

if [ -z "$FILTER" ] || [ "$FILTER" = "memory" ]; then
  run_lua_test "memory.remember and recall" \
    "local m=require('xaster.memory') m.remember('test_key','test_value') local v=m.recall('test_key') assert(v=='test_value', 'got '..tostring(v)) m.forget('test_key') print('mem_ok')" \
    "mem_ok"

  run_lua_test "memory task tracking" \
    "local m=require('xaster.memory') m.tasks_init({{id='1',title='Task 1'},{id='2',title='Task 2'}}) local p=m.task_progress() assert(p.total==2) m.task_update('1','done') local p2=m.task_progress() assert(p2.done==1) m.clear() print('tasks_ok')" \
    "tasks_ok"

  run_lua_test "memory.two-layer: mark and jump" \
    "local m=require('xaster.memory') local buf=vim.api.nvim_get_current_buf() vim.api.nvim_buf_set_lines(buf,0,-1,false,{'line1','line2'}) vim.api.nvim_win_set_cursor(0,{2,0}) local r=m.mark_location('test_mark','a') assert(r.ok and r.mark=='a') local loc=m.recall('test_mark') assert(loc.row==2) m.clear() print('mark_ok')" \
    "mark_ok"
fi

# ============================================================================
# Section 9: Checkpoint
# ============================================================================

section "Checkpoint"

if [ -z "$FILTER" ] || [ "$FILTER" = "checkpoint" ]; then
  run_lua_test "checkpoint.save and load_last" \
    "local cp=require('xaster.checkpoint') local path,err=cp.save({round=5,messages={{role='user',content='test'}},compressed_count=1}) assert(path, 'save failed: '..(err or '?')) print('saved: '..path:match('[^/]+$')) \
     local ck,ck_path=cp.load_last() assert(ck, 'load_last failed') assert(ck.round==5) assert(ck.messages[1].content=='test') cp.clear_all() print('checkpoint_ok')" \
    "checkpoint_ok"

  run_lua_test "checkpoint.list returns array" \
    "local cp=require('xaster.checkpoint') cp.clear_all() local p1,e1=cp.save({round=1,messages={{role='user',content='t1'}}}) assert(p1 and type(p1)=='string', 'save1 failed: '..(e1 or '?')) assert(vim.loop.fs_stat(p1), 'file1 missing: '..p1) local p2,e2=cp.save({round=2,messages={{role='user',content='t2'}}}) assert(p2 and type(p2)=='string', 'save2 failed: '..(e2 or '?')) assert(vim.loop.fs_stat(p2), 'file2 missing: '..p2) local cps=cp.list() assert(type(cps)=='table', 'list returned non-table: '..type(cps)) assert(#cps >= 1, 'list empty') cp.clear_all() print('list_ok '..#cps)" \
    "list_ok"
fi

# ============================================================================
# Section 10: Virtual Cursor
# ============================================================================

section "Virtual Cursor"

if [ -z "$FILTER" ] || [ "$FILTER" = "vcursor" ]; then
  run_lua_test "vcursor.set and get and clear" \
    "local vc=require('xaster.vcursor') vc.define_highlights() local buf=vim.api.nvim_get_current_buf() vim.api.nvim_buf_set_lines(buf,0,-1,false,{'line1','line2','line3'}) local r=vc.set(buf,1,0,{mode='editing'}) assert(r.ok) local g=vc.get(buf) assert(g and g.row==1) local c=vc.clear(buf) assert(c==1) print('vcursor_ok')" \
    "vcursor_ok"
fi

# ============================================================================
# Section 11: Agent State Machine
# ============================================================================

section "Agent State"

if [ -z "$FILTER" ] || [ "$FILTER" = "agent" ]; then
  run_lua_test "agent starts in non-running state" \
    "local agent=require('xaster.agent') assert(not agent.is_running(), 'agent should not be running') print('idle_ok')" \
    "idle_ok"

  run_lua_test "agent.clear_history resets state" \
    "local agent=require('xaster.agent') agent.clear_history() local obs=agent.observe() assert(obs.round==0) assert(obs.messages_count==0) print('clear_ok')" \
    "clear_ok"

  run_lua_test "agent._restore_state loads checkpoint" \
    "local agent=require('xaster.agent') agent._restore_state({messages={{role='user',content='restored'}},round=3,compressed_count=1}) local obs=agent.observe() assert(obs.round==3) assert(obs.messages_count==1) agent.clear_history() print('restore_ok')" \
    "restore_ok"
fi

# ============================================================================
# Section 12: History Module
# ============================================================================

section "History Module"

if [ -z "$FILTER" ] || [ "$FILTER" = "history" ]; then
  run_lua_test "history.list and stats" \
    "local h=require('xaster.history') h.clear() local list=h.list({n=5}) assert(type(list)=='table') local stats=h.stats() assert(stats.total_calls==0) print('history_ok')" \
    "history_ok"
fi

# ============================================================================
# Section 13: Editor Operations (Quick)
# ============================================================================

section "Editor Operations"

if [ -z "$FILTER" ] || [ "$FILTER" = "editor" ]; then
  run_lua_test "editor.observe returns snapshot" \
    "local ed=require('xaster.editor') local obs=ed.observe() assert(obs.current_file) assert(obs.mode) print('observe_ok')" \
    "observe_ok"

  run_lua_test "editor.buffer_create and delete" \
    "local ed=require('xaster.editor') local buf=ed.buffer_create({'test'},'test_buf') assert(buf and vim.api.nvim_buf_is_valid(buf)) local ok,err=ed.buffer_delete(buf,true) assert(ok, err) print('buffer_ok')" \
    "buffer_ok"
fi

# ============================================================================
# Section 14: Full Plugin Setup
# ============================================================================

section "Plugin Setup"

if [ -z "$FILTER" ] || [ "$FILTER" = "setup" ]; then
  run_lua_test "xaster.setup initializes all components" \
    "local x=require('xaster.init') x.setup({agent={api_key='test'},log={level='ERROR',notify_enabled=false}}) local status=x.observe() assert(status.current_file) print('setup_ok')" \
    "setup_ok"
fi

# ============================================================================
# Summary
# ============================================================================

echo ""
echo "════════════════════════════════════════"
echo -e "Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}, $TOTAL total"
echo "════════════════════════════════════════"

if [ $FAIL -gt 0 ]; then
  exit 1
else
  exit 0
fi
