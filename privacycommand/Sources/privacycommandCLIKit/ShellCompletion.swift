import Foundation

/// Tab completion for the `privacycommand` CLI in zsh, bash and fish.
///
/// `privacycommand completion <shell>` prints these scripts, and the release
/// build writes them into the app bundle (`Contents/Resources/completions`) for
/// the Homebrew cask to link. All three are generated from the command tables
/// below, so a new subcommand or flag goes there as well as into the command's
/// help text.
///
/// What completes:
/// - the subcommands, and the top-level options;
/// - installed app names (the `*.app` names `privacycommand <name>` matches
///   against) and directories, wherever an app target is expected;
/// - audit options after `audit <target>` or a bare `<target>`;
/// - preview and upgrade options, the `--min-tier` / `--max-risk` levels,
///   `--apps-dir` directories, and the outdated cask tokens
///   `brew outdated --cask` lists;
/// - the shell names after `completion`.
public enum ShellCompletion {

    public enum Shell: String, CaseIterable, Sendable {
        case zsh, bash, fish

        /// The file name each shell (and Homebrew's cask stanzas) expects.
        public var fileName: String {
            switch self {
            case .zsh:  return "_privacycommand"
            case .bash: return "privacycommand.bash"
            case .fish: return "privacycommand.fish"
            }
        }
    }

    public struct Option: Sendable {
        public enum Value: Sendable {
            case directory
            case choices([String])
        }

        public let short: String?
        public let long: String
        public let help: String
        public let value: Value?

        init(_ short: String?, _ long: String, _ help: String, value: Value? = nil) {
            self.short = short
            self.long = long
            self.help = help
            self.value = value
        }

        var names: [String] { [short, long].compactMap { $0 } }
    }

    public struct Subcommand: Sendable {
        public let name: String
        public let help: String
    }

    public static let command = "privacycommand"

    public static let subcommands: [Subcommand] = [
        Subcommand(name: "audit", help: "static audit of one app"),
        Subcommand(name: "preview", help: "preview apps before you update them"),
        Subcommand(name: "upgrade", help: "apply brew upgrades under a risk limit, review the rest"),
        Subcommand(name: "interactive", help: "open the interactive browser"),
        Subcommand(name: "completion", help: "print a tab-completion script"),
    ]

    public static let topLevelOptions: [Option] = [
        Option("-h", "--help", "show usage"),
        Option("-v", "--version", "print the version"),
        Option("-i", "--interactive", "open the interactive browser"),
    ]

    public static let auditOptions: [Option] = [
        Option("-s", "--short", "one-line verdict only"),
        Option("-t", "--tree", "the app's component tree"),
        Option(nil, "--warnings", "only the findings section"),
        Option(nil, "--json", "machine-readable JSON"),
        Option(nil, "--verbose", "include info-level findings and full lists"),
        Option("-x", "--exact", "exact app-name match"),
        Option(nil, "--warn-exit", "exit 1 when there are warn or error findings"),
        Option(nil, "--no-color", "disable coloured output"),
        Option("-h", "--help", "show help"),
    ]

    public static let riskTiers = ["low", "medium", "high", "critical"]

    public static let previewOptions: [Option] = [
        Option(nil, "--all-apps", "preview every installed app instead of brew casks"),
        Option(nil, "--apps-dir", "preview every app in a folder", value: .directory),
        Option(nil, "--fetch", "download each incoming cask and diff it"),
        Option(nil, "--greedy", "include casks that normally update themselves"),
        Option(nil, "--max-risk", "gate: hold casks above this risk for review", value: .choices(riskTiers)),
        Option(nil, "--min-tier", "only show apps at or above a risk tier", value: .choices(riskTiers)),
        Option(nil, "--only-noteworthy", "hide apps with nothing noteworthy"),
        Option(nil, "--no-color", "disable coloured output"),
        Option(nil, "--json", "machine-readable JSON"),
        Option("-h", "--help", "show help"),
    ]

