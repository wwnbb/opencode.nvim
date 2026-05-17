import { tool } from "@opencode-ai/plugin"

export default tool({
  description:
    "Fast file content search using ripgrep (rg). Recursively searches for a regex pattern with automatic .gitignore support. " +
    "Use for finding patterns, strings, function definitions, imports, classes, or any text across files. " +
    "Supports file type filtering, glob patterns, context lines, and multiple output modes. " +
    "Prefer this over bash grep for all code searching tasks.",
  args: {
    pattern: tool.schema
      .string()
      .describe("The regex pattern to search for. Uses Rust regex syntax by default."),
    path: tool.schema
      .string()
      .optional()
      .describe(
        "File or directory to search in. Defaults to the current working directory. " +
        "Supports multiple paths separated by newlines.",
      ),
    type: tool.schema
      .string()
      .optional()
      .describe(
        "Filter by file type (e.g. 'py', 'js', 'ts', 'rs', 'go', 'java', 'md'). Can specify multiple comma-separated types like 'js,ts'.",
      ),
    exclude_type: tool.schema
      .string()
      .optional()
      .describe(
        "Exclude file types from search (e.g. 'md', 'txt'). Can specify multiple comma-separated types like 'md,txt'. Maps to rg -T.",
      ),
    glob: tool.schema
      .string()
      .optional()
      .describe(
        "Glob pattern to filter files (e.g. '*.config.*', '!*.test.*'). Prefix with '!' to exclude. " +
        "Supports multiple patterns separated by newlines.",
      ),
    case_insensitive: tool.schema
      .boolean()
      .optional()
      .describe("Case insensitive search. Default: false (case sensitive)."),
    smart_case: tool.schema
      .boolean()
      .optional()
      .describe(
        "Smart case: case insensitive unless the pattern contains uppercase. Overrides case_insensitive.",
      ),
    word: tool.schema
      .boolean()
      .optional()
      .describe("Match whole words only."),
    line_match: tool.schema
      .boolean()
      .optional()
      .describe("Match whole lines only. The entire line must match the pattern."),
    fixed_strings: tool.schema
      .boolean()
      .optional()
      .describe(
        "Treat pattern as a literal string, not a regex. Useful for searching strings with dots, parens, etc.",
      ),
    context: tool.schema
      .number()
      .optional()
      .describe(
        "Number of lines to show before and after each match for context.",
      ),
    before_context: tool.schema
      .number()
      .optional()
      .describe("Number of lines to show before each match."),
    after_context: tool.schema
      .number()
      .optional()
      .describe("Number of lines to show after each match."),
    files_only: tool.schema
      .boolean()
      .optional()
      .describe(
        "Only list filenames that contain matches, not the matching lines.",
      ),
    files_without_match: tool.schema
      .boolean()
      .optional()
      .describe(
        "Only list filenames that do NOT contain any matches.",
      ),
    count: tool.schema
      .boolean()
      .optional()
      .describe("Show count of matches per file instead of matching lines."),
    only_matching: tool.schema
      .boolean()
      .optional()
      .describe("Show only the matched part of each line, not the entire line."),
    column: tool.schema
      .boolean()
      .optional()
      .describe("Show column number of each match in addition to line number."),
    invert: tool.schema
      .boolean()
      .optional()
      .describe("Invert the match: show lines that do NOT match the pattern."),
    hidden: tool.schema
      .boolean()
      .optional()
      .describe("Search hidden files and directories (dotfiles). Default: false."),
    follow: tool.schema
      .boolean()
      .optional()
      .describe("Follow symbolic links when searching. Default: false."),
    binary: tool.schema
      .boolean()
      .optional()
      .describe("Search binary files as if they were text. Default: false."),
    no_ignore: tool.schema
      .boolean()
      .optional()
      .describe(
        "Disable all ignore-file filtering. Broadest option; includes VCS, parent, global, and local ignore files. Default: false.",
      ),
    no_ignore_vcs: tool.schema
      .boolean()
      .optional()
      .describe(
        "Disable VCS ignore rules only, such as .gitignore. Use this to search gitignored files without disabling every ignore source. Default: false.",
      ),
    extra_patterns: tool.schema
      .string()
      .optional()
      .describe(
        "Additional patterns to search for (OR logic). Newline-separated. " +
        "Combined with the main pattern using -e flags. Use when searching for any of multiple patterns.",
      ),
    max_count: tool.schema
      .number()
      .int()
      .nonnegative()
      .optional()
      .describe("Limit the number of matches per file. Set 0 or omit for unlimited."),
    multiline: tool.schema
      .boolean()
      .optional()
      .describe(
        "Enable multiline matching where '.' matches newlines and patterns can span lines.",
      ),
    pcre2: tool.schema
      .boolean()
      .optional()
      .describe(
        "Use PCRE2 regex engine for advanced features like lookahead, lookbehind, and backreferences.",
      ),
    max_results: tool.schema
      .number()
      .optional()
      .describe(
        "Maximum total number of output lines to return. Truncates output if exceeded. Default: 500.",
      ),
  },
  async execute(args, context) {
    const flags: string[] = ["--line-number", "--color=never", "--no-heading"]

    // Case and matching options
    if (args.case_insensitive) flags.push("-i")
    if (args.smart_case) flags.push("-S")
    if (args.word) flags.push("-w")
    if (args.line_match) flags.push("-x")
    if (args.fixed_strings) flags.push("-F")

    // Output mode flags
    if (args.files_only) flags.push("-l")
    if (args.files_without_match) flags.push("--files-without-match")
    if (args.count) flags.push("-c")
    if (args.only_matching) flags.push("-o")
    if (args.column) flags.push("--column")
    if (args.invert) flags.push("-v")

    // Traversal options
    if (args.hidden) flags.push("--hidden")
    if (args.follow) flags.push("--follow")
    if (args.binary) flags.push("-a")
    if (args.no_ignore) flags.push("--no-ignore")
    if (args.no_ignore_vcs) flags.push("--no-ignore-vcs")

    // Advanced matching
    if (args.multiline) flags.push("-U", "--multiline-dotall")
    if (args.pcre2) flags.push("-P")

    // Context lines
    if (args.context != null && args.context > 0) flags.push("-C", String(args.context))
    if (args.before_context != null && args.before_context > 0) flags.push("-B", String(args.before_context))
    if (args.after_context != null && args.after_context > 0) flags.push("-A", String(args.after_context))
    if (args.max_count != null && args.max_count > 0) flags.push("-m", String(args.max_count))

    // File type filtering
    if (args.type) {
      for (const t of args.type.split(",")) {
        flags.push("-t", t.trim())
      }
    }
    if (args.exclude_type) {
      for (const t of args.exclude_type.split(",")) {
        flags.push("-T", t.trim())
      }
    }

    // Glob patterns (supports multiple newline-separated patterns)
    if (args.glob) {
      for (const g of args.glob.split("\n")) {
        const trimmed = g.trim()
        if (trimmed) flags.push("-g", trimmed)
      }
    }

    // Pattern handling: support multiple patterns via -e flags
    if (args.extra_patterns) {
      const allPatterns = [args.pattern]
      for (const p of args.extra_patterns.split("\n")) {
        const trimmed = p.trim()
        if (trimmed) allPatterns.push(trimmed)
      }
      for (const p of allPatterns) {
        flags.push("-e", p)
      }
    }

    // Build paths list (supports multiple newline-separated paths)
    const paths: string[] = []
    if (args.path) {
      for (const p of args.path.split("\n")) {
        const trimmed = p.trim()
        if (trimmed) paths.push(trimmed)
      }
    }
    if (paths.length === 0) {
      paths.push(context.directory)
    }

    const maxResults = args.max_results ?? 500

    // When using -e flags, pattern is already in flags; otherwise pass as positional
    const cmd = args.extra_patterns
      ? ["rg", ...flags, "--", ...paths]
      : ["rg", ...flags, "--", args.pattern, ...paths]

    const proc = Bun.spawn(cmd, {
      stdout: "pipe",
      stderr: "pipe",
    })

    const [stdout, stderr] = await Promise.all([
      new Response(proc.stdout).text(),
      new Response(proc.stderr).text(),
    ])
    const exitCode = await proc.exited

    if (exitCode === 1) {
      return "No matches found."
    }

    if (exitCode === 2 || (exitCode !== 0 && exitCode !== 1)) {
      return `ripgrep error: ${stderr.trim()}`
    }

    const lines = stdout.split("\n")
    if (lines.length > maxResults) {
      const truncated = lines.slice(0, maxResults).join("\n")
      return `${truncated}\n\n--- Truncated: showing ${maxResults} of ${lines.length} lines. Use more specific patterns, file type filters, or glob patterns to narrow results. ---`
    }

    return stdout.trim() || "No matches found."
  },
})
