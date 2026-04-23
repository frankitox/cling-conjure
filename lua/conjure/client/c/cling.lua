-- [nfnl] fnl/conjure/client/c/cling.fnl
local _local_1_ = require("conjure.nfnl.module")
local autoload = _local_1_.autoload
local define = _local_1_.define
local core = autoload("conjure.nfnl.core")
local str = autoload("conjure.nfnl.string")
local stdio = autoload("conjure.remote.stdio")
local config = autoload("conjure.config")
local mapping = autoload("conjure.mapping")
local client = autoload("conjure.client")
local log = autoload("conjure.log")
local ts = autoload("conjure.tree-sitter")
local M = define("conjure.client.c.cling")
local sentinel = "__CONJURE_C_DONE__"
config.merge({client = {c = {cling = {command = "stdbuf -o0 cling", ["prompt-pattern"] = sentinel, ["delay-stderr-ms"] = 10}}}})
if config["get-in"]({"mapping", "enable_defaults"}) then
  config.merge({client = {c = {cling = {mapping = {start = "cs", stop = "cS", interrupt = "ei"}}}}})
else
end
local cfg = config["get-in-fn"]({"client", "c", "cling"})
local state
local function _3_()
  return {repl = nil}
end
state = client["new-state"](_3_)
M["buf-suffix"] = ".c"
M["comment-prefix"] = "// "
M["form-node?"] = function(node)
  local t = node:type()
  return ((t == "expression_statement") or (t == "declaration") or (t == "function_definition") or (t == "preproc_include") or (t == "preproc_def") or (t == "preproc_function_def") or (t == "struct_specifier") or (t == "enum_specifier") or (t == "type_definition") or (t == "comment"))
end
local function with_repl_or_warn(f, _opts)
  local repl = state("repl")
  if repl then
    return f(repl)
  else
    return log.append({(M["comment-prefix"] .. "No REPL running"), (M["comment-prefix"] .. "Start REPL with " .. config["get-in"]({"mapping", "prefix"}) .. cfg({"mapping", "start"}))})
  end
end
local function prep_code(s)
  local trimmed = str.trim(s)
  local single_line_3f = not string.find(trimmed, "\n")
  local code
  if single_line_3f then
    code = string.gsub(trimmed, ";$", "")
  else
    code = trimmed
  end
  return (code .. "\nfputs(\"" .. sentinel .. "\\n\",stdout);\n")
end
M.unbatch = function(msgs)
  local function _5_(_241)
    return (core.get(_241, "out") or core.get(_241, "err"))
  end
  return str.join("", core.map(_5_, msgs))
end
M["format-msg"] = function(msg)
  local function _6_(line)
    return not string.match(line, "^%[cling%]") and (str.trim(line) ~= "")
  end
  return core.filter(_6_, str.split(msg, "\n"))
end
local function log_repl_output(msgs)
  local lines = M["format-msg"](M.unbatch(msgs))
  if not core["empty?"](lines) then
    return log.append(lines)
  else
    return nil
  end
end
M["eval-str"] = function(opts)
  return with_repl_or_warn(function(repl)
    return repl.send(prep_code(opts.code), function(msgs)
      log_repl_output(msgs)
      if opts["on-result"] then
        local lines = M["format-msg"](M.unbatch(msgs))
        return opts["on-result"](str.join(" ", lines))
      else
        return nil
      end
    end, {["batch?"] = true})
  end)
end
M["eval-file"] = function(opts)
  return M["eval-str"](core.assoc(opts, "code", core.slurp(opts["file-path"])))
end
local function display_repl_status(status)
  return log.append({(M["comment-prefix"] .. cfg({"command"}) .. " (" .. (status or "no status") .. ")")}, {["break?"] = true})
end
M.stop = function()
  local repl = state("repl")
  if repl then
    repl.destroy()
    display_repl_status("stopped")
    return core.assoc(state(), "repl", nil)
  else
    return nil
  end
end
M.start = function()
  log.append({(M["comment-prefix"] .. "Starting C client (cling)...")})
  if state("repl") then
    return log.append({(M["comment-prefix"] .. "Can't start, REPL is already running."), (M["comment-prefix"] .. "Stop the REPL with " .. config["get-in"]({"mapping", "prefix"}) .. cfg({"mapping", "stop"}))}, {["break?"] = true})
  else
    if not ts["add-language"]("c") then
      return log.append({(M["comment-prefix"] .. "(error) The C client requires a C tree-sitter parser."), (M["comment-prefix"] .. "(error) See https://github.com/nvim-treesitter/nvim-treesitter")})
    else
      local function _9_()
        display_repl_status("started")
        return with_repl_or_warn(function(repl)
          return repl.send(("#include <stdio.h>\nfputs(\"" .. sentinel .. "\\n\",stdout);\n"), function(_msgs)
            return nil
          end, nil)
        end)
      end
      local function _12_(err)
        return display_repl_status(err)
      end
      local function _13_(code, signal)
        if (("number" == type(code)) and (code > 0)) then
          log.append({(M["comment-prefix"] .. "process exited with code " .. code)})
        else
        end
        if (("number" == type(signal)) and (signal > 0)) then
          log.append({(M["comment-prefix"] .. "process exited with signal " .. signal)})
        else
        end
        return M.stop()
      end
      local function _16_(msg)
        return log.dbg(M["format-msg"](M.unbatch({msg})), {["join-first?"] = true})
      end
      return core.assoc(state(), "repl", stdio.start({["prompt-pattern"] = cfg({"prompt-pattern"}), cmd = cfg({"command"}), ["delay-stderr-ms"] = cfg({"delay-stderr-ms"}), ["on-success"] = _9_, ["on-error"] = _12_, ["on-exit"] = _13_, ["on-stray-output"] = _16_}))
    end
  end
end
M["on-exit"] = function()
  return M.stop()
end
M.interrupt = function()
  return with_repl_or_warn(function(repl)
    log.append({(M["comment-prefix"] .. "Sending interrupt signal.")}, {["break?"] = true})
    return repl["send-signal"]("sigint")
  end)
end
M["on-load"] = function()
  if config["get-in"]({"client_on_load"}) then
    return M.start()
  else
    return nil
  end
end
M["on-filetype"] = function()
  mapping.buf("CStart", cfg({"mapping", "start"}), function()
    return M.start()
  end, {desc = "Start the C REPL (cling)"})
  mapping.buf("CStop", cfg({"mapping", "stop"}), function()
    return M.stop()
  end, {desc = "Stop the C REPL"})
  return mapping.buf("CInterrupt", cfg({"mapping", "interrupt"}), function()
    return M.interrupt()
  end, {desc = "Interrupt the current evaluation"})
end
return M