    public static let upgradeOptions: [Option] = [
        Option(nil, "--max-risk", "upgrade casks at or below this risk, hold the rest", value: .choices(riskTiers)),
        Option(nil, "--dry-run", "show what would be upgraded without running brew"),
        Option(nil, "--no-input", "never ask about held casks"),
        Option(nil, "--greedy", "include casks that normally update themselves"),
        Option(nil, "--min-tier", "only show apps at or above a risk tier", value: .choices(riskTiers)),
        Option(nil, "--only-noteworthy", "hide apps with nothing noteworthy"),
        Option(nil, "--no-color", "disable coloured output"),
        Option(nil, "--json", "machine-readable JSON"),
        Option("-h", "--help", "show help"),
    ]

    /// Folders whose top-level `*.app` names `privacycommand <name>` matches.
    static let appDirectories = ["/Applications", "~/Applications", "/System/Applications"]

    public static func script(for shell: Shell) -> String {
        switch shell {
        case .zsh:  return zsh()
        case .bash: return bash()
        case .fish: return fish()
        }
    }

    // MARK: - zsh

    static func zsh() -> String {
        func spec(_ o: Option) -> String {
            let exclusive = o.names.count > 1 ? "'(\(o.names.joined(separator: " ")))'" : ""
            let names = o.names.count > 1 ? "{\(o.names.joined(separator: ","))}" : o.long
            var s = "\(exclusive)\(names)'[\(zshEscaped(o.help))]"
            switch o.value {
            case .none:                  break
            case .directory:             s += ":directory:_files -/"
            case .choices(let choices):  s += ":value:(\(choices.joined(separator: " ")))"
            }
            return s + "'"
        }
        let audit = auditOptions.map { "    \(spec($0))" }.joined(separator: "\n")
        let preview = previewOptions.map { "    \(spec($0))" }.joined(separator: "\n")
        let upgrade = upgradeOptions.map { "    \(spec($0))" }.joined(separator: "\n")
        // Top-level options end the command line: nothing completes after them.
        let top = topLevelOptions.map { o -> String in
            let names = o.names.count > 1 ? "{\(o.names.joined(separator: ","))}" : o.long
            return "    '(- *)'\(names)'[\(zshEscaped(o.help))]'"
        }.joined(separator: " \\\n")
        let commands = subcommands.map { "    '\($0.name):\(zshEscaped($0.help))'" }.joined(separator: "\n")
        let dirs = appDirectories.joined(separator: " ")

        return """
        #compdef \(command)
        # zsh completion for \(command). Generated by `\(command) completion zsh`.

        __\(command)_apps() {
          local -a apps
          local dir
          for dir in \(dirs); do
            [[ -d $dir ]] && apps+=( $dir/*.app(N:t:r) )
          done
          _wanted apps expl 'installed app' compadd -a apps
        }

        __\(command)_targets() {
          _alternative \\
            'apps:installed app:__\(command)_apps' \\
            'files:app bundle:_files -/'
        }

        __\(command)_casks() {
          (( $+commands[brew] )) || return 1
          local -a casks
          casks=( ${(f)"$(brew outdated --cask --quiet 2>/dev/null)"} )
          _wanted casks expl 'outdated cask' compadd -a casks
        }

        _\(command)() {
          local curcontext=$curcontext state line ret=1
          local -a audit_opts preview_opts upgrade_opts subcmds
          audit_opts=(
        \(audit)
          )
          preview_opts=(
        \(preview)
          )
          upgrade_opts=(
        \(upgrade)
          )
          subcmds=(
        \(commands)
          )

          _arguments -C \\
        \(top) \\
            '1: :->first' \\
            '*:: :->rest' && ret=0

          case $state in
            first)
              _alternative \\
                'commands:command:{_describe -t commands command subcmds}' \\
                'targets:app to audit:__\(command)_targets' && ret=0
              ;;
            rest)
              case $line[1] in
                audit)
                  _arguments -s $audit_opts '1:app to audit:__\(command)_targets' && ret=0 ;;
                preview)
                  _arguments -s $preview_opts '*:outdated cask:__\(command)_casks' && ret=0 ;;
                upgrade)
                  _arguments -s $upgrade_opts '*:outdated cask:__\(command)_casks' && ret=0 ;;
                completion)
                  _arguments '1:shell:(\(Shell.allCases.map(\.rawValue).joined(separator: " ")))' && ret=0 ;;
                interactive) ;;
                *)
                  _arguments -s $audit_opts && ret=0 ;;
              esac
              ;;
          esac
          return ret
        }

        if [[ $funcstack[1] == _\(command) ]]; then
          # Autoloaded from fpath (Homebrew, or a site-functions folder).
          _\(command) "$@"
        elif (( $+functions[compdef] )); then
          # Sourced or eval'd from ~/.zshrc, after compinit.
          compdef _\(command) \(command)
        fi

        """
    }

