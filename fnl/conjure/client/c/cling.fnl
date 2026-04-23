(local {: autoload : define} (require :conjure.nfnl.module))
(local core (autoload :conjure.nfnl.core))
(local str (autoload :conjure.nfnl.string))
(local stdio (autoload :conjure.remote.stdio))
(local config (autoload :conjure.config))
(local mapping (autoload :conjure.mapping))
(local client (autoload :conjure.client))
(local log (autoload :conjure.log))
(local ts (autoload :conjure.tree-sitter))

(local M (define :conjure.client.c.cling))

;; We can't rely on prompt detection because cling suppresses its prompt when
;; stdout is not a tty. Instead we append a sentinel fputs() after every eval
;; and treat its appearance as the "done" signal.
(local sentinel "__CONJURE_C_DONE__")

(config.merge
  {:client
   {:c
    {:cling
     {:command "stdbuf -o0 cling"
      :prompt-pattern sentinel
      :delay-stderr-ms 10}}}})

(when (config.get-in [:mapping :enable_defaults])
  (config.merge
    {:client
     {:c
      {:cling
       {:mapping {:start "cs"
                  :stop "cS"
                  :interrupt "ei"}}}}}))

(local cfg (config.get-in-fn [:client :c :cling]))
(local state (client.new-state #(do {:repl nil})))
(set M.buf-suffix ".c")
(set M.comment-prefix "// ")

;; Top-level C constructs that make sense to evaluate as a unit.
(fn M.form-node? [node]
  (let [t (node:type)]
    (or (= t "expression_statement")
        (= t "declaration")
        (= t "function_definition")
        (= t "preproc_include")
        (= t "preproc_def")
        (= t "preproc_function_def")
        (= t "struct_specifier")
        (= t "enum_specifier")
        (= t "type_definition")
        (= t "comment"))))

(fn with-repl-or-warn [f opts]
  (let [repl (state :repl)]
    (if repl
      (f repl)
      (log.append [(.. M.comment-prefix "No REPL running")
                   (.. M.comment-prefix
                       "Start REPL with "
                       (config.get-in [:mapping :prefix])
                       (cfg [:mapping :start]))]))))

;; cling only prints expression values when there's no trailing semicolon.
;; Strip it from single-line evals so `coco;` shows `(int) 1` rather than nothing.
;; Multi-line blocks (function defs etc.) are left unchanged.
;; Always append the sentinel so the stdio transport knows evaluation is complete.
(fn prep-code [s]
  (let [trimmed (str.trim s)
        single-line? (not (string.find trimmed "\n"))
        code (if single-line? (string.gsub trimmed ";$" "") trimmed)]
    (.. code "\nfputs(\"" sentinel "\\n\",stdout);\n")))

(fn M.unbatch [msgs]
  (->> msgs
       (core.map #(or (core.get $1 :out) (core.get $1 :err)))
       (str.join "")))

;; Filter out blank lines and any residual [cling] prompt lines.
(fn M.format-msg [msg]
  (->> (str.split msg "\n")
       (core.filter
         #(and (not (string.match $1 "^%[cling%]"))
               (~= "" (str.trim $1))))))

(fn log-repl-output [msgs]
  (let [lines (-> msgs M.unbatch M.format-msg)]
    (when (not (core.empty? lines))
      (log.append lines))))

(fn M.eval-str [opts]
  (with-repl-or-warn
    (fn [repl]
      (repl.send
        (prep-code opts.code)
        (fn [msgs]
          (log-repl-output msgs)
          (when opts.on-result
            (let [lines (-> msgs M.unbatch M.format-msg)]
              (opts.on-result (str.join " " lines)))))
        {:batch? true}))))

(fn M.eval-file [opts]
  (M.eval-str (core.assoc opts :code (core.slurp opts.file-path))))

(fn display-repl-status [status]
  (log.append
    [(.. M.comment-prefix
         (cfg [:command])
         " (" (or status "no status") ")")]
    {:break? true}))

(fn M.stop []
  (let [repl (state :repl)]
    (when repl
      (repl.destroy)
      (display-repl-status :stopped)
      (core.assoc (state) :repl nil))))

(fn M.start []
  (log.append [(.. M.comment-prefix "Starting C client (cling)...")])
  (if (state :repl)
    (log.append [(.. M.comment-prefix "Can't start, REPL is already running.")
                 (.. M.comment-prefix "Stop the REPL with "
                     (config.get-in [:mapping :prefix])
                     (cfg [:mapping :stop]))]
                {:break? true})
    (if (not (ts.add-language "c"))
      (log.append [(.. M.comment-prefix "(error) The C client requires a C tree-sitter parser.")
                   (.. M.comment-prefix "(error) See https://github.com/nvim-treesitter/nvim-treesitter")])
      (core.assoc
        (state) :repl
        (stdio.start
          {:prompt-pattern (cfg [:prompt-pattern])
           :cmd (cfg [:command])
           :delay-stderr-ms (cfg [:delay-stderr-ms])

           :on-success
           (fn []
             (display-repl-status :started)
             (with-repl-or-warn
               (fn [repl]
                 ;; Bootstrap: include stdio.h so fputs is available for all
                 ;; subsequent evals, and fire the first sentinel to synchronise
                 ;; the queue before any user eval is processed.
                 (repl.send
                   (.. "#include <stdio.h>\nfputs(\"" sentinel "\\n\",stdout);\n")
                   (fn [_msgs] nil)
                   nil))))

           :on-error
           (fn [err]
             (display-repl-status err))

           :on-exit
           (fn [code signal]
             (when (and (= :number (type code)) (> code 0))
               (log.append [(.. M.comment-prefix "process exited with code " code)]))
             (when (and (= :number (type signal)) (> signal 0))
               (log.append [(.. M.comment-prefix "process exited with signal " signal)]))
             (M.stop))

           :on-stray-output
           (fn [msg]
             (log.dbg (-> [msg] M.unbatch M.format-msg) {:join-first? true}))})))))

(fn M.on-exit []
  (M.stop))

(fn M.interrupt []
  (with-repl-or-warn
    (fn [repl]
      (log.append [(.. M.comment-prefix "Sending interrupt signal.")] {:break? true})
      (repl.send-signal :sigint))))

(fn M.on-load []
  (when (config.get-in [:client_on_load])
    (M.start)))

(fn M.on-filetype []
  (mapping.buf
    :CStart (cfg [:mapping :start])
    #(M.start)
    {:desc "Start the C REPL (cling)"})

  (mapping.buf
    :CStop (cfg [:mapping :stop])
    #(M.stop)
    {:desc "Stop the C REPL"})

  (mapping.buf
    :CInterrupt (cfg [:mapping :interrupt])
    #(M.interrupt)
    {:desc "Interrupt the current evaluation"}))

M
