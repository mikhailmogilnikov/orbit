import Foundation
import OrbitACP
import OrbitAPI

/// A JSON Schema for `.orbit/settings.json` and `~/.orbit/settings.json`
/// (D182), given to the JSON server inline: completion, hover and a warning
/// for keys Orbit doesn't read, which it otherwise ignores silently.
enum SettingsSchema {
    static let fileMatch = ["**/.orbit/settings.json"]

    /// The JSON server's settings with the schema added.
    static func jsonServerSettings(merging own: JSONValue?) -> JSONValue {
        // The server checks nothing until it's told to (VS Code sends this too).
        let schemas: JSONValue = ["json": [
            "validate": ["enable": true],
            "schemas": [["fileMatch": .array(fileMatch.map(JSONValue.string)), "schema": schema]],
        ]]
        return own.map { schemas.merging($0) } ?? schemas
    }

    static let schema: JSONValue = {
        let formatterNames = FormatterPreset.all.map(\.id) + ["server", "off"]
        let text = """
        {
          "$schema": "http://json-schema.org/draft-07/schema#",
          "title": "Orbit settings",
          "description": "A project's .orbit/settings.json wins over ~/.orbit/settings.json, which wins over Settings.",
          "type": "object",
          "additionalProperties": false,
          "patternProperties": {
            "^editor\\\\.(wordWrap|highlightCurrentLine|formatOnSave|inlayHints|stickyScroll|pathBar|indentGuides|blame|imageThumbnails|autoClose)$": { "type": "boolean" },
            "^agents\\\\.isolated$": { "type": "boolean" },
            "^agents\\\\.default$": { "type": "string" }
          },
          "properties": {
            "$schema": { "type": "string" },
            "editor": {
              "description": "Editor options, as in Settings → Editor. Also written as \\"editor.wordWrap\\": true.",
              "type": "object",
              "additionalProperties": false,
              "properties": {
                "wordWrap": { "type": "boolean", "description": "Wrap long lines.", "default": false },
                "highlightCurrentLine": { "type": "boolean", "description": "Highlight the line with the caret.", "default": true },
                "formatOnSave": { "type": "boolean", "description": "Format with the project's formatter, else the language server, on ⌘S.", "default": false },
                "inlayHints": { "type": "boolean", "description": "Types and parameter names from the language server, drawn in the code.", "default": true },
                "stickyScroll": { "type": "boolean", "description": "Keep the enclosing class and function pinned at the top.", "default": true },
                "pathBar": { "type": "boolean", "description": "The file's folders and the symbol at the caret, above the editor.", "default": true },
                "indentGuides": { "type": "boolean", "description": "Lines at each indentation level.", "default": true },
                "blame": { "type": "boolean", "description": "Who last changed the caret's line, faded after its end.", "default": true },
                "imageThumbnails": { "type": "boolean", "description": "Thumbnails of images and swatches of colors a line refers to.", "default": true },
                "autoClose": { "type": "boolean", "description": "Typing an opening bracket or quote adds the closing one.", "default": true }
              }
            },
            "agents": {
              "description": "What new chats start with in this project.",
              "type": "object",
              "additionalProperties": false,
              "properties": {
                "default": { "type": "string", "description": "The agent new chats start with, by id: claude-code-acp, codex-acp, gemini…" },
                "isolated": { "type": "boolean", "description": "Agents edit their own copy of the project; Apply brings the changes back.", "default": false }
              }
            },
            "mcpServers": {
              "description": "MCP servers every agent gets, in the format of Claude Code's .mcp.json.",
              "type": "object",
              "additionalProperties": {
                "type": "object",
                "properties": {
                  "command": { "type": "string", "description": "The program to start (stdio)." },
                  "args": { "type": "array", "items": { "type": "string" } },
                  "env": { "type": "object", "additionalProperties": { "type": "string" } },
                  "url": { "type": "string", "description": "A remote server's address (HTTP or SSE)." },
                  "type": { "enum": ["stdio", "http", "sse"] },
                  "headers": { "type": "object", "additionalProperties": { "type": "string" } },
                  "disabled": { "type": "boolean" }
                }
              }
            },
            "formatters": {
              "description": "The formatter per file type (\\"ts, tsx\\" works): a preset, \\"server\\", \\"off\\" or a command that reads stdin.",
              "type": "object",
              "additionalProperties": {
                "anyOf": [
                  { "enum": FORMATTERS },
                  { "type": "string" },
                  {
                    "type": "object",
                    "required": ["command"],
                    "properties": {
                      "command": { "type": "string" },
                      "arguments": { "type": "array", "items": { "type": "string" }, "description": "{file} is the file's path." }
                    }
                  }
                ]
              }
            },
            "languageServers": {
              "description": "The language server per file type: an nvim-lspconfig name, \\"off\\", or { \\"server\\" | \\"command\\": … }.",
              "type": "object",
              "additionalProperties": {
                "anyOf": [
                  { "type": "string" },
                  {
                    "type": "object",
                    "properties": {
                      "server": { "type": "string" },
                      "command": { "type": "string" },
                      "arguments": { "type": "array", "items": { "type": "string" } },
                      "settings": { "type": "object", "description": "The answer to workspace/configuration." },
                      "initializationOptions": { "type": "object" }
                    }
                  }
                ]
              }
            },
            "companions": {
              "description": "Servers that run beside a file's own: eslint, tailwindcss… \\"on\\", \\"off\\" or { \\"settings\\": … }.",
              "type": "object",
              "additionalProperties": {
                "anyOf": [
                  { "enum": ["on", "off"] },
                  { "type": "boolean" },
                  {
                    "type": "object",
                    "properties": {
                      "enabled": { "type": "boolean" },
                      "settings": { "type": "object" },
                      "initializationOptions": { "type": "object" }
                    }
                  }
                ]
              }
            },
            "codeActionsOnSave": {
              "description": "Code actions run before formatting on save, per file type: [\\"source.fixAll.eslint\\"].",
              "type": "object",
              "additionalProperties": {
                "anyOf": [
                  { "type": "array", "items": { "type": "string" } },
                  { "type": "string" }
                ]
              }
            },
            "tasks": {
              "description": "Commands for Run Task… (⌃⌘R): { \\"name\\": \\"command\\" } or [{ \\"name\\", \\"command\\" }].",
              "anyOf": [
                { "type": "object", "additionalProperties": { "type": "string" } },
                {
                  "type": "array",
                  "items": {
                    "type": "object",
                    "required": ["name", "command"],
                    "properties": { "name": { "type": "string" }, "command": { "type": "string" } }
                  }
                }
              ]
            }
          }
        }
        """
        let names = "[" + formatterNames.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
        let json = text.replacingOccurrences(of: "FORMATTERS", with: names)
        return (try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))) ?? .object([:])
    }()
}