    // MARK: - bash

    static func bash() -> String {
        func words(_ options: [Option]) -> String {
            var seen = Set<String>()
            return options.flatMap(\.names).filter { seen.insert($0).inserted }
                .joined(separator: " ")
        }
        let dirs = appDirectories.map { $0.replacingOccurrences(of: "~", with: "\"$HOME\"") }
            .joined(separator: " ")
        let tierWords = riskTiers.joined(separator: " ")
        let shells = Shell.allCases.map(\.rawValue).joined(separator: " ")

        return """
        # bash completion for \(command). Generated by `\(command) completion bash`.
        # Works with macOS's bash 3.2 and later.

        __\(command)_apps() {
          local dir app
          for dir in \(dirs); do
            [[ -d $dir ]] || continue
            for app in "$dir"/*.app; do
              [[ -e $app ]] || continue
              app=${app##*/}
              printf '%s\\n' "${app%.app}"
            done
          done
        }

        # Installed app names plus directories (an .app bundle is a directory).
        __\(command)_targets() {
          local IFS=$'\\n'
          COMPREPLY+=( $(compgen -W "$(__\(command)_apps)" -- "$1") )
          COMPREPLY+=( $(compgen -d -- "$1") )
        }

        _\(command)() {
          local cur=${COMP_WORDS[COMP_CWORD]}
          local prev=${COMP_WORDS[COMP_CWORD-1]}
          local audit_opts="\(words(auditOptions))"
          local preview_opts="\(words(previewOptions))"
          local upgrade_opts="\(words(upgradeOptions))"
          COMPREPLY=()

          case $prev in
            --min-tier|--max-risk) COMPREPLY=( $(compgen -W "\(tierWords)" -- "$cur") ); return 0 ;;
            --apps-dir) COMPREPLY=( $(compgen -d -- "$cur") ); return 0 ;;
          esac

          if (( COMP_CWORD == 1 )); then
            if [[ $cur == -* ]]; then
              COMPREPLY=( $(compgen -W "\(words(topLevelOptions + auditOptions))" -- "$cur") )
            else
              COMPREPLY=( $(compgen -W "\(subcommands.map(\.name).joined(separator: " "))" -- "$cur") )
              __\(command)_targets "$cur"
            fi
            return 0
          fi

          case ${COMP_WORDS[1]} in
            audit)
              if [[ $cur == -* ]]; then
                COMPREPLY=( $(compgen -W "$audit_opts" -- "$cur") )
              else
                __\(command)_targets "$cur"
              fi ;;
            preview)
              if [[ $cur == -* ]]; then
                COMPREPLY=( $(compgen -W "$preview_opts" -- "$cur") )
              elif command -v brew >/dev/null 2>&1; then
                COMPREPLY=( $(compgen -W "$(brew outdated --cask --quiet 2>/dev/null)" -- "$cur") )
              fi ;;
            upgrade)
              if [[ $cur == -* ]]; then
                COMPREPLY=( $(compgen -W "$upgrade_opts" -- "$cur") )
              elif command -v brew >/dev/null 2>&1; then
                COMPREPLY=( $(compgen -W "$(brew outdated --cask --quiet 2>/dev/null)" -- "$cur") )
              fi ;;
            completion)
              (( COMP_CWORD == 2 )) && COMPREPLY=( $(compgen -W "\(shells)" -- "$cur") ) ;;
            interactive|\(topLevelOptions.flatMap(\.names).joined(separator: "|")))
              ;;
            *)
              [[ $cur == -* ]] && COMPREPLY=( $(compgen -W "$audit_opts" -- "$cur") ) ;;
          esac
          return 0
        }

        # -o filenames escapes app names with spaces and marks directories.
        complete -o filenames -F _\(command) \(command)

        """
    }

