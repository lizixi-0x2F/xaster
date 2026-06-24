--- tests/xaster/test_token_count_spec.lua
--- Tests for the token counting heuristics in llm.lua.

local helpers = require("tests.helpers")

describe("llm token counting", function()
  local llm

  before_each(function()
    llm = require("xaster.llm")
  end)

  describe("estimate_tokens", function()
    it("returns 0 for empty string", function()
      assert.equals(0, llm.estimate_tokens(""))
    end)

    it("returns 0 for nil", function()
      assert.equals(0, llm.estimate_tokens(nil))
    end)

    it("returns at least 1 for non-empty string", function()
      local tokens = llm.estimate_tokens("hello")
      assert.is_true(tokens >= 1)
    end)

    it("counts more tokens for longer text", function()
      local short = llm.estimate_tokens("hello world")
      local long = llm.estimate_tokens("hello world this is a much longer sentence with many words")
      assert.is_true(long > short)
    end)

    it("counts punctuation as extra tokens", function()
      local no_punct = llm.estimate_tokens("hello world")
      local with_punct = llm.estimate_tokens("hello, world! How are you?")
      assert.is_true(with_punct > no_punct)
    end)

    it("handles code-like text reasonably", function()
      local code = [[function hello() return "world" end]]
      local tokens = llm.estimate_tokens(code)
      -- Code should produce a reasonable token count
      assert.is_true(tokens > 0 and tokens < 100)
    end)
  end)

  describe("count_message_tokens", function()
    it("returns 0 for nil message", function()
      assert.equals(0, llm.count_message_tokens(nil))
    end)

    it("counts string content messages", function()
      local msg = { role = "user", content = "Hello, how are you?" }
      local tokens = llm.count_message_tokens(msg)
      assert.is_true(tokens > 1)
    end)

    it("counts content block array messages", function()
      local msg = {
        role = "assistant",
        content = {
          { type = "text", text = "I'll help with that." },
        },
      }
      local tokens = llm.count_message_tokens(msg)
      assert.is_true(tokens > 1)
    end)

    it("counts tool_use blocks", function()
      local msg = {
        role = "assistant",
        content = {
          {
            type = "tool_use",
            id = "abc123",
            name = "file.read",
            input = { filepath = "/test/file.lua" },
          },
        },
      }
      local tokens = llm.count_message_tokens(msg)
      assert.is_true(tokens > 1)
    end)
  end)

  describe("count_context_tokens", function()
    it("returns 0 for nil arguments", function()
      assert.equals(0, llm.count_context_tokens(nil, nil))
    end)

    it("counts system prompt", function()
      local tokens = llm.count_context_tokens({}, "You are a helpful assistant.")
      assert.is_true(tokens > 1)
    end)

    it("counts messages + system", function()
      local msgs = {
        { role = "user", content = "Hello" },
        { role = "assistant", content = "Hi there!" },
      }
      local system = "You are helpful."
      local with_system = llm.count_context_tokens(msgs, system)
      local without_system = llm.count_context_tokens(msgs, nil)
      assert.is_true(with_system > without_system)
    end)
  end)

  describe("get_context_limit", function()
    it("returns a positive number", function()
      local limit = llm.get_context_limit()
      assert.is_true(type(limit) == "number" and limit > 0)
    end)

    it("returns at least 64000", function()
      assert.is_true(llm.get_context_limit() >= 64000)
    end)
  end)
end)