    // MARK: - fish

    static func fish() -> String {
        let c = command
        let dirs = appDirectories.joined(separator: " ")

        func line(_ o: Option, condition: String) -> String {
            var s = "complete -c \(c) -n '\(condition)'"
            if let short = o.short { s += " -s \(short.dropFirst())" }
            s += " -l \(o.long.dropFirst(2))"
            switch o.value {
            case .none:                  break
            case .directory:             s += " -x -a '(__fish_complete_directories (commandline -ct))'"
            case .choices(let choices):  s += " -x -a '\(choices.joined(separator: " "))'"
            }
            return s + " -d '\(fishEscaped(o.help))'"
        }

        let first = "__fish_use_subcommand"
        let audit = "not __fish_use_subcommand; and not __fish_seen_subcommand_from preview upgrade completion interactive"
        let preview = "__fish_seen_subcommand_from preview"
        let upgrade = "__fish_seen_subcommand_from upgrade"

        let subcommandLines = subcommands.map {
            "complete -c \(c) -n '\(first)' -a \($0.name) -d '\(fishEscaped($0.help))'"
        }
        let topLines = topLevelOptions.map { line($0, condition: first) }
        let auditLines = auditOptions.map { line($0, condition: audit) }
        let previewLines = previewOptions.map { line($0, condition: preview) }
        let upgradeLines = upgradeOptions.map { line($0, condition: upgrade) }

        return """
        # fish completion for \(c). Generated by `\(c) completion fish`.

        function __\(c)_apps
            for dir in \(dirs)
                test -d $dir; or continue
                for app in $dir/*.app
                    basename $app .app
                end
            end
        end

        function __\(c)_casks
            command -sq brew; and brew outdated --cask --quiet 2>/dev/null
        end

        complete -c \(c) -f

        \(subcommandLines.joined(separator: "\n"))
        \(topLines.joined(separator: "\n"))

        # An app to audit: the first word, or the word after `audit`.
        complete -c \(c) -n '\(first)' -a '(__\(c)_apps)' -d 'installed app'
        complete -c \(c) -n '\(first)' -a '(__fish_complete_directories (commandline -ct))'
        complete -c \(c) -n '__fish_seen_subcommand_from audit' -a '(__\(c)_apps)' -d 'installed app'
        complete -c \(c) -n '__fish_seen_subcommand_from audit' -a '(__fish_complete_directories (commandline -ct))'
        \(auditLines.joined(separator: "\n"))

        complete -c \(c) -n '\(preview)' -a '(__\(c)_casks)' -d 'outdated cask'
        \(previewLines.joined(separator: "\n"))

        complete -c \(c) -n '\(upgrade)' -a '(__\(c)_casks)' -d 'outdated cask'
        \(upgradeLines.joined(separator: "\n"))

        complete -c \(c) -n '__fish_seen_subcommand_from completion' -x -a '\(Shell.allCases.map(\.rawValue).joined(separator: " "))'

        """
    }

    // MARK: - Escaping

    /// Text inside a zsh `_arguments` description: `[`, `]` and `:` are
    /// syntax there, and the spec sits inside single quotes.
    static func zshEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "'\\''")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: ":", with: "\\:")
    }

    static func fishEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }
}
